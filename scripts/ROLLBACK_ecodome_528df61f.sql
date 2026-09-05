-- =============================================================================
-- ROLLBACK del import ECODOME — Business 528df61f-7136-4591-9e87-ee19f5882037
--
-- Borra los 42 productos que metio IMPORT_ecodome_528df61f.sql, y NADA mas:
-- el filtro es la lista de sku del archivo.
--
-- Se van en cascada con el producto: menu_item_links, menu_item_print_areas,
-- menu_item_taxes, menu_item_groups, recipes.
--
-- LO QUE PUEDE BLOQUEAR — a proposito:
--   order_items.product_id -> ON DELETE RESTRICT. Si el producto YA SE
--   VENDIO, Postgres aborta todo. Un producto con historial no se borra, se
--   DESACTIVA. El paso 1 te avisa antes.
--
-- CORRER POR PARTES. El paso 1 no escribe nada.
-- =============================================================================


-- ###########################################################################
-- PASO 1 — QUE SE VA A BORRAR (no escribe nada)
-- ###########################################################################
begin;
create temp table _sku (sku text primary key) on commit drop;
insert into _sku (sku) values
  ('10020'),
  ('10030'),
  ('10033'),
  ('10014'),
  ('10005'),
  ('10013'),
  ('10023'),
  ('10029'),
  ('10025'),
  ('10024'),
  ('10018'),
  ('10009'),
  ('10036'),
  ('10016'),
  ('10041'),
  ('10011'),
  ('10015'),
  ('10002'),
  ('10022'),
  ('10021'),
  ('10003'),
  ('10004'),
  ('10017'),
  ('10032'),
  ('10031'),
  ('10035'),
  ('10034'),
  ('10001'),
  ('10027'),
  ('10026'),
  ('10028'),
  ('10000'),
  ('10037'),
  ('10012'),
  ('10039'),
  ('10040'),
  ('10010'),
  ('10019'),
  ('10038'),
  ('10007'),
  ('10006'),
  ('10008');

select
  (select count(*) from public.menu_items mi
    where mi.business_id = '528df61f-7136-4591-9e87-ee19f5882037'::uuid) as productos_del_negocio,
  (select count(*) from public.menu_items mi join _sku s on s.sku = mi.sku
    where mi.business_id = '528df61f-7136-4591-9e87-ee19f5882037'::uuid) as se_borrarian,
  (select count(*) from public.order_items oi
     join public.menu_items mi on mi.id = oi.product_id
     join _sku s on s.sku = mi.sku
    where mi.business_id = '528df61f-7136-4591-9e87-ee19f5882037'::uuid) as lineas_de_venta_que_bloquean;

select mi.sku, mi.name, count(*) as veces_vendido
from public.menu_items mi
join _sku s on s.sku = mi.sku
join public.order_items oi on oi.product_id = mi.id
where mi.business_id = '528df61f-7136-4591-9e87-ee19f5882037'::uuid
group by mi.sku, mi.name order by count(*) desc, mi.name;
commit;


-- ###########################################################################
-- PASO 2 — BORRAR. Solo si el paso 1 dio lineas_de_venta_que_bloquean = 0.
-- ###########################################################################
begin;
create temp table _sku (sku text primary key) on commit drop;
insert into _sku (sku) values
  ('10020'),
  ('10030'),
  ('10033'),
  ('10014'),
  ('10005'),
  ('10013'),
  ('10023'),
  ('10029'),
  ('10025'),
  ('10024'),
  ('10018'),
  ('10009'),
  ('10036'),
  ('10016'),
  ('10041'),
  ('10011'),
  ('10015'),
  ('10002'),
  ('10022'),
  ('10021'),
  ('10003'),
  ('10004'),
  ('10017'),
  ('10032'),
  ('10031'),
  ('10035'),
  ('10034'),
  ('10001'),
  ('10027'),
  ('10026'),
  ('10028'),
  ('10000'),
  ('10037'),
  ('10012'),
  ('10039'),
  ('10040'),
  ('10010'),
  ('10019'),
  ('10038'),
  ('10007'),
  ('10006'),
  ('10008');

delete from public.menu_items mi
using _sku s
where mi.sku = s.sku
  and mi.business_id = '528df61f-7136-4591-9e87-ee19f5882037'::uuid;

select count(*) as productos_restantes from public.menu_items
 where business_id = '528df61f-7136-4591-9e87-ee19f5882037'::uuid;
commit;
