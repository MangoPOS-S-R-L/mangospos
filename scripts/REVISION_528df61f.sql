-- =============================================================================
-- REVISION DE ESTADO — Business 528df61f-7136-4591-9e87-ee19f5882037
--                       ("EcoDome Village")
--
-- NO ESCRIBE NADA. Solo lee.
--
-- COMO CORRERLO: en Supabase Studio -> SQL Editor el editor muestra solo el
-- resultado del ULTIMO statement, asi que selecciona un bloque y dale Run,
-- bloque por bloque. En psql se puede pegar todo de una.
--
-- Consolida y actualiza a scripts/DIAGNOSTICO_528df61f.sql (catalogo) y
-- scripts/AREAS_diagnostico_528df61f.sql (areas), que eran de la carga vieja.
--
-- 11 bloques:
--   1. El negocio
--   2. Que catalogo esta vivo hoy (EcoDome 42 vs ECO BAR 625 vs vacio)
--   3. Productos ya vendidos (los que NO se pueden borrar)
--   4. Las areas de produccion, con impresoras y productos ruteados
--   5. Las impresoras y a que area estan pegadas
--   6. Cobertura de area de los productos — una linea
--   7. Productos SIN area, por categoria
--   8. Ruteo roto: legacy huerfano y desacuerdo N:M vs legacy
--   9. El catalogo por categoria, de un vistazo
--  10. Menus y enlace de productos al menu
--  11. Los productos que necesitan mano
-- =============================================================================


-- ---------------------------------------------------------------------------
-- 1) EL NEGOCIO
--    OJO: la columna del nombre es `business_name`, no `name`.
-- ---------------------------------------------------------------------------
select b.id, b.business_name, b.branch_name, b.business_type, b.country,
       b.domain, b.status, b.created_at,
       bs.inventory_mode, bs.service_fee_enabled
from public.businesses b
left join public.business_settings bs on bs.business_id = b.id
where b.id = '528df61f-7136-4591-9e87-ee19f5882037'::uuid;


-- ---------------------------------------------------------------------------
-- 2) QUE CATALOGO ESTA VIVO HOY
--    Como leerlo:
--      productos = 42  y sku_ecodome_42 = 42  -> entro el catalogo Loyverse
--                                                bueno (8 categorias).
--      productos = 625 y sku_ecodome_42 = 0   -> sigue vivo el import
--                                                equivocado de ECO BAR
--                                                (59 categorias).
--      productos = 0                          -> el rollback ya corrio y
--                                                falta IMPORT_ecodome.
--      mezcla de los dos                      -> rollback a medias.
--    sin_costo alto es lo esperado: Loyverse traia Cost 0.00 y se graba NULL.
-- ---------------------------------------------------------------------------
select
  count(*)                                                            as productos,
  count(*) filter (where mi.is_active)                                as activos,
  count(*) filter (where mi.sku ~ '^100(([0-3][0-9])|(4[0-1]))$')     as sku_ecodome_42,
  count(*) filter (where coalesce(mi.sku,'') <> ''
                     and mi.sku !~ '^100(([0-3][0-9])|(4[0-1]))$')    as sku_otros,
  count(*) filter (where coalesce(mi.sku,'') = '')                    as sin_sku,
  count(*) filter (where coalesce(mi.price,0) = 0)                    as precio_cero,
  count(*) filter (where mi.cost is null)                             as sin_costo,
  count(*) filter (where mi.tax_mode = 'inclusive')                   as inclusive,
  (select count(*) from public.categories c
    where c.business_id = '528df61f-7136-4591-9e87-ee19f5882037'::uuid) as categorias,
  min(mi.created_at)::date                                            as primer_producto,
  max(mi.created_at)::date                                            as ultimo_producto
from public.menu_items mi
where mi.business_id = '528df61f-7136-4591-9e87-ee19f5882037'::uuid;


-- ---------------------------------------------------------------------------
-- 3) PRODUCTOS YA VENDIDOS
--    Con ventas NO se borra: se desactiva (is_active = false). La FK de
--    order_items.product_id aborta el delete (RESTRICT) o desconecta el
--    historico en silencio (SET NULL), segun si la mig 20260902_0006 esta
--    aplicada en esta base.
-- ---------------------------------------------------------------------------
select count(distinct oi.product_id) as productos_con_ventas,
       count(*)                      as lineas_de_venta
from public.order_items oi
join public.menu_items mi on mi.id = oi.product_id
where mi.business_id = '528df61f-7136-4591-9e87-ee19f5882037'::uuid;


-- ---------------------------------------------------------------------------
-- 4) LAS AREAS DE PRODUCCION
--    De la columna `code` salen los valores del bloque >> de
--    scripts/AREAS_ecodome_528df61f.sql.
--    impr_comandas = 0 -> el area acepta el producto pero la comanda NO sale.
--    display_order y color se leen via jsonb porque los agrega la mig
--    20260521_0002 y no todas las bases la tienen (si no existe sale null,
--    no revienta con 42703).
-- ---------------------------------------------------------------------------
select a.code, a.name, a.is_active,
       (to_jsonb(a) ->> 'display_order')                as display_order,
       (to_jsonb(a) ->> 'color')                        as color,
       (select count(*) from public.print_area_printers pp
         where pp.area_id = a.id)                       as impresoras,
       (select count(*) from public.print_area_printers pp
         where pp.area_id = a.id and pp.enabled
           and pp.prints_orders)                        as impr_comandas,
       (select count(*) from public.menu_item_print_areas x
         where x.print_area_id = a.id)                  as productos_nm,
       (select count(*) from public.menu_items mi
         where mi.business_id = a.business_id
           and mi.print_area_code = a.code)             as productos_legacy
from public.print_areas a
where a.business_id = '528df61f-7136-4591-9e87-ee19f5882037'::uuid
order by a.code;


-- ---------------------------------------------------------------------------
-- 5) LAS IMPRESORAS Y A QUE AREA ESTAN PEGADAS
--    area = null -> impresora huerfana: no imprime comanda de ninguna area.
--    `purpose` y `transport` los agrega la mig 20260521_0001; se leen via
--    jsonb por la misma razon que arriba.
-- ---------------------------------------------------------------------------
select p.name as impresora, p.type,
       (to_jsonb(p) ->> 'purpose')                as purpose,
       (to_jsonb(p) ->> 'transport')              as transport,
       p.is_active, p.online, p.last_seen,
       coalesce(p.ip_address, host(p.ip))         as ip, p.port, p.paper_width,
       a.code as area, pp.priority, pp.enabled,
       pp.prints_orders, pp.prints_prebills, pp.prints_receipts
from public.printers p
left join public.print_area_printers pp on pp.printer_id = p.id
left join public.print_areas a          on a.id = pp.area_id
where p.business_id = '528df61f-7136-4591-9e87-ee19f5882037'::uuid
order by p.name, a.code;


-- ---------------------------------------------------------------------------
-- 6) COBERTURA DE AREA — UNA LINEA
--    El orden de resolucion real del codigo es: N:M primero, legacy despues,
--    asi que solo_legacy NO es un problema: rutea igual.
--    sin_area = productos que hacen fallar "Enviar a cocina" callado.
--    solo_nm = rutea bien por N:M, pero fn_add_item_from_menu copia el legacy
--    al order_item, asi que el KDS/comanda del item queda sin code.
-- ---------------------------------------------------------------------------
with mi as (
  select mi.id, mi.print_area_code,
         exists (select 1 from public.menu_item_print_areas x
                  where x.menu_item_id = mi.id)                       as tiene_nm,
         exists (select 1 from public.print_areas a
                  where a.business_id = mi.business_id
                    and a.code = mi.print_area_code)                  as legacy_valido
  from public.menu_items mi
  where mi.business_id = '528df61f-7136-4591-9e87-ee19f5882037'::uuid
)
select
  count(*)                                                            as productos,
  count(*) filter (where tiene_nm)                                    as con_area_nm,
  count(*) filter (where coalesce(print_area_code,'') <> '')           as con_code_legacy,
  count(*) filter (where tiene_nm
                     and coalesce(print_area_code,'') <> '')           as ambos,
  count(*) filter (where tiene_nm
                     and coalesce(print_area_code,'') = '')            as solo_nm,
  count(*) filter (where not tiene_nm
                     and coalesce(print_area_code,'') <> '')           as solo_legacy,
  count(*) filter (where coalesce(print_area_code,'') <> ''
                     and not legacy_valido)                           as legacy_roto,
  count(*) filter (where not tiene_nm
                     and coalesce(print_area_code,'') = '')            as sin_area
from mi;


-- ---------------------------------------------------------------------------
-- 7) PRODUCTOS SIN AREA, POR CATEGORIA
--    Esto es lo que falta rutear. Con las areas sembradas debe salir vacio.
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
-- 8) RUTEO ROTO — las dos formas. Ambas deben dar 0 filas.
--    8a: print_area_code apunta a un code que no existe -> rutea al vacio.
--    8b: el legacy dice un area que el N:M no tiene -> segun por donde entre
--        el item, la comanda sale en dos cocinas distintas.
-- ---------------------------------------------------------------------------
select '8a legacy huerfano' as caso, mi.sku, mi.name, mi.print_area_code as legacy, null::text as nm
from public.menu_items mi
where mi.business_id = '528df61f-7136-4591-9e87-ee19f5882037'::uuid
  and coalesce(mi.print_area_code, '') <> ''
  and not exists (select 1 from public.print_areas a
                   where a.business_id = mi.business_id and a.code = mi.print_area_code)
union all
select '8b desacuerdo N:M vs legacy', mi.sku, mi.name, mi.print_area_code,
       (select string_agg(a.code, '+' order by a.code)
          from public.menu_item_print_areas x
          join public.print_areas a on a.id = x.print_area_id
         where x.menu_item_id = mi.id)
from public.menu_items mi
where mi.business_id = '528df61f-7136-4591-9e87-ee19f5882037'::uuid
  and coalesce(mi.print_area_code, '') <> ''
  -- solo cuenta como desacuerdo si el producto SI tiene N:M: sin filas N:M el
  -- codigo cae al legacy y eso es una config valida, no un split-brain.
  and exists (select 1 from public.menu_item_print_areas x
               where x.menu_item_id = mi.id)
  and not exists (select 1 from public.menu_item_print_areas x
                   join public.print_areas a on a.id = x.print_area_id
                  where x.menu_item_id = mi.id and a.code = mi.print_area_code)
order by 1, 3;


-- ---------------------------------------------------------------------------
-- 9) EL CATALOGO POR CATEGORIA, DE UN VISTAZO
--    con_impuesto = 0 es LO DECIDIDO por el dueno (los precios de Loyverse
--    ya son finales). con_impuesto en 0 significa ITBIS 0.00 en la factura:
--    menu_item_taxes es la unica fuente del impuesto.
--    en_menu = 0 con un menu activo -> la pantalla del POS sale VACIA.
-- ---------------------------------------------------------------------------
select coalesce(c.name, '(sin categoria)') as categoria,
       count(*)                                                        as productos,
       count(*) filter (where mi.is_active)                            as activos,
       count(*) filter (where coalesce(mi.price,0) = 0)                as precio_0,
       min(mi.price)                                                   as precio_min,
       max(mi.price)                                                   as precio_max,
       count(*) filter (where exists (select 1 from public.menu_item_print_areas x
                                       where x.menu_item_id = mi.id))  as con_area_nm,
       count(*) filter (where coalesce(mi.print_area_code,'') <> '')    as con_code_legacy,
       count(*) filter (where exists (select 1 from public.menu_item_taxes t
                                       where t.item_id = mi.id))       as con_impuesto,
       count(*) filter (where exists (select 1 from public.menu_item_links l
                                       where l.item_id = mi.id))       as en_menu
from public.menu_items mi
left join public.categories c on c.id = mi.category_id
where mi.business_id = '528df61f-7136-4591-9e87-ee19f5882037'::uuid
group by 1
order by 1;


-- ---------------------------------------------------------------------------
-- 10) MENUS Y ENLACE AL MENU
--     El POS filtra por menu (v_menu_items_list.eq('menu_id'), sacado de
--     menu_item_links). Un producto sin fila aqui existe pero no se ve.
-- ---------------------------------------------------------------------------
select m.id, m.name, m.is_active, m.created_at,
       (select count(*) from public.menu_item_links l where l.menu_id = m.id) as items_enlazados
from public.menus m
where m.business_id = '528df61f-7136-4591-9e87-ee19f5882037'::uuid
order by m.created_at;

select count(*) as productos_fuera_de_todo_menu
from public.menu_items mi
where mi.business_id = '528df61f-7136-4591-9e87-ee19f5882037'::uuid
  and not exists (select 1 from public.menu_item_links l where l.item_id = mi.id);


-- ---------------------------------------------------------------------------
-- 11) LOS PRODUCTOS QUE NECESITAN MANO
--     Precio 0, inactivos, sin area o fuera del menu. En el catalogo EcoDome
--     se espera exactamente 1 inactivo: 'Plato del dia - Nino' (sku 10028),
--     que en Loyverse traia el precio literal "variable".
-- ---------------------------------------------------------------------------
select mi.sku, mi.name, mi.price, mi.is_active,
       coalesce(c.name, '(sin categoria)') as categoria,
       mi.print_area_code as legacy,
       (select string_agg(a.code, '+' order by a.code)
          from public.menu_item_print_areas x
          join public.print_areas a on a.id = x.print_area_id
         where x.menu_item_id = mi.id) as areas_nm,
       exists (select 1 from public.menu_item_links l where l.item_id = mi.id) as en_menu,
       exists (select 1 from public.menu_item_taxes t where t.item_id = mi.id) as con_impuesto
from public.menu_items mi
left join public.categories c on c.id = mi.category_id
where mi.business_id = '528df61f-7136-4591-9e87-ee19f5882037'::uuid
  and (
    coalesce(mi.price,0) = 0
    or not mi.is_active
    or (coalesce(mi.print_area_code,'') = ''
        and not exists (select 1 from public.menu_item_print_areas x
                         where x.menu_item_id = mi.id))
    or not exists (select 1 from public.menu_item_links l where l.item_id = mi.id)
  )
order by mi.name
limit 200;
