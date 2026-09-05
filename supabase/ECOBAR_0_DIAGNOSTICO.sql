-- =============================================================================
-- ECO BAR & LOUNGE — foto del estado ACTUAL, antes de tocar nada.
-- Negocio: fc3065c8-cb40-45ad-bec1-aecb388001c1
-- Solo lee. Corre esto primero; si algo se ve raro, pásame los resultados.
-- =============================================================================

-- 1. ¿Es el negocio que creemos?
select id, business_name, branch_name, business_type, country, status
  from public.businesses
 where id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1';


-- 2. Menú actual: cuánto hay y cuánto de eso ya se vendió.
--    Lo vendido NO se puede borrar sin romper el histórico fiscal.
select count(*)                                                    as productos,
       count(*) filter (where is_active)                           as activos,
       count(*) filter (where exists (
         select 1 from public.order_items oi where oi.product_id = menu_items.id
       ))                                                          as con_ventas,
       count(*) filter (where not exists (
         select 1 from public.order_items oi where oi.product_id = menu_items.id
       ))                                                          as sin_ventas_borrables
  from public.menu_items
 where business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1';


-- 3. Categorías actuales.
select c.position, c.name, c.is_active, count(mi.id) as productos
  from public.categories c
  left join public.menu_items mi on mi.category_id = c.id
 where c.business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1'
 group by c.position, c.name, c.is_active
 order by c.position;


-- 4. Impuestos del negocio y a cuántos productos está vinculado cada uno.
--    menu_item_taxes es la ÚNICA fuente del ITBIS: sin vínculo, factura en 0.
select t.id, t.name, t.rate, t.is_active,
       (select count(*) from public.menu_item_taxes mit
          join public.menu_items mi on mi.id = mit.item_id
         where mit.tax_id = t.id and mi.is_active)                  as productos_activos_vinculados
  from public.taxes t
 where t.business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1'
 order by t.is_active desc, t.rate desc;


-- 5. Áreas de impresión configuradas. Sin esto, "Enviar a cocina" rechaza todo.
select id, code, name, is_active,
       (select count(*) from public.menu_item_print_areas p
         where p.print_area_id = print_areas.id)                    as productos_asignados
  from public.print_areas
 where business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1'
 order by is_active desc, code;


-- 6. ¿Hay cuentas abiertas ahora mismo? Si sale > 0, NO cambies el menú todavía.
select count(distinct o.id) as ordenes_abiertas
  from public.orders o
  join public.order_items oi on oi.order_id = o.id
  join public.menu_items mi on mi.id = oi.product_id
 where mi.business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1'
   and o.status = 'open';


-- 7. Ataduras que complican el borrado. Va por dentro de un DO porque
--    combo_group_items / is_inventory_tracked no existen en toda instalación,
--    y una tabla ausente abortaría el script entero.
drop table if exists _eco_diag;
create temp table _eco_diag(metrica text, valor bigint);

do $$
declare v_biz constant uuid := 'fc3065c8-cb40-45ad-bec1-aecb388001c1';
begin
  insert into _eco_diag
  select 'productos_con_receta', count(*)
    from public.recipes r
    join public.menu_items mi on mi.id = r.menu_item_id
   where mi.business_id = v_biz;

  insert into _eco_diag
  select 'productos_en_orden_abierta_o_borrador', count(distinct oi.product_id)
    from public.order_items oi
    join public.menu_items mi on mi.id = oi.product_id
   where mi.business_id = v_biz and oi.status = 'draft';

  if to_regclass('public.combo_group_items') is not null then
    execute format($f$
      insert into _eco_diag
      select 'productos_dentro_de_combos', count(*)
        from public.combo_group_items cgi
        join public.menu_items mi on mi.id = cgi.menu_item_id
       where mi.business_id = %L $f$, v_biz);
  end if;

  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'menu_items'
                and column_name = 'is_inventory_tracked') then
    execute format($f$
      insert into _eco_diag
      select 'productos_inventariables', count(*)
        from public.menu_items
       where business_id = %L and is_inventory_tracked $f$, v_biz);
  end if;
end $$;

select * from _eco_diag;


-- 8. Qué regla tiene hoy la FK de ventas → producto.
--    RESTRICT  = borrar un producto vendido FALLA (bien).
--    SET NULL  = borrar desconecta las ventas EN SILENCIO (peligroso).
select conname, pg_get_constraintdef(oid) as definicion
  from pg_constraint
 where conrelid = 'public.order_items'::regclass
   and conname = 'order_items_product_id_fkey';
