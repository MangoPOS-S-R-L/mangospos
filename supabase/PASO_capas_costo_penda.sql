-- =============================================================================
-- LA PENDA EXPRESS — encendido del motor de capas de costo.
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- ORDEN OBLIGATORIO:
--   0. Correr PREFLIGHT_capas_costo.sql y leer las 8 salidas.
--   1. Aplicar 20260902_0012_inventory_cost_layers.sql
--   2. Aplicar 20260902_0013_inventory_opening_layers.sql
--      (hasta aquí NADA cambia: el default es last_price)
--   3. COMBINAR_conteos_por_area_penda.sql — pasos 1 a 5. Las cinco sesiones
--      son de la MISMA bodega (Almacén Principal); hay que sumarlas en UNA
--      sola ANTES de cualquier otra cosa.
--   4. Cerrar la sesión destino DESDE LA APP, con el motor todavía apagado.
--      Al cerrar, el stock queda IGUAL a lo contado.
--   5. PASO A de este archivo sobre esa única sesión — simulacro, no escribe.
--   6. Cotejar el simulacro con DH.
--   7. PASO B — sembrar la apertura.
--   8. PASO C — encender UEPS.
--   9. PASO D — verificar.
--
-- POR QUÉ EL CIERRE VA ANTES DE SEMBRAR (paso 4 antes del 7):
--   `fn_physical_count_complete` genera un movimiento de ajuste por cada línea
--   contada. Con el motor ENCENDIDO esos ajustes crearían capas por su cuenta,
--   encima de la apertura, y el inventario quedaría contado dos veces. Con el
--   motor apagado los ajustes solo mueven cantidades, el stock queda igual a
--   lo contado, y la apertura que sembramos después calza al centavo.
--
-- LOS PASOS 4 A 8 VAN SEGUIDOS Y CON LA OPERACIÓN CERRADA. Entre el cierre del
-- conteo y el encendido, cada venta que entre mueve el stock y lo separa de las
-- capas: esa diferencia aparecería después como faltante falso en el PASO D.
--
-- SESIONES AL 2026-09-01 (todas in_progress, todas Almacén Principal):
--   PC-2026-000002  Furgón + Almacén principal   283 líneas
--   PC-2026-000003  Almacén Cocina                 0 líneas  ← EN PAPEL, SIN TECLEAR
--   PC-2026-000004  Foodshop · Winnifer          203 líneas
--   PC-2026-000005  Foodshop · Rosayra           266 líneas  ← destino de la combinación
--   PC-2026-000006  Bar                           26 líneas
--   No se puede sembrar hasta que la 000003 esté digitada.
-- =============================================================================


-- =============================================================================
-- PASO A — SIMULACRO (no escribe nada).
--
-- UNA sola corrida, sobre la sesión DESTINO ya combinada y cerrada
-- (PC-2026-000005 = 0a854976-91f3-4bf1-9895-de925c41a5a7 al 01-09, verificar
-- que siga siendo esa después de combinar). NO correr una vez por sesión: las
-- cinco son de la misma bodega y la apertura es una sola.
-- =============================================================================

select public.fn_inventory_seed_opening_layers('0a854976-91f3-4bf1-9895-de925c41a5a7'::uuid, true);

-- Devuelve:
--   lines            renglones que entrarían como capa
--   units            unidades
--   total_value      LA CIFRA que hay que cotejar con DH
--   estimated_lines  renglones SIN comprobante que los sustente
--   estimated_value  cuánto de ese valor no es defendible ante la DGII

-- Detalle artículo por artículo del simulacro, para mandárselo a DH.
select ii.sku,
       ii.name,
       ii.unit,
       l.counted_quantity                          as cantidad_contada,
       c.unit_cost                                 as costo_unitario,
       round(l.counted_quantity * coalesce(c.unit_cost,0), 2) as valor,
       c.document_number                           as ncf_o_factura,
       c.document_date                             as fecha_documento,
       s.name                                      as proveedor,
       case when c.is_estimated then 'SIN RESPALDO' else 'con comprobante' end
                                                   as sustento
  from public.physical_count_lines l
  join public.inventory_items ii on ii.id = l.item_id
  cross join lateral public.fn_inventory_last_invoiced_cost(
               ii.business_id, l.item_id) c
  left join public.suppliers s on s.id = c.supplier_id
 where l.session_id = '0a854976-91f3-4bf1-9895-de925c41a5a7'::uuid
   and coalesce(l.counted_quantity, 0) > 0
 order by (l.counted_quantity * coalesce(c.unit_cost,0)) desc;


-- =============================================================================
-- PASO B — SEMBRAR LA APERTURA. Escribe. UNA sola corrida, misma sesión que
-- el PASO A. La segunda corrida sobre la misma bodega rebota a propósito con
-- OPENING_LAYERS_EXIST.
-- =============================================================================

select public.fn_inventory_seed_opening_layers('0a854976-91f3-4bf1-9895-de925c41a5a7'::uuid, false);

-- Control: capas creadas por bodega.
select w.name                                as bodega,
       count(*)                              as capas,
       round(sum(l.quantity_remaining), 2)   as unidades,
       round(sum(l.quantity_remaining * l.unit_cost), 2) as valor,
       count(*) filter (where l.is_estimated) as sin_respaldo
  from public.inventory_cost_layers l
  join public.warehouses w on w.id = l.warehouse_id
 where l.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
   and l.source_type = 'opening'
 group by w.name
 order by valor desc;


-- =============================================================================
-- PASO C — ENCENDER UEPS. Una sola fila. Reversible con el mismo UPDATE.
-- =============================================================================

update public.business_settings
   set inventory_costing_method = 'lifo'
 where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6';

-- Para apagarlo si algo sale mal (las capas se conservan):
--   update public.business_settings
--      set inventory_costing_method = 'last_price'
--    where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6';


-- =============================================================================
-- PASO D — VERIFICAR (correr después de unas cuantas ventas reales)
-- =============================================================================

-- D1. Las ventas ya traen costo. Antes esta columna era NULL siempre.
select date_trunc('day', m.created_at)::date        as dia,
       count(*)                                     as salidas,
       count(*) filter (where m.cost_per_unit is not null) as con_costo,
       round(sum(abs(m.quantity) * coalesce(m.cost_per_unit,0)), 2)
                                                    as costo_de_venta
  from public.inventory_movements m
 where m.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
   and m.movement_type = 'sale'
   and m.quantity < 0
   and m.created_at >= date '2026-09-01'
 group by 1
 order by 1;

-- D2. Inventario valorado por capas vs. la valuación vieja (último precio).
--     La diferencia es la partida de conciliación que pide el informe.
select round(sum(value), 2)                as valor_por_capas,
       round(sum(value_at_last_price), 2)  as valor_ultimo_precio,
       round(sum(value_at_last_price) - sum(value), 2) as diferencia,
       round(sum(estimated_value), 2)      as porcion_sin_respaldo
  from public.v_inventory_valuation_layers
 where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6';

-- D3. Los artículos donde más se separan las dos cifras.
--     Aquí deben salir AZUCAR BLANCA y SACO DE CEBOLLA.
select item_sku, item_name, item_unit, quantity,
       effective_unit_cost, master_unit_cost,
       round(value, 2)                as valor_por_capas,
       round(value_at_last_price, 2)  as valor_ultimo_precio
  from public.v_inventory_valuation_layers
 where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
 order by abs(value_at_last_price - value) desc
 limit 25;

-- D4. Faltantes: salidas que no encontraron capa (los negativos).
select * from public.v_inventory_cost_shortfalls
 where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
 order by shortfall_value desc;

-- D5. Cuadre duro: capas abiertas vs. inventory_stock.
--     Solo deben aparecer artículos con negativos o movidos antes de sembrar.
select ii.sku, ii.name, w.name as bodega,
       round(coalesce(st.quantity, 0), 4)   as stock,
       round(coalesce(cap.qty, 0), 4)       as capas_abiertas,
       round(coalesce(st.quantity,0) - coalesce(cap.qty,0), 4) as diferencia
  from public.inventory_stock st
  join public.inventory_items ii on ii.id = st.item_id
  join public.warehouses w on w.id = st.warehouse_id
  left join (
    select item_id, warehouse_id, sum(quantity_remaining) as qty
      from public.inventory_cost_layers
     where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
     group by item_id, warehouse_id
  ) cap on cap.item_id = st.item_id and cap.warehouse_id = st.warehouse_id
 where ii.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
   and abs(coalesce(st.quantity,0) - coalesce(cap.qty,0)) > 0.0001
 order by abs(coalesce(st.quantity,0) - coalesce(cap.qty,0)) desc
 limit 50;
