-- =============================================================================
-- LA PENDA EXPRESS · OPERACIÓN INVENTARIO — PASO 7: el rollforward
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- POR QUÉ HACE FALTA:
--   `fn_physical_count_complete` deja el stock IGUAL a lo contado. La línea es
--       v_applied := v_line.counted_quantity - v_current;
--   contra el stock VIVO. O sea: al cerrar, el stock queda en el número que se
--   contó el 1-sep, y los 21 días de movimiento desde entonces se borran.
--   Este paso los vuelve a poner.
--
-- LO QUE SE REAPLICA (medido el 22-sep, desde el congelado del 1-sep):
--   purchase       352 movimientos · 260 insumos · neto +41,298.70 · RD$903,742.65
--   sale         7,499 movimientos · 611 insumos · neto  −8,725.00
--   waste           23 movimientos ·  15 insumos · neto     −94.00
--   transfer_in/out   8 y 8 · netos +770 / −770  (se cancelan entre sí)
--
-- LO QUE NO SE REAPLICA, A PROPÓSITO:
--   `adjustment`. Son 71 movimientos y uno de ellos es el disparate de
--   CARIBAS PLATANITOS (+16,571,952,675 del 11-sep). Reaplicarlos volvería a
--   meter esos 16 mil millones. Además, los ajustes que importan son los que
--   el propio cierre va a escribir. Los otros 70 suman 889 entre todos: si
--   alguno era una corrección real, se vuelve a hacer a mano.
--
-- EL ORDEN IMPORTA Y NO ES NEGOCIABLE:
--   7a  ANTES de cerrar — calcula y GUARDA el neto en `_penda_rollforward`.
--       Se guarda antes porque después de cerrar ya no se puede distinguir
--       qué movimiento era de antes y qué escribió el cierre.
--   7b  DESPUÉS de cerrar — aplica lo guardado.
--   Entre las dos va el cierre de las 5 sesiones (con PENDA_OP_3 ya corrido,
--   o el stock cae todo en Almacén Principal).
--
-- CADA MOVIMIENTO VUELVE A SU MISMA BODEGA. No se reparte ni se reasigna: si
-- una compra entró al FoodShop, vuelve al FoodShop.
--
-- ⚠️ LO QUE ESTE PASO NO ARREGLA — el hueco de la cocina:
--   Los 7,499 movimientos de venta cubren solo los 611 insumos que YA
--   descuentan, que son los de vínculo directo (botellas, latas, snacks). Los
--   platos preparados NO descontaron nada en septiembre porque no había ni una
--   receta. Cargar las recetas ahora NO recupera ese consumo: la receta aplica
--   hacia adelante, no hacia atrás.
--   Así que después del rollforward el stock de cocina va a estar ALTO: tiene
--   lo comprado pero no lo consumido. Hay dos salidas y es decisión del dueño:
--     (a) dejarlo así y que el faltante salga como merma en el próximo conteo
--     (b) calcular el consumo teórico (receta × unidades vendidas desde el
--         1-sep) y postearlo como ajuste. Solo tiene sentido cuando las
--         recetas estén revisadas y cargadas; si están mal, el ajuste
--         también.
-- =============================================================================


-- ═══ 7a · ANTES DE CERRAR — fotografiar lo que hay que reaplicar ═════════════
do $$
declare
  v_biz    uuid := '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6';
  v_desde  timestamptz;
  v_n      int;
begin
  select min(coalesce((to_jsonb(s)->>'frozen_at')::timestamptz,
                      (to_jsonb(s)->>'created_at')::timestamptz))
    into v_desde
    from public.physical_count_sessions s
   where s.business_id = v_biz and s.status in ('draft','in_progress');

  if v_desde is null then
    raise exception 'No hay sesiones de conteo abiertas: o ya se cerraron (y '
                    'entonces 7a llega tarde) o no hay ninguna. No se guardo nada.';
  end if;

  if to_regclass('public._penda_rollforward') is not null then
    select count(*) into v_n from public._penda_rollforward;
    raise exception 'Ya existe _penda_rollforward con % filas. Si es de una corrida '
                    'anterior, borrarla a mano antes de rehacer la foto.', v_n;
  end if;

  create table public._penda_rollforward (
    warehouse_id uuid not null,
    item_id      uuid not null,
    neto         numeric not null,
    costo_prom   numeric,
    movimientos  int not null,
    desde        timestamptz not null,
    foto_en      timestamptz not null default now(),
    aplicado_en  timestamptz,
    primary key (warehouse_id, item_id)
  );

  insert into public._penda_rollforward
    (warehouse_id, item_id, neto, costo_prom, movimientos, desde)
  select im.warehouse_id,
         im.item_id,
         sum(im.quantity),
         -- costo ponderado solo de las COMPRAS: es el unico tipo que lo trae
         -- confiable (las ventas vienen con cost_per_unit en null).
         nullif(sum(im.quantity * im.cost_per_unit)
                  filter (where im.movement_type = 'purchase')
                / nullif(sum(im.quantity) filter (where im.movement_type = 'purchase'), 0), 0),
         count(*),
         v_desde
    from public.inventory_movements im
   where im.business_id = v_biz
     and im.created_at >= v_desde
     -- los ajustes NO: uno de ellos son los 16 mil millones de CARIBAS
     and im.movement_type in ('purchase','sale','waste','transfer_in',
                              'transfer_out','return')
     and coalesce(im.reference_type,'') <> 'physical_count'
     and coalesce(im.reference_type,'') <> 'rollforward'
   group by im.warehouse_id, im.item_id
  having sum(im.quantity) <> 0;          -- lo que se cancela no hace falta

  select count(*) into v_n from public._penda_rollforward;
  raise notice 'FOTO TOMADA — % pares (bodega, insumo) desde %. AHORA se cierran '
               'las sesiones, y despues se corre 7b.', v_n, v_desde;
end
$$;


-- ─── VER LA FOTO antes de cerrar (una sola consulta) ─────────────────────────
select w.name                                                   as bodega,
       count(*)                                                  as insumos,
       sum(rf.movimientos)                                       as movimientos,
       trim(to_char(sum(rf.neto * coalesce(i.cost,0)),
                    'FM999,999,999.00'))                         as valor_al_costo,
       count(*) filter (where rf.neto > 0)                       as suben,
       count(*) filter (where rf.neto < 0)                       as bajan
from public._penda_rollforward rf
join public.warehouses w      on w.id = rf.warehouse_id
join public.inventory_items i on i.id = rf.item_id
group by w.name
order by w.name;


-- ═══ 7b · DESPUÉS DE CERRAR — aplicar la foto ═══════════════════════════════
--   Correr SOLO cuando las 5 sesiones esten cerradas. Es idempotente: lo que
--   ya se aplico queda con `aplicado_en` y no se repite.
/*
do $$
declare
  v_biz  uuid := '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6';
  v_n    int := 0;
  r      record;
begin
  if to_regclass('public._penda_rollforward') is null then
    raise exception 'Falta la foto (7a). No se aplico nada.';
  end if;

  if exists (select 1 from public.physical_count_sessions
              where business_id = v_biz and status in ('draft','in_progress')) then
    raise exception 'Todavia hay sesiones de conteo ABIERTAS. Cerrarlas primero: '
                    'si se aplica antes, el cierre borra esto tambien. No se aplico nada.';
  end if;

  for r in
    select * from public._penda_rollforward where aplicado_en is null
     order by warehouse_id, item_id
  loop
    perform public.fn_inventory_record_movement(
      p_business_id   => v_biz,
      p_warehouse_id  => r.warehouse_id,
      p_item_id       => r.item_id,
      p_movement_type => 'adjustment'::public.movement_type,
      p_quantity      => r.neto,
      p_cost_per_unit => r.costo_prom,
      p_reference_id  => null,
      p_reference_type=> 'rollforward',
      p_notes         => 'Rollforward del conteo: reaplica compras, ventas y '
                         'mermas desde ' || to_char(r.desde, 'DD-Mon-YYYY') ||
                         ' (' || r.movimientos || ' movimientos)'
    );
    update public._penda_rollforward
       set aplicado_en = now()
     where warehouse_id = r.warehouse_id and item_id = r.item_id;
    v_n := v_n + 1;
  end loop;

  raise notice 'APLICADO — % pares. Los que ya estaban aplicados se saltaron.', v_n;
end
$$;
*/


-- ─── VERIFICAR después de 7b ─────────────────────────────────────────────────
--   ESPERADO: aplicados = total, y el stock de cada insumo = contado + neto.
/*
select w.name                                        as bodega,
       count(*)                                       as pares,
       count(*) filter (where rf.aplicado_en is not null) as aplicados,
       count(*) filter (where rf.aplicado_en is null)     as pendientes
from public._penda_rollforward rf
join public.warehouses w on w.id = rf.warehouse_id
group by w.name order by w.name;
*/


-- ─── DESHACER ────────────────────────────────────────────────────────────────
--   Reversa cada movimiento del rollforward con su contrario. No borra filas:
--   el historial se conserva.
/*
do $$
declare r record; v_n int := 0;
begin
  for r in select * from public._penda_rollforward where aplicado_en is not null loop
    perform public.fn_inventory_record_movement(
      p_business_id   => '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6',
      p_warehouse_id  => r.warehouse_id,
      p_item_id       => r.item_id,
      p_movement_type => 'adjustment'::public.movement_type,
      p_quantity      => -r.neto,
      p_cost_per_unit => r.costo_prom,
      p_reference_type=> 'rollforward_undo',
      p_notes         => 'Reversa del rollforward');
    update public._penda_rollforward set aplicado_en = null
     where warehouse_id = r.warehouse_id and item_id = r.item_id;
    v_n := v_n + 1;
  end loop;
  raise notice 'Reversados % pares.', v_n;
end $$;
*/
