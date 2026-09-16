-- =============================================================================
-- DIAGNÓSTICO del pedido sugerido · La Penda · Almacén Principal — SOLO LECTURA
-- Para la parte del NEGOCIO (después del sistema). Una sola consulta.
--
--  A) Existencias negativas: cuántas, cuánto se pedía de más por ellas (con la
--     fórmula de la 0004) y las 25 peores.
--  B) Insumos que hace falta pedir y NO tienen suplidor: por qué (recepción
--     directa sin suplidor, orden sin suplidor, solo carga inicial, nunca
--     entró por compra).
--
-- Da lo mismo antes o después de la 0006: el «de más» se calcula aquí con las
-- columnas crudas.
-- =============================================================================

with
proj as materialized (
  select *
    from public.fn_purchase_projection(
           '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6',
           'f0cd4394-3bd9-4889-908c-686fd9ed67d2',   -- Almacen Principal
           7, 30, 2, 3, null, false)
),
neg as (
  select p.*,
         greatest(0, p.target - (p.stock + p.in_transit + p.on_order))
           - greatest(0, p.target - (greatest(p.stock, 0) + p.in_transit + p.on_order)) as de_mas
    from proj p
   where p.stock < 0
),
sin_suplidor as (
  select p.item_id,
         case
           when exists (
             select 1 from public.inventory_movements im
               join public.direct_receipts dr on dr.id = im.reference_id
              where im.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
                and im.item_id = p.item_id
                and im.movement_type = 'purchase' and im.reference_type = 'direct_receipt'
                and dr.supplier_id is null)
             then '1 · recepción directa sin suplidor'
           when exists (
             select 1 from public.inventory_movements im
               join public.purchase_orders po on po.id = im.reference_id
              where im.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
                and im.item_id = p.item_id
                and im.movement_type = 'purchase' and im.reference_type = 'purchase_order'
                and po.supplier_id is null)
             then '2 · orden de compra sin suplidor'
           when exists (
             select 1 from public.inventory_movements im
              where im.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
                and im.item_id = p.item_id
                and im.movement_type = 'purchase' and im.reference_type = 'initial_stock')
             then '3 · solo carga inicial'
           when exists (
             select 1 from public.inventory_movements im
              where im.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
                and im.item_id = p.item_id
                and im.movement_type = 'purchase')
             then '4 · otra entrada de compra'
           else '5 · nunca entró por compra'
         end as origen,
         p.estimated_cost
    from proj p
   where p.suggested_base > 0
     and p.supplier_id is null
)
select orden, seccion, detalle, valor
  from (
    select 1 as orden, 'A · Negativos' as seccion,
           'Insumos con existencia negativa' as detalle,
           count(*)::text as valor
      from neg
    union all
    select 2, 'A · Negativos', 'De esos, con pedido sugerido (fórmula 0004)',
           count(*) filter (where greatest(0, target - (stock + in_transit + on_order)) > 0)::text
      from neg
    union all
    select 3, 'A · Negativos', 'Lo que se pedía DE MÁS por el negativo (costo estimado)',
           round(coalesce(sum(de_mas * coalesce(unit_cost_base, 0)), 0), 2)::text
      from neg
    union all
    select 10 + row_number() over (order by origen), 'B · Sin suplidor', origen,
           count_items || ' insumos · costo estimado ' || costo
      from (
        select origen, count(*) as count_items, round(sum(estimated_cost), 2) as costo
          from sin_suplidor
         group by origen
      ) b
    union all
    select 100 + row_number() over (order by stock), 'A · 25 más negativos',
           item_name || coalesce(' · ' || sku, ''),
           stock || ' ' || unit || ' · consume ' || daily_consumption || '/día · de más '
             || round(de_mas, 2) || ' (' || round(de_mas * coalesce(unit_cost_base, 0), 2) || ')'
      from (select * from neg order by stock limit 25) n25
  ) v
 order by orden;
