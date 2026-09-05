-- =============================================================================
-- AREAS DE PRODUCCION — Business 528df61f-7136-4591-9e87-ee19f5882037
-- NO ESCRIBE NADA. Correr en Supabase Studio -> SQL Editor.
--
-- El import de catalogo ya entro (625 productos). Falta el ruteo a areas:
-- un producto sin area deja print_area_code NULL y "Enviar a cocina" se
-- bloquea sin decir por que. Esto te dice que hay hoy y que falta.
--
-- Devuelve 6 resultados:
--   1. Resumen de una linea
--   2. Las areas del negocio, con impresoras y productos ya ruteados
--   3. Las impresoras del negocio y a que area estan pegadas
--   4. Productos SIN area, agrupados por categoria (lo que falta rutear)
--   5. print_area_code legacy que apunta a un code inexistente
--   6. Desacuerdos entre el N:M y el legacy
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1) Resumen. Lo esperado ANTES de correr seed_business_528df61f_print_areas:
--    areas >= 2 (cocina y bar), productos = 625, sin_area = 625.
--    DESPUES: sin_area = 0 y rutas_nm = 631 (625 + 6 combos a dos areas).
-- ---------------------------------------------------------------------------
select
  (select count(*) from public.print_areas a
    where a.business_id = '528df61f-7136-4591-9e87-ee19f5882037'::uuid) as areas,
  (select count(*) from public.print_areas a
    where a.business_id = '528df61f-7136-4591-9e87-ee19f5882037'::uuid
      and coalesce(a.is_active, true)) as areas_activas,
  (select count(*) from public.printers p
    where p.business_id = '528df61f-7136-4591-9e87-ee19f5882037'::uuid) as impresoras,
  (select count(*) from public.menu_items mi
    where mi.business_id = '528df61f-7136-4591-9e87-ee19f5882037'::uuid) as productos,
  (select count(*) from public.menu_item_print_areas x
    join public.menu_items mi on mi.id = x.menu_item_id
    where mi.business_id = '528df61f-7136-4591-9e87-ee19f5882037'::uuid) as rutas_nm,
  (select count(*) from public.menu_items mi
    where mi.business_id = '528df61f-7136-4591-9e87-ee19f5882037'::uuid
      and coalesce(mi.print_area_code, '') <> '') as con_code_legacy,
  (select count(*) from public.menu_items mi
    where mi.business_id = '528df61f-7136-4591-9e87-ee19f5882037'::uuid
      and coalesce(mi.print_area_code, '') = ''
      and not exists (select 1 from public.menu_item_print_areas x
                       where x.menu_item_id = mi.id)) as sin_area;

-- ---------------------------------------------------------------------------
-- 2) Las areas. De la columna `code` salen los dos valores que hay que poner
--    en el bloque marcado con >> de seed_business_528df61f_print_areas.sql.
--    Un area con impresoras = 0 acepta el producto pero la comanda no sale.
-- ---------------------------------------------------------------------------
select a.code, a.name, a.is_active, a.display_order,
       (select count(*) from public.print_area_printers pp
         where pp.area_id = a.id) as impresoras,
       (select count(*) from public.print_area_printers pp
         where pp.area_id = a.id and pp.enabled and pp.prints_orders) as impr_comandas,
       (select count(*) from public.menu_item_print_areas x
         where x.print_area_id = a.id) as productos_nm,
       (select count(*) from public.menu_items mi
         where mi.business_id = a.business_id and mi.print_area_code = a.code) as productos_legacy
from public.print_areas a
where a.business_id = '528df61f-7136-4591-9e87-ee19f5882037'::uuid
order by a.display_order, a.code;

-- ---------------------------------------------------------------------------
-- 3) Impresoras del negocio y a que area(s) estan pegadas.
--    area = NULL -> impresora huerfana: no imprime comanda de ninguna area.
-- ---------------------------------------------------------------------------
select p.name as impresora, p.type, p.purpose, p.is_active, p.online,
       coalesce(p.ip_address, host(p.ip)) as ip, p.port,
       a.code as area, pp.priority, pp.enabled,
       pp.prints_orders, pp.prints_prebills, pp.prints_receipts
from public.printers p
left join public.print_area_printers pp on pp.printer_id = p.id
left join public.print_areas a on a.id = pp.area_id
where p.business_id = '528df61f-7136-4591-9e87-ee19f5882037'::uuid
order by p.name, a.code;

-- ---------------------------------------------------------------------------
-- 4) Productos SIN area, por categoria. Esto es lo que falta rutear.
--    Con el script de areas esta lista debe quedar vacia.
-- ---------------------------------------------------------------------------
select coalesce(c.name, '(sin categoria)') as categoria, count(*) as productos
from public.menu_items mi
left join public.categories c on c.id = mi.category_id
where mi.business_id = '528df61f-7136-4591-9e87-ee19f5882037'::uuid
  and coalesce(mi.print_area_code, '') = ''
  and not exists (select 1 from public.menu_item_print_areas x
                   where x.menu_item_id = mi.id)
group by 1
order by 2 desc, 1;

-- ---------------------------------------------------------------------------
-- 5) Legacy roto: print_area_code que apunta a un code que no existe.
--    Debe dar 0 filas. Si sale algo, ese producto rutea al vacio.
-- ---------------------------------------------------------------------------
select mi.sku, mi.name, mi.print_area_code
from public.menu_items mi
where mi.business_id = '528df61f-7136-4591-9e87-ee19f5882037'::uuid
  and coalesce(mi.print_area_code, '') <> ''
  and not exists (
    select 1 from public.print_areas a
    where a.business_id = mi.business_id and a.code = mi.print_area_code
  )
order by mi.name;

-- ---------------------------------------------------------------------------
-- 6) Desacuerdo entre los dos mecanismos: el legacy dice un area que el N:M
--    no tiene. Debe dar 0 filas — si no, un bache de red rutea a otra cocina.
-- ---------------------------------------------------------------------------
select mi.sku, mi.name, mi.print_area_code as legacy,
       (select string_agg(a.code, '+' order by a.code)
          from public.menu_item_print_areas x
          join public.print_areas a on a.id = x.print_area_id
         where x.menu_item_id = mi.id) as nm
from public.menu_items mi
where mi.business_id = '528df61f-7136-4591-9e87-ee19f5882037'::uuid
  and coalesce(mi.print_area_code, '') <> ''
  and not exists (
    select 1 from public.menu_item_print_areas x
    join public.print_areas a on a.id = x.print_area_id
    where x.menu_item_id = mi.id and a.code = mi.print_area_code
  )
order by mi.name;
