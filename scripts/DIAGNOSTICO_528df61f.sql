-- =============================================================================
-- DIAGNOSTICO PREVIO — Business 528df61f-7136-4591-9e87-ee19f5882037
-- NO ESCRIBE NADA. Correr ANTES de import_products_528df61f.sql.
--
-- Que mirar en cada resultado:
--   1. El negocio existe y es el que crees. inventory_mode y
--      service_fee_enabled son informativos: este import no los toca.
--   2. print_areas — hacen falta un area de COCINA y una de BARRA. Sus
--      `code` van copiados en seed_business_528df61f_print_areas.sql. Si no
--      existen, crealas primero desde Ajustes -> Areas de impresion; un
--      area con 0 impresoras acepta el producto pero la comanda no sale.
--   3. Catalogo actual — con 0 productos el import entra limpio. Si ya hay,
--      corre COMPARAR_catalogo_528df61f.sql para ver que se actualiza.
--   4. Menus — si no hay ninguno activo, el import crea 'MENU PRINCIPAL'.
--   5. Impuestos — informativo. Este import NO enlaza ninguno, a proposito.
-- =============================================================================

-- 1) El negocio
select b.id, b.business_name, b.branch_name, b.business_type, b.domain,
       b.status, bs.inventory_mode, bs.service_fee_enabled
from public.businesses b
left join public.business_settings bs on bs.business_id = b.id
where b.id = '528df61f-7136-4591-9e87-ee19f5882037'::uuid;

-- 2) Areas de impresion — de aqui salen los `code` del script de areas
select a.code, a.name, a.is_active,
       (select count(*) from public.print_area_printers pp
         where pp.area_id = a.id) as impresoras
from public.print_areas a
where a.business_id = '528df61f-7136-4591-9e87-ee19f5882037'::uuid
order by a.code;

-- 3) Catalogo actual
select count(*) as productos,
       count(*) filter (where mi.sku is not null and btrim(mi.sku) <> '') as con_sku,
       count(*) filter (where mi.is_active) as activos,
       count(*) filter (where mi.tax_mode = 'inclusive') as inclusive,
       (select count(*) from public.categories c
         where c.business_id = '528df61f-7136-4591-9e87-ee19f5882037'::uuid) as categorias
from public.menu_items mi
where mi.business_id = '528df61f-7136-4591-9e87-ee19f5882037'::uuid;

-- 4) Menus
select m.id, m.name, m.is_active,
       (select count(*) from public.menu_item_links l where l.menu_id = m.id) as items
from public.menus m
where m.business_id = '528df61f-7136-4591-9e87-ee19f5882037'::uuid
order by m.created_at;

-- 5) Impuestos del negocio (informativo: NO se enlaza ninguno)
select t.name, t.rate, t.is_active,
       (select count(*) from public.menu_item_taxes x
          join public.menu_items mi on mi.id = x.item_id
         where x.tax_id = t.id and mi.business_id = t.business_id) as productos_enlazados
from public.taxes t
where t.business_id = '528df61f-7136-4591-9e87-ee19f5882037'::uuid
order by t.name;
