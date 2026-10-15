-- =============================================================================
-- LA PENDA EXPRESS · RECETAS — PASO R2: descontar lo gastado y ENCENDER
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- ESCRIBE, en una sola transacción. Correr después del R1.
--
--   1. Asienta lo que la cocina gastó desde el conteo del 1-oct, ORDEN POR
--      ORDEN (venta de la orden, almacén Cocina), con el cálculo de
--      `_penda_rec_consumo()` hecho EN ESTE MOMENTO (no una foto vieja).
--   2. Si Cocina queda NEGATIVO de un insumo que hay en el Principal (o en el
--      FoodShop), pasa de allá SOLO lo justo para dejarlo en 0: es lo que la
--      cocina usó de allá sin transferencia.
--   3. Enciende las recetas de `_penda_rec_encender` (las que tienen al menos
--      un insumo con existencia y ningún renglón absurdo; las otras siguen
--      vendiéndose sin descontar), la venta en negativo en todo lo que
--      descuenta, devuelve a la caja lo apagado por el auto-86, y enciende el
--      inventario por área: desde aquí los platos de área COCINA descuentan
--      del almacén Cocina.
--
-- LO QUE NO HACE (queda para PENDA_ACT_3_encender, después de las
-- transferencias): darle al Bar su área y que el Principal deje de vender.
-- Mientras tanto, todo lo que no es de cocina se sigue vendiendo como hoy:
-- primero del Principal, después del FoodShop.
-- =============================================================================

set statement_timeout = '15min';

do $$
declare
  v_biz     uuid := '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6';
  v_coc     uuid;
  v_n_cons  int;
  v_n_cuad  int;
  v_n1 int; v_n2 int; v_n3 int;
begin
  ---------------------------------------------------------------------------
  -- Guardas
  ---------------------------------------------------------------------------
  if to_regclass('public._penda_act_plan') is null
     or not exists (select 1 from public._penda_act_plan where aplicado_en is not null) then
    raise exception 'El PASO 2 del inventario no se ha aplicado. No se tocó nada.';
  end if;

  if to_regprocedure('public._penda_rec_consumo()') is null then
    raise exception 'Falta la función _penda_rec_consumo(): correr el PASO R1. No se tocó nada.';
  end if;

  if to_regclass('public._penda_rec_encender') is null then
    raise exception 'Falta la lista _penda_rec_encender: correr el PASO R1. No se tocó nada.';
  end if;

  if to_regclass('public._penda_rec_movs') is not null then
    raise exception 'El PASO R2 ya se corrió (_penda_rec_movs existe). No se tocó nada.';
  end if;

  select id into v_coc from public.warehouses
   where business_id = v_biz and name = 'Cocina' and coalesce(is_active, true)
     and warehouse_type = 'production' and production_area_id is not null;
  if v_coc is null then
    raise exception 'El almacén Cocina no es production con área. No se tocó nada.';
  end if;

  ---------------------------------------------------------------------------
  -- Respaldo
  ---------------------------------------------------------------------------
  create table public._penda_rec_movs (
    movement_id uuid primary key,
    tipo        text not null,
    hecho_en    timestamptz not null default now()
  );

  create table public._penda_rec_bk_productos as
  select m.id, m.is_inventory_tracked, m.allow_negative_sale, m.is_active, m.auto_disabled
    from public.menu_items m
   where m.business_id = v_biz
     and (exists (select 1 from public.recipes r where r.menu_item_id = m.id)
          or m.inventory_item_id is not null
          or coalesce(m.auto_disabled, false));

  create table public._penda_rec_bk_ajustes as
  select business_id, warehouse_sections_enabled
    from public.business_settings where business_id = v_biz;

  ---------------------------------------------------------------------------
  -- 1. Lo que gastó la cocina, orden por orden (ANTES de encender: así el
  --    auto-86 no recalcula plato por plato en cada movimiento)
  ---------------------------------------------------------------------------
  with ins as (
    insert into public.inventory_movements (
      business_id, warehouse_id, item_id, movement_type, quantity,
      reference_id, reference_type, notes
    )
    select v_biz, v_coc, c.item_id, 'sale', -c.qty, c.order_id, 'order',
           'Consumo de receta asentado al encender (venta desde el conteo del 1-oct)'
      from public._penda_rec_consumo() c
    returning id
  )
  insert into public._penda_rec_movs (movement_id, tipo)
  select id, 'consumo' from ins;
  get diagnostics v_n_cons = row_count;

  ---------------------------------------------------------------------------
  -- 2. Cocina en negativo → lo justo desde el Principal, luego el FoodShop
  ---------------------------------------------------------------------------
  with
  neg as (
    select st.item_id, -st.quantity as falta
      from public.inventory_stock st
     where st.warehouse_id = v_coc and st.quantity < 0
       and st.item_id in (select im.item_id from public.inventory_movements im
                           join public._penda_rec_movs m on m.movement_id = im.id)
  ),
  src as (
    select st.item_id, st.warehouse_id, st.quantity as hay,
           coalesce(sum(st.quantity) over (partition by st.item_id order by
                      case w.name when 'Almacen Principal' then 1 else 2 end
                      rows between unbounded preceding and 1 preceding), 0) as antes
      from public.inventory_stock st
      join public.warehouses w on w.id = st.warehouse_id
     where w.business_id = v_biz and w.name in ('Almacen Principal','FoodShop')
       and st.quantity > 0
       and st.item_id in (select item_id from neg)
  ),
  mover as (
    select s.item_id, s.warehouse_id,
           least(s.hay, n.falta - s.antes) as q
      from src s join neg n on n.item_id = s.item_id
     where n.falta - s.antes > 0
  ),
  salida as (
    insert into public.inventory_movements (
      business_id, warehouse_id, item_id, movement_type, quantity,
      cost_per_unit, reference_type, notes
    )
    select v_biz, m.warehouse_id, m.item_id, 'transfer_out', -m.q,
           nullif(i.cost, 0), 'recetas_cuadre',
           'Al encender recetas: la cocina usó esto sin transferencia'
      from mover m join public.inventory_items i on i.id = m.item_id
    returning id
  ),
  entrada as (
    insert into public.inventory_movements (
      business_id, warehouse_id, item_id, movement_type, quantity,
      cost_per_unit, reference_type, notes
    )
    select v_biz, v_coc, m.item_id, 'transfer_in', m.q,
           nullif(i.cost, 0), 'recetas_cuadre',
           'Al encender recetas: vino de ' || w.name || ' sin transferencia'
      from mover m
      join public.inventory_items i on i.id = m.item_id
      join public.warehouses w on w.id = m.warehouse_id
    returning id
  )
  insert into public._penda_rec_movs (movement_id, tipo)
  select id, 'cuadre' from salida
  union all
  select id, 'cuadre' from entrada;
  get diagnostics v_n_cuad = row_count;

  ---------------------------------------------------------------------------
  -- 3. Encender
  ---------------------------------------------------------------------------
  update public.menu_items m
     set is_inventory_tracked = true
   where m.business_id = v_biz
     and not coalesce(m.is_inventory_tracked, false)
     and m.id in (select menu_item_id from public._penda_rec_encender where encender);
  get diagnostics v_n1 = row_count;

  update public.menu_items m
     set allow_negative_sale = true
   where m.business_id = v_biz
     and coalesce(m.is_inventory_tracked, false)
     and not coalesce(m.allow_negative_sale, false)
     and (exists (select 1 from public.recipes r where r.menu_item_id = m.id)
          or m.inventory_item_id is not null);
  get diagnostics v_n2 = row_count;

  update public.menu_items m
     set is_active = true, auto_disabled = false
   where m.business_id = v_biz
     and coalesce(m.auto_disabled, false)
     and not coalesce(m.is_active, true);
  get diagnostics v_n3 = row_count;

  update public.business_settings
     set warehouse_sections_enabled = true
   where business_id = v_biz;

  drop function public._penda_rec_consumo();

  raise notice 'LISTO — % movimientos de consumo, % de cuadre; % recetas encendidas, '
               '% productos a venta en negativo, % reactivados. La cocina descuenta '
               'de Cocina.', v_n_cons, v_n_cuad, v_n1, v_n2, v_n3;
end
$$;


-- ═══ VERIFICAR (una sola consulta) ══════════════════════════════════════════
--   ESPERADO: recetas encendidas = las de la lista + las 2 que ya estaban;
--   sin venta en negativo = 0;
--   inventario por área = true; y lo que quedó en Cocina.
select 'movimientos' as que, tipo as dato, count(*)::text as valor
  from public._penda_rec_movs group by tipo
union all
select 'recetas', 'encendidas / total',
       count(*) filter (where m.is_inventory_tracked) || ' / ' || count(*)
  from public.menu_items m
 where m.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
   and exists (select 1 from public.recipes r where r.menu_item_id = m.id)
union all
select 'productos', 'descuentan sin venta en negativo',
       count(*)::text
  from public.menu_items m
 where m.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
   and m.is_inventory_tracked and not coalesce(m.allow_negative_sale, false)
   and (m.inventory_item_id is not null
        or exists (select 1 from public.recipes r where r.menu_item_id = m.id))
union all
select 'negocio', 'inventario por área',
       (select warehouse_sections_enabled::text from public.business_settings
         where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6')
union all
select 'Cocina', 'insumos > 0 · en negativo · valor',
       count(*) filter (where st.quantity > 0) || ' · ' ||
       count(*) filter (where st.quantity < 0) || ' · ' ||
       to_char(sum(st.quantity * coalesce(i.cost, 0)) filter (where st.quantity > 0),
               'FM999,999,990.00')
  from public.inventory_stock st
  join public.warehouses w on w.id = st.warehouse_id
  join public.inventory_items i on i.id = st.item_id
 where w.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6' and w.name = 'Cocina';


-- ═══ DESHACER ═══════════════════════════════════════════════════════════════
--   Cada consumo se devuelve como VENTA de la misma orden con signo contrario
--   (así la conciliación de esa orden queda en cero, como si nunca se hubiera
--   asentado); el cuadre se devuelve con su transferencia contraria. Productos
--   e interruptor vuelven a como estaban.
/*
set statement_timeout = '15min';
do $$
begin
  insert into public.inventory_movements (
    business_id, warehouse_id, item_id, movement_type, quantity,
    cost_per_unit, reference_id, reference_type, notes)
  select im.business_id, im.warehouse_id, im.item_id,
         case im.movement_type::text
           when 'transfer_out' then 'transfer_in'::public.movement_type
           when 'transfer_in'  then 'transfer_out'::public.movement_type
           else im.movement_type end,
         -im.quantity, im.cost_per_unit, im.reference_id, im.reference_type,
         'Reversa: ' || coalesce(im.notes, '')
    from public.inventory_movements im
    join public._penda_rec_movs m on m.movement_id = im.id;

  update public.menu_items m
     set is_inventory_tracked = b.is_inventory_tracked,
         allow_negative_sale  = b.allow_negative_sale,
         is_active            = b.is_active,
         auto_disabled        = b.auto_disabled
    from public._penda_rec_bk_productos b where b.id = m.id;

  update public.business_settings bs
     set warehouse_sections_enabled = b.warehouse_sections_enabled
    from public._penda_rec_bk_ajustes b where b.business_id = bs.business_id;

  drop table public._penda_rec_movs;
  drop table public._penda_rec_bk_productos;
  drop table public._penda_rec_bk_ajustes;
  raise notice 'Deshecho. Para volver a intentarlo, correr el PASO R1 (recrea la función).';
end $$;
*/
