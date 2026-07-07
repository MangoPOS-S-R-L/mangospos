-- ============================================================================
-- Alinear el área LEGACY (que ve el KDS) con el área N:M real (que usa la
-- impresión). Arregla el KDS: filtro cocina/bar y "Plato del dia bajo Bar".
--
-- Causa: menu_items.print_area_code quedó viejo ('kitchen_hot', null o un área
--   equivocada) porque se asignó el área por la interfaz N:M (menu_item_print_areas)
--   sin actualizar el campo legacy. El KDS lee oi.print_area_code, que se copia
--   de menu_items.print_area_code al agregar el ítem → queda desalineado.
--
-- El app YA mantiene legacy+N:M sincronizados al guardar un producto; esto es
-- un backfill de una sola vez para la data vieja.
--
-- Rellena <BUSINESS_ID> con el negocio donde ves el bug del KDS.
-- Corre los pasos EN ORDEN en Supabase Studio.
-- ============================================================================

-- ─── Área "primaria" N:M de cada producto (la primera asignada) ─────────────
-- (se reusa en los 3 pasos vía este patrón distinct on created_at)

-- ─── PASO 1) PREVIEW: productos cuyo legacy NO coincide con su N:M ───────────
with area_primaria as (
  select distinct on (mipa.menu_item_id)
         mipa.menu_item_id as item_id, pa.code
  from public.menu_item_print_areas mipa
  join public.print_areas pa on pa.id = mipa.print_area_id
  order by mipa.menu_item_id, mipa.created_at
)
select mi.name as producto,
       mi.print_area_code as legacy_actual,
       ap.code            as area_nm_correcta
from public.menu_items mi
join area_primaria ap on ap.item_id = mi.id
where mi.business_id = '<BUSINESS_ID>'
  and mi.print_area_code is distinct from ap.code
order by producto;

-- ─── PASO 2) BACKFILL menu_items (arregla los ítems NUEVOS de aquí en más) ──
with area_primaria as (
  select distinct on (mipa.menu_item_id)
         mipa.menu_item_id as item_id, pa.code
  from public.menu_item_print_areas mipa
  join public.print_areas pa on pa.id = mipa.print_area_id
  order by mipa.menu_item_id, mipa.created_at
)
update public.menu_items mi
set print_area_code = ap.code
from area_primaria ap
where mi.id = ap.item_id
  and mi.business_id = '<BUSINESS_ID>'
  and mi.print_area_code is distinct from ap.code;

-- ─── PASO 3) BACKFILL order_items ABIERTOS (arregla las comandas EN el tablero)
--     Solo ítems activos (draft/pending/preparing/ready) del negocio.
with area_primaria as (
  select distinct on (mipa.menu_item_id)
         mipa.menu_item_id as item_id, pa.code
  from public.menu_item_print_areas mipa
  join public.print_areas pa on pa.id = mipa.print_area_id
  order by mipa.menu_item_id, mipa.created_at
)
update public.order_items oi
set print_area_code = ap.code
from area_primaria ap,
     public.orders o,
     public.table_sessions ts
where oi.product_id = ap.item_id
  and oi.order_id = o.id
  and ts.id = o.session_id
  and ts.business_id = '<BUSINESS_ID>'
  and oi.status in ('draft','pending','preparing','ready')
  and oi.print_area_code is distinct from ap.code;

-- ─── PASO 4) VERIFICAR: ya no debe quedar legacy desalineado ─────────────────
with area_primaria as (
  select distinct on (mipa.menu_item_id)
         mipa.menu_item_id as item_id, pa.code
  from public.menu_item_print_areas mipa
  join public.print_areas pa on pa.id = mipa.print_area_id
  order by mipa.menu_item_id, mipa.created_at
)
select count(*) as productos_aun_desalineados
from public.menu_items mi
join area_primaria ap on ap.item_id = mi.id
where mi.business_id = '<BUSINESS_ID>'
  and mi.print_area_code is distinct from ap.code;
