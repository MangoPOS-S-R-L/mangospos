-- =============================================================================
-- SEMBRAR vínculos insumo–suplidor desde las compras recibidas (decisión D8)
--
-- Para negocios con el maestro de suplidores VACÍO (La Penda: 92 suplidores,
-- 0 vínculos). Crea UN vínculo por cada insumo × suplidor que ya entró al
-- inventario, con:
--   · la presentación de compra y el contenido del INSUMO,
--   · el último precio pagado > 0, llevado a precio por unidad de compra
--     (costo por unidad base × contenido).
--
-- Fuentes (solo mercancía que ENTRÓ): órdenes recibidas, recepciones directas
-- con suplidor y recepciones con conduce.
--
-- CANDADOS:
--   · Solo el negocio de la línea `business_id` de abajo.
--   · No pisa vínculos que ya existan, ni reactiva los desactivados a mano.
--   · Correrlo dos veces no duplica.
--   · Respaldo de lo sembrado; el ROLLBACK borra solo lo que sigue igual.
--
-- Deshacer: SEMBRAR_vinculos_suplidor_ROLLBACK.sql
-- =============================================================================

begin;

set local lock_timeout = '5s';
set local statement_timeout = '120s';

create temporary table tmp_params on commit drop as
select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'::uuid as business_id;   -- ← negocio

do $$
begin
  if to_regclass('public.supplier_items') is null then
    raise exception 'Falta la migración 20260819_0003 (supplier_items). No se sembró nada.';
  end if;
end $$;

create table if not exists public.backup_supplier_items_seed (
  id                uuid        not null,
  business_id       uuid        not null,
  supplier_id       uuid        not null,
  inventory_item_id uuid        not null,
  sembrado_price    numeric,
  sembrado_unit     text,
  sembrado_pack     numeric,
  sembrado_en       timestamptz not null default now()
);
revoke all on table public.backup_supplier_items_seed from anon, authenticated;

create temporary table tmp_seed on commit drop as
with p as (select business_id from tmp_params),
purchases as (
  select im.item_id, po.supplier_id, im.cost_per_unit, im.created_at
    from public.inventory_movements im
    join p on p.business_id = im.business_id
    join public.purchase_orders po on po.id = im.reference_id
   where im.movement_type = 'purchase'
     and im.reference_type = 'purchase_order'
     and po.supplier_id is not null
  union all
  select im.item_id, dr.supplier_id, im.cost_per_unit, im.created_at
    from public.inventory_movements im
    join p on p.business_id = im.business_id
    join public.direct_receipts dr on dr.id = im.reference_id
   where im.movement_type = 'purchase'
     and im.reference_type = 'direct_receipt'
     and dr.supplier_id is not null
  union all
  select im.item_id, pr.supplier_id, im.cost_per_unit, im.created_at
    from public.inventory_movements im
    join p on p.business_id = im.business_id
    join public.purchase_reception_lines prl on prl.id = im.reference_id
    join public.purchase_receptions pr on pr.id = prl.reception_id
   where im.movement_type = 'purchase'
     and im.reference_type = 'purchase_reception_line'
     and pr.supplier_id is not null
),
-- Por pareja: la compra más reciente CON costo; si ninguna tiene costo, la
-- más reciente igual (el vínculo sirve aunque falte el precio).
last_by_pair as (
  select distinct on (item_id, supplier_id)
         item_id, supplier_id, cost_per_unit, created_at
    from purchases
   order by item_id, supplier_id,
            (coalesce(cost_per_unit, 0) > 0) desc,
            created_at desc
)
select b.item_id,
       b.supplier_id,
       nullif(trim(ii.purchase_unit), '')          as purchase_unit,
       coalesce(nullif(ii.pack_size, 0), 1)        as pack_size,
       case when coalesce(b.cost_per_unit, 0) > 0
            then round(b.cost_per_unit * coalesce(nullif(ii.pack_size, 0), 1), 4)
       end                                          as last_price,
       b.created_at                                 as last_purchase_at
  from last_by_pair b
  join p on true
  join public.inventory_items ii on ii.id = b.item_id and ii.business_id = p.business_id
  join public.suppliers s        on s.id  = b.supplier_id and s.business_id = p.business_id;

with inserted as (
  insert into public.supplier_items (
    business_id, supplier_id, inventory_item_id,
    purchase_unit, pack_size, last_price, is_active, notes
  )
  select p.business_id, t.supplier_id, t.item_id,
         t.purchase_unit, t.pack_size, t.last_price, true,
         'Sembrado desde compras recibidas'
    from tmp_seed t
    cross join tmp_params p
  on conflict (supplier_id, inventory_item_id) do nothing
  returning id, business_id, supplier_id, inventory_item_id,
            last_price, purchase_unit, pack_size
)
insert into public.backup_supplier_items_seed (
  id, business_id, supplier_id, inventory_item_id,
  sembrado_price, sembrado_unit, sembrado_pack
)
select id, business_id, supplier_id, inventory_item_id,
       last_price, purchase_unit, pack_size
  from inserted;

-- Resumen. Revisar ANTES del commit.
select 'parejas insumo × suplidor encontradas' as dato, count(*)::text as valor from tmp_seed
union all
select 'vínculos sembrados ahora', count(*)::text
  from public.backup_supplier_items_seed b, tmp_params p
 where b.business_id = p.business_id
   and b.sembrado_en >= now() - interval '1 minute'
union all
select 'parejas que ya tenían vínculo (no se tocaron)', count(*)::text
  from tmp_seed t
  join public.supplier_items si
    on si.supplier_id = t.supplier_id and si.inventory_item_id = t.item_id
  left join public.backup_supplier_items_seed b on b.id = si.id
 where b.id is null
union all
select 'insumos con 2 o más suplidores', count(*)::text
  from (select item_id from tmp_seed group by item_id having count(*) > 1) x
union all
select 'parejas sin precio (ninguna compra con costo)', count(*)::text
  from tmp_seed where last_price is null;

commit;
