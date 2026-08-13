-- ============================================================================
-- SCRIPT 1 de 2 — DIAGNÓSTICO de impuestos
-- Negocio 6e18428f-fdd6-4c58-af0e-dae2403fbf1d (LA COCINA MEXICANA AUTENTICA)
--
-- SOLO LECTURA. Responde: cuántos impuestos hay, cuántos productos tienen los
-- dos, cuántos tienen uno solo y cuántos no tienen ninguno.
--
-- Contexto: `menu_item_taxes` es la ÚNICA fuente del impuesto por producto.
-- Producto sin fila ahí → se vende con impuesto 0.
--
-- El script 2 (scripts/ley10_6e18428f_aplicar.sql) es el que escribe.
-- ============================================================================

-- ─── 1) ¿Cuántos impuestos hay creados y cómo están configurados? ───────────
--   Ojo a: rate, is_active, include_in_ecf (false = no se declara a DGII,
--   correcto para la propina de ley) y las banderas de canal.
--   is_service_fee debe estar en FALSE en todos — nunca se activa.
select
  t.id,
  t.name,
  t.rate,
  t.is_active,
  t.is_service_fee,
  t.include_in_ecf,
  t.apply_on_zone,
  t.apply_on_manual,
  t.apply_on_quick,
  t.apply_on_delivery,
  t.apply_on_takeout,
  (select count(*)
     from public.menu_item_taxes mit
     join public.menu_items mi on mi.id = mit.item_id
    where mit.tax_id = t.id
      and mi.business_id = t.business_id
      and mi.is_active)                     as productos_vinculados
from public.taxes t
where t.business_id = '6e18428f-fdd6-4c58-af0e-dae2403fbf1d'::uuid
order by t.rate desc, t.name;


-- ─── 2) LA MATRIZ: productos activos por combinación ITBIS 18 / LEY 10 ──────
--   Esta es la respuesta directa a "cuántos tienen los 2, cuántos 1, cuántos 0".
with prod as (
  select
    mi.id,
    mi.tax_mode,
    exists (
      select 1 from public.menu_item_taxes m
      join public.taxes t on t.id = m.tax_id
      where m.item_id = mi.id and t.rate = 18 and t.is_active)  as tiene_itbis,
    exists (
      select 1 from public.menu_item_taxes m
      join public.taxes t on t.id = m.tax_id
      where m.item_id = mi.id and t.rate = 10 and t.is_active)  as tiene_ley
  from public.menu_items mi
  where mi.business_id = '6e18428f-fdd6-4c58-af0e-dae2403fbf1d'::uuid
    and mi.is_active
)
select
  count(*)                                                          as productos_activos,
  count(*) filter (where tiene_itbis and tiene_ley)                 as con_los_2,
  count(*) filter (where tiene_itbis and not tiene_ley)             as solo_itbis,
  count(*) filter (where tiene_ley and not tiene_itbis)             as solo_ley,
  count(*) filter (where not tiene_itbis and not tiene_ley)         as sin_ninguno,
  count(*) filter (where tax_mode = 'inclusive')                    as en_modo_inclusive,
  count(*) filter (where tax_mode = 'exclusive')                    as en_modo_exclusive
from prod;


-- ─── 3) Los que NO tienen los dos — lista para revisar uno por uno ──────────
select
  mi.name                          as producto,
  c.name                           as categoria,
  mi.price,
  mi.tax_mode,
  case
    when not tiene_itbis and not tiene_ley then 'SIN NINGUNO'
    when not tiene_ley                     then 'falta LEY 10%'
    else                                        'falta ITBIS 18%'
  end                              as que_le_falta
from (
  select
    mi.*,
    exists (
      select 1 from public.menu_item_taxes m
      join public.taxes t on t.id = m.tax_id
      where m.item_id = mi.id and t.rate = 18 and t.is_active) as tiene_itbis,
    exists (
      select 1 from public.menu_item_taxes m
      join public.taxes t on t.id = m.tax_id
      where m.item_id = mi.id and t.rate = 10 and t.is_active) as tiene_ley
  from public.menu_items mi
  where mi.business_id = '6e18428f-fdd6-4c58-af0e-dae2403fbf1d'::uuid
    and mi.is_active
) mi
left join public.categories c on c.id = mi.category_id
where not (tiene_itbis and tiene_ley)
order by que_le_falta, c.name nulls last, mi.name;


-- ─── 4) Cobertura por categoría ─────────────────────────────────────────────
select
  coalesce(c.name, '(sin categoría)')                             as categoria,
  count(*)                                                        as productos,
  count(*) filter (where exists (
    select 1 from public.menu_item_taxes m
    join public.taxes t on t.id = m.tax_id
    where m.item_id = mi.id and t.rate = 18 and t.is_active))     as con_itbis,
  count(*) filter (where exists (
    select 1 from public.menu_item_taxes m
    join public.taxes t on t.id = m.tax_id
    where m.item_id = mi.id and t.rate = 10 and t.is_active))     as con_ley
from public.menu_items mi
left join public.categories c on c.id = mi.category_id
where mi.business_id = '6e18428f-fdd6-4c58-af0e-dae2403fbf1d'::uuid
  and mi.is_active
group by c.name
order by c.name nulls last;


-- ─── 5) Master switch de propina por orden — DEBE estar en false ────────────
--   Si sale true, el 10% se cobraría dos veces (por producto y por orden).
select bs.service_fee_enabled, bs.service_fee_rate
from public.business_settings bs
where bs.business_id = '6e18428f-fdd6-4c58-af0e-dae2403fbf1d'::uuid;
