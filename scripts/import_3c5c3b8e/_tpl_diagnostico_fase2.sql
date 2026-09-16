-- ============================================================================
-- DIAGNÓSTICO PREVIO A LA FASE 2.  Business 3c5c3b8e-28e6-45f0-8dc7-85e3efe8d30c
--
-- ⚠ ARCHIVO GENERADO por build_fase2_3c5c3b8e.py desde _tpl_diagnostico_fase2.sql.
--
-- CORRE ESTO PRIMERO Y PÉGAME EL RESULTADO. No escribe nada.
-- Es UNA sola consulta a propósito: el SQL Editor de Supabase solo muestra el
-- resultado de la última. Sale una tabla (seccion, detalle):
--   1) ajustes, ITBIS, menús, bodega y área
--   2) fase 1: cuántos de los __N_FASE1__ siguen, cuáles ya no están y cuáles
--      cambiaron de categoría
--   3) productos o insumos que YA tienen un código de la fase 2 (creados a mano)
--   4) productos creados desde el 15/09 que no son de la fase 1, y sin categoría
--   5) categorías actuales
-- ============================================================================

with
biz as (
  select '3c5c3b8e-28e6-45f0-8dc7-85e3efe8d30c'::uuid as id
),
f1 as (
  select split_part(x, '~', 1) as codigo, split_part(x, '~', 2) as categoria
  from unnest(string_to_array('__CODES_F1_CAT__', ';')) as x
),
f2 as (
  select unnest(string_to_array('__CODES__', ',')) as codigo
),
bc2 as (
  select unnest(string_to_array('__BARCODES__', ',')) as barcode
),
mi as (
  select m.*, c.name as cat,
         exists (select 1 from public.order_items oi where oi.product_id = m.id) as vendido
  from public.menu_items m
  left join public.categories c on c.id = m.category_id
  where m.business_id = (select id from biz)
),
ya as (
  select 'producto: ' || m.name || ' · sku ' || coalesce(m.sku, '—')
         || ' · barcode ' || coalesce(m.barcode, '—') || ' · $' || m.price
         || ' · ' || case when m.vendido then 'CON ventas' else 'sin ventas' end
         || ' · creado ' || to_char(m.created_at, 'DD/MM HH24:MI') as detalle
  from mi m
  where m.sku in (select codigo from f2)
     or m.barcode in (select codigo from f2)
     or m.barcode in (select barcode from bc2)
  union all
  select 'insumo: ' || ii.name || ' · sku ' || coalesce(ii.sku, '—')
         || ' · barcode ' || coalesce(ii.barcode, '—') || ' · movimientos '
         || (select count(*) from public.inventory_movements mv where mv.item_id = ii.id)
  from public.inventory_items ii
  where ii.business_id = (select id from biz)
    and (ii.sku in (select codigo from f2)
         or ii.barcode in (select codigo from f2)
         or ii.barcode in (select barcode from bc2))
),
filas(orden, sub, seccion, detalle) as (
  -- 1) Ajustes
  select 10, 0, '1. Ajustes',
         'kitchen_enabled = ' || coalesce(bs.kitchen_enabled, true)::text
         || ' · inventory_mode = ' || coalesce(bs.inventory_mode, 'none')
         || ' · service_fee_enabled = ' || coalesce(bs.service_fee_enabled, false)::text
  from public.business_settings bs
  where bs.business_id = (select id from biz)
  union all
  select 11, 0, '1. Ajustes', 'Impuestos: ' || coalesce((
           select string_agg(t.name || ' ' || t.rate || '%'
                  || case when coalesce(t.is_active, true) then '' else ' (inactivo)' end
                  || case when coalesce(t.is_service_fee, false) then ' (is_service_fee!)' else '' end,
                  ', ')
           from public.taxes t where t.business_id = (select id from biz)), 'ninguno')
  union all
  select 12, 0, '1. Ajustes', 'Menús activos: ' || (
           select count(*) from public.menus
           where business_id = (select id from biz) and coalesce(is_active, true))
  union all
  select 13, 0, '1. Ajustes', 'Bodega de la que descuenta la venta: ' || coalesce((
           select w.name || case when coalesce(w.is_active, true) then '' else ' (INACTIVA)' end
           from public.warehouses w
           where w.business_id = (select id from biz)
           order by w.is_main desc, w.created_at asc nulls first, w.id asc
           limit 1), 'NINGUNA')
  union all
  select 14, 0, '1. Ajustes', 'Áreas de comanda: ' || coalesce((
           select string_agg(a.name || ' (' || a.code || ')', ', ')
           from public.print_areas a
           where a.business_id = (select id from biz)
             and a.is_active
             and a.code not in ('cashier', 'fiscal', 'cash_close')), 'ninguna')

  -- 2) Fase 1
  union all
  select 20, 0, '2. Fase 1',
         'Encontrados ' || count(*) || ' de ' || (select count(*) from f1)
         || ' · activos ' || count(*) filter (where m.is_active)
         || ' · con ventas ' || count(*) filter (where m.vendido)
         || ' · productos del negocio en total ' || (select count(*) from mi)
  from f1
  join mi m on m.sku = f1.codigo
  union all
  select 21, 0, '2. Fase 1 · ya NO está', f1.codigo || ' (era de ' || f1.categoria || ')'
  from f1
  where not exists (select 1 from mi m where m.sku = f1.codigo)
  union all
  select 22, 0, '2. Fase 1 · cambió de categoría',
         m.name || ' (' || m.sku || '): ' || f1.categoria || ' → ' || coalesce(m.cat, 'SIN CATEGORÍA')
  from f1
  join mi m on m.sku = f1.codigo
  where lower(btrim(coalesce(m.cat, ''))) <> lower(f1.categoria)

  -- 3) Códigos de la fase 2 que ya existen
  union all
  select 30, 0, '3. Código de la fase 2 que YA existe', detalle from ya
  union all
  select 30, 0, '3. Código de la fase 2 que YA existe', 'ninguno: la carga solo inserta'
  where not exists (select 1 from ya)

  -- 4) Creados a mano / sin categoría
  union all
  select 40, 0, '4. Creado desde el 15/09 (no es de la fase 1)',
         m.name || ' · sku ' || coalesce(m.sku, '—') || ' · barcode ' || coalesce(m.barcode, '—')
         || ' · $' || m.price || ' · ' || coalesce(m.cat, 'SIN CATEGORÍA')
         || ' · ' || case when m.vendido then 'CON ventas' else 'sin ventas' end
         || ' · creado ' || to_char(m.created_at, 'DD/MM HH24:MI')
  from mi m
  where m.created_at >= '2026-09-15'
    and not exists (select 1 from f1 where f1.codigo = m.sku)
  union all
  select 41, 0, '4. Sin categoría',
         m.name || ' · sku ' || coalesce(m.sku, '—') || ' · $' || m.price
  from mi m
  where m.category_id is null

  -- 5) Categorías
  union all
  select 50, c.position, '5. Categoría',
         c.name || ' · posición ' || c.position
         || ' · ' || (select count(*) from mi m where m.category_id = c.id) || ' productos'
         || case when c.is_active then '' else ' · INACTIVA' end
  from public.categories c
  where c.business_id = (select id from biz)
)
select seccion, detalle
from filas
order by orden, sub, detalle;
