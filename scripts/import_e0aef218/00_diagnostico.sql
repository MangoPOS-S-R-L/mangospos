-- ============================================================================
-- BARRA PAYÁN — DIAGNÓSTICO PREVIO.  Business e0aef218-ab95-4ba4-b8ef-036fab1c07c7
--
-- CORRE ESTO PRIMERO Y PÉGAME EL RESULTADO. No escribe nada.
-- Confirma las 4 cosas de las que depende el import:
--   1) el negocio existe y está activo
--   2) el ITBIS 18% existe, está activo y es único por nombre
--   3) las áreas JUGUERA y SANDWICHERA existen y tienen su `code`
--   4) el catálogo está vacío (o qué hay ya, para no duplicar)
-- ============================================================================

-- 1) El negocio
select id, business_name, branch_name, business_type, country,
       status, domain, created_at
from public.businesses
where id = 'e0aef218-ab95-4ba4-b8ef-036fab1c07c7'::uuid;

-- 2) Impuestos configurados.
--    Espero ver un ITBIS 18% activo. OJO con is_service_fee: debe ser FALSE.
select id, name, rate, is_active, is_service_fee,
       apply_on_zone, apply_on_manual, apply_on_quick,
       apply_on_takeout, apply_on_delivery
from public.taxes
where business_id = 'e0aef218-ab95-4ba4-b8ef-036fab1c07c7'::uuid
order by name;

-- 3) Áreas de comanda. Necesito el `code` exacto de JUGUERA y SANDWICHERA.
select a.id, a.name, a.code, a.is_active,
       count(pap.printer_id) as impresoras
from public.print_areas a
left join public.print_area_printers pap on pap.area_id = a.id
where a.business_id = 'e0aef218-ab95-4ba4-b8ef-036fab1c07c7'::uuid
group by a.id, a.name, a.code, a.is_active
order by a.name;

-- 4) ¿Ya hay catálogo? Espero 0 en todo.
select
  (select count(*) from public.categories
     where business_id = 'e0aef218-ab95-4ba4-b8ef-036fab1c07c7'::uuid) as categorias,
  (select count(*) from public.menu_items
     where business_id = 'e0aef218-ab95-4ba4-b8ef-036fab1c07c7'::uuid) as productos,
  (select count(*) from public.modifier_groups
     where business_id = 'e0aef218-ab95-4ba4-b8ef-036fab1c07c7'::uuid) as grupos_modificadores;

-- 4b) Si productos > 0, esto dice cuáles son (para decidir si chocan).
select mi.name, mi.price, mi.tax_mode, c.name as categoria
from public.menu_items mi
left join public.categories c on c.id = mi.category_id
where mi.business_id = 'e0aef218-ab95-4ba4-b8ef-036fab1c07c7'::uuid
order by c.name, mi.name;

-- 5) Ajustes del negocio. `service_fee_enabled` debe estar en FALSE:
--    no cobran Ley 10%, y encendido cobraría un 10% por orden que el menú
--    no anuncia. Va con select * porque esta tabla difiere entre entornos.
select * from public.business_settings
where business_id = 'e0aef218-ab95-4ba4-b8ef-036fab1c07c7'::uuid;
