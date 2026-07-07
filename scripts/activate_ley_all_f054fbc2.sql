-- ============================================================================
-- Activar LEY 10% en TODOS los productos
-- Negocio: f054fbc2-3fb7-4e34-a020-11341ff11d84 (Sophisticated Managment SRL)
-- Mecanismo: insertar (item_id, tax_id_LEY) en menu_item_taxes para cada
--   producto que aún no lo tenga. Idempotente (NOT EXISTS) y scopeado al negocio.
-- OJO: esto le cobra 10% de LEY también a retail (cigarrillos, cargadores, etc.).
-- Correr los pasos EN ORDEN en Supabase Studio (SQL Editor).
-- ============================================================================

-- ─── PASO 1) PREVIEW: cuántas filas se van a insertar (debe dar ~888) ───────
select count(*) as filas_a_insertar
from public.menu_items mi
join public.taxes t
  on t.business_id = mi.business_id and t.name = 'LEY'
where mi.business_id = 'f054fbc2-3fb7-4e34-a020-11341ff11d84'
  and not exists (
    select 1 from public.menu_item_taxes m
    where m.item_id = mi.id and m.tax_id = t.id
  );

-- ─── PASO 2) INSERT: asigna LEY a todos los que no la tienen ────────────────
insert into public.menu_item_taxes (item_id, tax_id)
select mi.id, t.id
from public.menu_items mi
join public.taxes t
  on t.business_id = mi.business_id and t.name = 'LEY'
where mi.business_id = 'f054fbc2-3fb7-4e34-a020-11341ff11d84'
  and not exists (
    select 1 from public.menu_item_taxes m
    where m.item_id = mi.id and m.tax_id = t.id
  );

-- ─── PASO 3) VERIFICAR: con_ley debe igualar a productos ────────────────────
with tax_ley as (
  select id from public.taxes
   where business_id = 'f054fbc2-3fb7-4e34-a020-11341ff11d84' and name = 'LEY' limit 1
)
select
  count(*)                                                                   as productos,
  count(*) filter (where exists (
    select 1 from public.menu_item_taxes m
    where m.item_id = mi.id and m.tax_id = (select id from tax_ley)))         as con_ley
from public.menu_items mi
where mi.business_id = 'f054fbc2-3fb7-4e34-a020-11341ff11d84';

-- ============================================================================
-- ROLLBACK (solo si te arrepientes): QUITA LEY de TODOS los productos.
-- OJO: también se la quita a los 481 que YA la tenían antes (no distingue).
-- ============================================================================
-- delete from public.menu_item_taxes m
-- using public.taxes t
-- where m.tax_id = t.id
--   and t.business_id = 'f054fbc2-3fb7-4e34-a020-11341ff11d84'
--   and t.name = 'LEY';
