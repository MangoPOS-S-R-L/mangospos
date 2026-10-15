-- =============================================================================
-- LA PENDA EXPRESS · RECETAS — DESHACER el PASO R2 de la PRIMERA versión
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- ESCRIBE, en una sola transacción.
--
-- POR QUÉ (12-oct): el R2 se corrió en su primera versión, que encendía las
-- 119 recetas tal cual. Así entraron la receta de PAPAS a 180 «unidades» por
-- plato (RD$351,000 por hamburguesa, RD$3.16 millones asentados en Cocina) y
-- las recetas sin ningún insumo real. Además, cada venta desde entonces
-- descontó con esas recetas.
--
-- QUÉ HACE — deja todo como si ese R2 no se hubiera corrido:
--   1. Anota qué órdenes concilió el sistema DESPUÉS de encender (las que
--      se vendieron con las recetas viejas).
--   2. Revierte, uno por uno, los movimientos que asentó aquel R2 (consumo
--      hacia atrás y cuadre), con su contrario: el consumo vuelve como
--      VENTA de la misma orden con signo opuesto, así la conciliación de cada
--      orden queda en cero.
--   3. Devuelve productos (recetas apagadas, venta en negativo, auto-86) y el
--      interruptor de inventario por área a como estaban antes.
--   4. Re-concilia las órdenes del punto 1 con consume_inventory_from_order
--      (la misma función que usa la caja), ya con las recetas apagadas: les
--      devuelve lo que descontaron de más (las 180 cajas de papas por
--      hamburguesa, los «COCINA ·»), y lo que vendieron de reventa queda donde
--      el sistema lo descuenta hoy.
--   5. Guarda el rastro: renombra las tablas de aquel R2 a `_penda_rec_v1_*`.
--
-- DESPUÉS: PENDA_REC_1_preparar.sql (lista nueva con la regla del dueño) y
-- PENDA_REC_2_aplicar.sql (la versión nueva).
-- =============================================================================

set statement_timeout = '15min';

do $$
declare
  v_biz   uuid := '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6';
  v_t1    timestamptz;
  v_rev   int;
  v_ord   int := 0;
  v_hay_lista boolean;
  r       record;
begin
  ---------------------------------------------------------------------------
  -- Guardas
  ---------------------------------------------------------------------------
  if to_regclass('public._penda_rec_v1_movs') is not null then
    raise exception 'La primera versión del R2 YA se deshizo (_penda_rec_v1_movs existe). '
                    'No se tocó nada.';
  end if;
  if to_regclass('public._penda_rec_movs') is null
     or to_regclass('public._penda_rec_bk_productos') is null
     or to_regclass('public._penda_rec_bk_ajustes') is null then
    raise exception 'No están las tablas del R2 (_penda_rec_movs y respaldos): no hay nada '
                    'que deshacer. No se tocó nada.';
  end if;
  -- (dinámico: plpgsql resuelve las tablas al planear el IF, aunque la
  -- primera condición ya sea falsa)
  if to_regclass('public._penda_rec_encender') is not null then
    execute 'select exists (select 1 from public._penda_rec_encender)' into v_hay_lista;
    if v_hay_lista then
      raise exception 'Existe _penda_rec_encender: el R2 que se corrió parece ser el NUEVO, no '
                      'el primero. Revisar antes de deshacer. No se tocó nada.';
    end if;
  end if;

  select min(hecho_en) into v_t1 from public._penda_rec_movs;

  ---------------------------------------------------------------------------
  -- 1. Órdenes que el sistema concilió con las recetas viejas
  ---------------------------------------------------------------------------
  create temp table _ventana on commit drop as
  select distinct im.reference_id as order_id
    from public.inventory_movements im
   where im.business_id = v_biz
     and im.reference_type = 'order'
     and im.reference_id is not null
     and im.created_at > v_t1
     and im.id not in (select movement_id from public._penda_rec_movs);

  ---------------------------------------------------------------------------
  -- 2. Revertir lo que asentó aquel R2
  ---------------------------------------------------------------------------
  insert into public.inventory_movements (
    business_id, warehouse_id, item_id, movement_type, quantity,
    cost_per_unit, reference_id, reference_type, notes)
  select im.business_id, im.warehouse_id, im.item_id,
         case im.movement_type::text
           when 'transfer_out' then 'transfer_in'::public.movement_type
           when 'transfer_in'  then 'transfer_out'::public.movement_type
           else im.movement_type end,
         -im.quantity, im.cost_per_unit, im.reference_id, im.reference_type,
         'Reversa (R2 primera versión): ' || coalesce(im.notes, '')
    from public.inventory_movements im
    join public._penda_rec_movs m on m.movement_id = im.id;
  get diagnostics v_rev = row_count;

  ---------------------------------------------------------------------------
  -- 3. Productos e interruptor como estaban
  ---------------------------------------------------------------------------
  update public.menu_items m
     set is_inventory_tracked = b.is_inventory_tracked,
         allow_negative_sale  = b.allow_negative_sale,
         is_active            = b.is_active,
         auto_disabled        = b.auto_disabled
    from public._penda_rec_bk_productos b
   where b.id = m.id;

  update public.business_settings bs
     set warehouse_sections_enabled = b.warehouse_sections_enabled
    from public._penda_rec_bk_ajustes b
   where b.business_id = bs.business_id;

  ---------------------------------------------------------------------------
  -- 4. Re-conciliar lo vendido con las recetas viejas
  ---------------------------------------------------------------------------
  for r in select order_id from _ventana loop
    perform public.consume_inventory_from_order(r.order_id);
    v_ord := v_ord + 1;
  end loop;

  ---------------------------------------------------------------------------
  -- 5. Rastro
  ---------------------------------------------------------------------------
  alter table public._penda_rec_movs         rename to _penda_rec_v1_movs;
  alter table public._penda_rec_bk_productos rename to _penda_rec_v1_bk_productos;
  alter table public._penda_rec_bk_ajustes   rename to _penda_rec_v1_bk_ajustes;

  raise notice 'DESHECHO — % movimientos revertidos, % órdenes re-conciliadas (vendidas desde %). '
               'Ahora: PASO R1 y PASO R2.', v_rev, v_ord,
               to_char(v_t1 at time zone 'America/Santo_Domingo', 'DD-Mon HH24:MI');
end
$$;


-- ═══ VERIFICAR (una sola consulta) ══════════════════════════════════════════
--   ESPERADO: recetas encendidas = 2 (las de antes); inventario por área =
--   false; y el neto de lo que asentó aquel R2 + su reversa = 0.
select 'recetas encendidas' as que,
       count(*) filter (where m.is_inventory_tracked)::text as valor
  from public.menu_items m
 where m.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
   and exists (select 1 from public.recipes r where r.menu_item_id = m.id)
union all
select 'inventario por área',
       (select warehouse_sections_enabled::text from public.business_settings
         where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6')
union all
select 'neto R2 viejo + reversa (debe ser 0)',
       coalesce(round(sum(im.quantity), 4), 0)::text
  from public.inventory_movements im
 where im.id in (select movement_id from public._penda_rec_v1_movs)
    or (im.notes like 'Reversa (R2 primera versión):%'
        and im.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6');
