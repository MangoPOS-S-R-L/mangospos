-- =============================================================================
-- LA PENDA EXPRESS — CSV: TODAS LAS COMPRAS DE AGOSTO 2026
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- Una sola consulta, una línea por renglón de compra. Es el tercer archivo del
-- paquete del auditor: el conteo dice qué HAY, los no contados dicen qué NO se
-- verificó, y esto dice qué ENTRÓ durante el mes.
--
-- ── DOS COSAS QUE HAY QUE SABER PARA LEERLO ──────────────────────────────
--
-- 1. `cantidad` y `costo_unitario` están en la UNIDAD BASE del insumo, no en
--    la unidad de compra. Si se compró una caja de 12, la fila dice 12 y el
--    costo de cada uno. Las columnas `se_compro_en` y `contenido` muestran el
--    empaque original para poder rehacer la cuenta.
--
-- 2. `entro_al_inventario` distingue lo real de lo intencional. Una orden en
--    borrador o enviada NO movió existencia: es una compra planificada. Solo
--    `received` y `partial` afectan el inventario, y son las que se pueden
--    cruzar contra el conteo físico.
--
-- La fecha es la de RECEPCIÓN. Donde no la haya, cae a la de creación de la
-- orden, y la columna `fecha_es` lo dice.
--
-- EXPORTAR: correr y usar «Download CSV» en el SQL Editor de Supabase.
-- =============================================================================

select
  to_char(coalesce(po.received_date, po.created_at::date), 'DD/MM/YYYY')  as fecha,
  case when po.received_date is not null then 'recepción' else 'creación' end
                                                     as fecha_es,
  po.order_number                                    as orden,
  coalesce(s.name, '(sin proveedor)')                as proveedor,
  coalesce(s.rnc, '')                                as rnc,
  po.status                                          as estado_orden,
  case when po.status in ('received', 'partial') then 'SÍ' else 'no' end
                                                     as entro_al_inventario,

  coalesce(i.sku, '')                                as codigo,
  coalesce(i.name, coalesce(poi.description, '(sin artículo)'))
                                                     as articulo,
  case
    when i.id is null                                     then 'sin ligar'
    when exists (select 1 from public.menu_items mi
                  where mi.inventory_item_id = i.id)      then 'Producto'
    when exists (select 1 from public.recipe_ingredients ri
                  where ri.inventory_item_id = i.id)      then 'Receta'
    else                                                       'Insumo'
  end                                                as tipo,
  coalesce(i.unit, '')                               as unidad_base,

  coalesce(poi.purchase_unit, '')                    as se_compro_en,
  poi.pack_size                                      as contenido,

  poi.quantity_ordered                               as cantidad,
  poi.quantity_received                              as recibido,
  round(poi.unit_cost, 2)                            as costo_unitario,
  poi.tax_rate                                       as itbis_pct,
  round(poi.total, 2)                                as total_linea,

  round(coalesce(i.cost, 0), 2)                      as costo_maestro_hoy,
  case
    when i.id is null                              then ''
    when coalesce(i.cost, 0) = 0                   then 'maestro en CERO'
    when abs(coalesce(i.cost,0) - poi.unit_cost) < 0.01 then 'igual'
    when coalesce(i.cost,0) > poi.unit_cost        then 'maestro más alto'
    else                                                'maestro más bajo'
  end                                                as vs_maestro

from public.purchase_order_items poi
join public.purchase_orders po on po.id = poi.purchase_order_id
left join public.inventory_items i on i.id = poi.inventory_item_id
left join public.suppliers s on s.id = po.supplier_id
where po.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and coalesce(po.received_date, po.created_at::date)
      between date '2026-08-01' and date '2026-08-31'
order by
  coalesce(po.received_date, po.created_at::date),
  po.order_number,
  coalesce(i.name, poi.description);


-- ---------------------------------------------------------------------------
-- EL RESUMEN — para el mensaje que acompaña el archivo.
-- ---------------------------------------------------------------------------
with ordenes as (
  select po.id, po.status, po.supplier_id, coalesce(po.total, 0) as total
  from public.purchase_orders po
  where po.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
    and coalesce(po.received_date, po.created_at::date)
        between date '2026-08-01' and date '2026-08-31'
)
select
  count(*)                                                    as ordenes,
  count(*) filter (where status in ('received','partial'))    as recibidas,
  count(*) filter (where status in ('draft','sent'))          as sin_recibir,
  count(*) filter (where status = 'cancelled')                as canceladas,
  count(distinct supplier_id)                                 as proveedores,
  (select count(*) from public.purchase_order_items poi
    join ordenes o on o.id = poi.purchase_order_id)           as renglones,
  (select count(distinct poi.inventory_item_id)
     from public.purchase_order_items poi
     join ordenes o on o.id = poi.purchase_order_id)          as articulos_distintos,
  round(sum(total), 2)                                        as total_del_mes,
  round(sum(total) filter (where status in ('received','partial')), 2)
                                                              as total_recibido
from ordenes;
