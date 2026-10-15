-- =============================================================================
-- LA PENDA EXPRESS · ÁREAS — PASO A1: qué productos tienen cada área HOY
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- SOLO LECTURA. UNA sola consulta.
--
-- Para qué: con el inventario por área, el ÁREA DE PRODUCCIÓN del producto
-- decide de qué almacén descuenta (COCINA → Cocina, BAR → Bar, FOODSHOP →
-- FoodShop). Hoy la mercancía de tienda está en el área BAR y descontaría
-- del Bar. Esta lista, por categoría, sirve para decidir qué categorías
-- pasan al área FoodShop (creada en la app el 12-oct, impresora CAJA).
--
-- El área se lee igual que la caja y el consumo: las filas de
-- menu_item_print_areas mandan; si el producto no tiene ninguna, vale
-- menu_items.print_area_code.
-- =============================================================================

with
biz as (select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'::uuid as id),
prod as (
  select m.id, m.name, m.category_id,
         coalesce(m.is_inventory_tracked, false) as descuenta,
         coalesce(
           (select string_agg(pa.name, ' + ' order by pa.name)
              from public.menu_item_print_areas x
              join public.print_areas pa on pa.id = x.print_area_id
             where x.menu_item_id = m.id),
           (select pa.name from public.print_areas pa
             where pa.business_id = m.business_id and pa.code = m.print_area_code
             limit 1),
           '(sin área)') as area
    from public.menu_items m, biz
   where m.business_id = biz.id and coalesce(m.is_active, true)
),
-- ventas de 30 días, agregadas UNA vez (una subconsulta por fila revienta
-- el editor)
ventas as (
  select oi.product_id, sum(coalesce(oi.qty, oi.quantity::numeric, 0)) as un
    from public.order_items oi
   where oi.created_at >= now() - interval '30 days'
     and oi.status <> 'void'
     and oi.product_id in (select id from prod)
   group by oi.product_id
)
select coalesce(c.name, '(sin categoría)')                     as categoria,
       p.area                                                   as area_hoy,
       count(*)                                                 as productos,
       count(*) filter (where p.descuenta)                      as descuentan,
       coalesce(sum(v.un), 0)::int                              as vendidos_30d,
       left(string_agg(p.name, ' · ' order by coalesce(v.un, 0) desc, p.name), 160)
                                                                as ejemplos
  from prod p
  left join public.categories c on c.id = p.category_id
  left join ventas v on v.product_id = p.id
 group by coalesce(c.name, '(sin categoría)'), p.area
 order by p.area, count(*) desc;
