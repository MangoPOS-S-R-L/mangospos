-- MAX PÍCAME EL POLLO: los productos que ya hay, con impuestos, área y ventas (solo lee).
select c.name as categoria,
       mi.name as producto,
       mi.price as precio,
       mi.tax_mode,
       coalesce((select string_agg(t.name || ' ' || t.rate || '%', ' + ' order by t.rate desc)
                 from public.menu_item_taxes x join public.taxes t on t.id = x.tax_id
                 where x.item_id = mi.id), 'SIN IMPUESTO') as impuestos,
       coalesce((select string_agg(a.name, ', ')
                 from public.menu_item_print_areas x join public.print_areas a on a.id = x.print_area_id
                 where x.menu_item_id = mi.id), '—') as area,
       (select count(*) from public.order_items oi where oi.product_id = mi.id) as veces_vendido,
       (select max(oi.created_at)::date from public.order_items oi where oi.product_id = mi.id) as ultima_venta,
       mi.created_at::date as creado
from public.menu_items mi
left join public.categories c on c.id = mi.category_id
where mi.business_id = 'd16497fa-4853-41e3-8566-4d0565511f37'::uuid
order by c.position, mi.name;
