-- =============================================================================
-- VERIFICAR — Modificadores que descuentan insumos
-- Correr DESPUÉS de aplicar 20260907_0001 / 0002 / 0003.
-- =============================================================================

-- (1) Cómo quedó configurado cada modificador. Positivo = descuenta,
--     negativo = anula lo que la receta base del producto descontaría.
select b.legal_name,
       mg.name  as grupo,
       m.name   as modificador,
       ii.name  as insumo,
       mi.quantity,
       mi.unit,
       case when mi.quantity >= 0 then 'descuenta' else 'quita' end as efecto
from public.modifier_ingredients mi
join public.modifiers m        on m.id = mi.modifier_id
left join public.modifier_groups mg on mg.id = m.group_id
join public.inventory_items ii on ii.id = mi.inventory_item_id
join public.businesses b       on b.id = m.business_id
order by b.legal_name, mg.name, m.name, ii.name;

-- (2) ¿Las ventas nuevas están guardando la identidad del modificador?
--     Si `con_modifier_id` queda en 0 después de vender con modificadores, la
--     app está corriendo un build viejo (o falló el insert y cayó al reintento
--     sin la columna).
select count(*)                                          as filas_hoy,
       count(*) filter (where oim.modifier_id is not null) as con_modifier_id,
       count(*) filter (where oim.menu_item_id is not null) as con_menu_item_id
from public.order_item_modifiers oim
join public.order_items oi on oi.id = oim.item_id
where oi.created_at >= current_date - interval '1 day';

-- (3) Lo que una orden movió de inventario, renglón por renglón.
--     Cambia el id por el de la orden que quieras auditar.
select im.created_at,
       ii.name as insumo,
       w.name  as bodega,
       im.quantity,
       im.notes
from public.inventory_movements im
join public.inventory_items ii on ii.id = im.item_id
join public.warehouses w       on w.id = im.warehouse_id
where im.reference_type = 'order'
  and im.reference_id = '00000000-0000-0000-0000-000000000000'::uuid
order by im.created_at;

-- (4) Recalcular el consumo de esa orden (es idempotente: solo escribe la
--     diferencia). Útil para probar sin volver a vender.
-- select public.consume_inventory_from_order(
--   '00000000-0000-0000-0000-000000000000'::uuid);
