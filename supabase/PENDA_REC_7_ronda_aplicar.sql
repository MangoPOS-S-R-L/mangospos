-- =============================================================================
-- LA PENDA EXPRESS · RECETAS — RONDA DE ENCENDIDO, paso 2: APLICAR
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- ESCRIBE, en una sola transacción. Aplica la ronda abierta que dejó
-- PENDA_REC_6_ronda_preparar.sql:
--   1. asienta lo que esas recetas gastaron desde el conteo del 1-oct, orden
--      por orden, en Cocina (calculado EN ESTE MOMENTO);
--   2. si Cocina queda negativo de un insumo que hay en el Principal o el
--      FoodShop, pasa de allá lo justo;
--   3. enciende esas recetas con venta en negativo.
-- Todo queda anotado con el número de ronda, para poder deshacer solo esa.
-- =============================================================================

set statement_timeout = '15min';

do $$
declare
  v_biz    uuid := '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6';
  v_ronda  int;
  v_coc    uuid;
  v_cons   int;
  v_cuad   int;
  v_enc    int;
begin
  if to_regclass('public._penda_rec_ronda') is null then
    raise exception 'No hay rondas: correr PENDA_REC_6_ronda_preparar.sql. No se tocó nada.';
  end if;
  select max(ronda) into v_ronda from public._penda_rec_ronda where aplicado_en is null;
  if v_ronda is null then
    raise exception 'No hay ronda abierta: correr PENDA_REC_6_ronda_preparar.sql. No se tocó nada.';
  end if;
  if to_regprocedure('public._penda_rec_ronda_consumo(integer)') is null then
    raise exception 'Falta _penda_rec_ronda_consumo(): correr el paso de preparar. No se tocó nada.';
  end if;
  if not exists (select 1 from public._penda_rec_ronda_lista where ronda = v_ronda and encender) then
    raise exception 'La ronda % no enciende ninguna receta. No se tocó nada.', v_ronda;
  end if;

  select id into v_coc from public.warehouses
   where business_id = v_biz and name = 'Cocina' and coalesce(is_active, true);

  create table if not exists public._penda_rec_ronda_movs (
    ronda int not null, movement_id uuid primary key, tipo text not null
  );
  create table if not exists public._penda_rec_ronda_bk (
    ronda int not null, menu_item_id uuid not null,
    is_inventory_tracked boolean, allow_negative_sale boolean,
    primary key (ronda, menu_item_id)
  );

  insert into public._penda_rec_ronda_bk (ronda, menu_item_id, is_inventory_tracked, allow_negative_sale)
  select v_ronda, m.id, m.is_inventory_tracked, m.allow_negative_sale
    from public.menu_items m
    join public._penda_rec_ronda_lista l on l.menu_item_id = m.id
   where l.ronda = v_ronda and l.encender;

  -- 1. consumo desde el conteo, orden por orden
  with ins as (
    insert into public.inventory_movements (
      business_id, warehouse_id, item_id, movement_type, quantity,
      reference_id, reference_type, notes)
    select v_biz, v_coc, c.item_id, 'sale', -c.qty, c.order_id, 'order',
           'Consumo de receta asentado al encender (ronda ' || v_ronda
           || ', venta desde el conteo del 1-oct)'
      from public._penda_rec_ronda_consumo(v_ronda) c
    returning id
  )
  insert into public._penda_rec_ronda_movs (ronda, movement_id, tipo)
  select v_ronda, id, 'consumo' from ins;
  get diagnostics v_cons = row_count;

  -- 2. Cocina en negativo → lo justo desde el Principal, luego el FoodShop
  with
  neg as (
    select st.item_id, -st.quantity as falta
      from public.inventory_stock st
     where st.warehouse_id = v_coc and st.quantity < 0
       and st.item_id in (select im.item_id from public.inventory_movements im
                           join public._penda_rec_ronda_movs m on m.movement_id = im.id
                          where m.ronda = v_ronda)
  ),
  src as (
    select st.item_id, st.warehouse_id, st.quantity as hay,
           coalesce(sum(st.quantity) over (partition by st.item_id order by
                      case w.name when 'Almacen Principal' then 1 else 2 end
                      rows between unbounded preceding and 1 preceding), 0) as antes
      from public.inventory_stock st
      join public.warehouses w on w.id = st.warehouse_id
     where w.business_id = v_biz and w.name in ('Almacen Principal','FoodShop')
       and st.quantity > 0 and st.item_id in (select item_id from neg)
  ),
  mover as (
    select s.item_id, s.warehouse_id, least(s.hay, n.falta - s.antes) as q
      from src s join neg n on n.item_id = s.item_id
     where n.falta - s.antes > 0
  ),
  salida as (
    insert into public.inventory_movements (
      business_id, warehouse_id, item_id, movement_type, quantity,
      cost_per_unit, reference_type, notes)
    select v_biz, m.warehouse_id, m.item_id, 'transfer_out', -m.q, nullif(i.cost, 0),
           'recetas_cuadre', 'Ronda ' || v_ronda || ': la cocina usó esto sin transferencia'
      from mover m join public.inventory_items i on i.id = m.item_id
    returning id
  ),
  entrada as (
    insert into public.inventory_movements (
      business_id, warehouse_id, item_id, movement_type, quantity,
      cost_per_unit, reference_type, notes)
    select v_biz, v_coc, m.item_id, 'transfer_in', m.q, nullif(i.cost, 0),
           'recetas_cuadre', 'Ronda ' || v_ronda || ': vino de ' || w.name || ' sin transferencia'
      from mover m
      join public.inventory_items i on i.id = m.item_id
      join public.warehouses w on w.id = m.warehouse_id
    returning id
  )
  insert into public._penda_rec_ronda_movs (ronda, movement_id, tipo)
  select v_ronda, id, 'cuadre' from salida
  union all
  select v_ronda, id, 'cuadre' from entrada;
  get diagnostics v_cuad = row_count;

  -- 3. encender
  update public.menu_items m
     set is_inventory_tracked = true, allow_negative_sale = true
    from public._penda_rec_ronda_lista l
   where l.ronda = v_ronda and l.encender and m.id = l.menu_item_id
     and not coalesce(m.is_inventory_tracked, false);
  get diagnostics v_enc = row_count;

  update public._penda_rec_ronda set aplicado_en = now() where ronda = v_ronda;

  raise notice 'RONDA % APLICADA — % recetas encendidas, % movimientos de consumo, % de cuadre.',
               v_ronda, v_enc, v_cons, v_cuad;
end
$$;


-- ═══ VERIFICAR (una sola consulta) ══════════════════════════════════════════
select 'ronda ' || r.ronda as que,
       'aplicada ' || coalesce(to_char(r.aplicado_en at time zone 'America/Santo_Domingo',
                                       'DD-Mon HH24:MI'), '—') as dato,
       (select count(*) from public._penda_rec_ronda_lista l
         where l.ronda = r.ronda and l.encender) || ' recetas · '
       || coalesce((select count(*) from public._penda_rec_ronda_movs m
                     where m.ronda = r.ronda and m.tipo = 'consumo'), 0) || ' consumos · '
       || coalesce((select count(*) from public._penda_rec_ronda_movs m
                     where m.ronda = r.ronda and m.tipo = 'cuadre'), 0) || ' cuadres' as valor
  from public._penda_rec_ronda r
union all
select 'recetas encendidas en total', '',
       count(*) filter (where m.is_inventory_tracked) || ' de ' || count(*)
  from public.menu_items m
 where m.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
   and exists (select 1 from public.recipes x where x.menu_item_id = m.id)
order by 1;


-- ═══ DESHACER LA ÚLTIMA RONDA APLICADA ══════════════════════════════════════
/*
set statement_timeout = '15min';
do $$
declare v_r int;
begin
  select max(ronda) into v_r from public._penda_rec_ronda where aplicado_en is not null;
  insert into public.inventory_movements (
    business_id, warehouse_id, item_id, movement_type, quantity,
    cost_per_unit, reference_id, reference_type, notes)
  select im.business_id, im.warehouse_id, im.item_id,
         case im.movement_type::text
           when 'transfer_out' then 'transfer_in'::public.movement_type
           when 'transfer_in'  then 'transfer_out'::public.movement_type
           else im.movement_type end,
         -im.quantity, im.cost_per_unit, im.reference_id, im.reference_type,
         'Reversa ronda ' || v_r || ': ' || coalesce(im.notes, '')
    from public.inventory_movements im
    join public._penda_rec_ronda_movs m on m.movement_id = im.id
   where m.ronda = v_r;
  update public.menu_items mi
     set is_inventory_tracked = b.is_inventory_tracked, allow_negative_sale = b.allow_negative_sale
    from public._penda_rec_ronda_bk b where b.ronda = v_r and b.menu_item_id = mi.id;
  delete from public._penda_rec_ronda_movs where ronda = v_r;
  delete from public._penda_rec_ronda_bk where ronda = v_r;
  update public._penda_rec_ronda set aplicado_en = null where ronda = v_r;
  -- una ronda abierta posterior (preparada y sin aplicar) se descarta
  delete from public._penda_rec_ronda_lista where ronda > v_r;
  delete from public._penda_rec_ronda where ronda > v_r;
  raise notice 'Ronda % deshecha (queda abierta: se puede volver a preparar).', v_r;
end $$;
*/
