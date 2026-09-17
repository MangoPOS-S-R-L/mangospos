-- =============================================================================
-- ROLLBACK del import de la cotizacion Vocatus S44868
-- Negocio: 6d13ed3f-0fb9-40e3-a695-f4c09759fbfd
--
-- Borra los 19 productos cargados. Si alguno YA SE VENDIO, aborta completo:
-- no se borra un producto que tiene ventas, se desactiva.
--
-- Las categorias solo se borran si quedaron vacias Y se crearon hoy.
--
-- OJO: borra por NOMBRE. Si alguno de esos 19 nombres ya existia en el
-- catalogo antes del import, tambien se lo lleva (por eso el candado de
-- ventas). Si el diagnostico te dijo que alguno ya existia, saca esa
-- linea de la lista antes de correr esto.
-- =============================================================================

begin;

create temp table _f on commit drop as
select v.name,
       upper(btrim(regexp_replace(translate(v.name, 'ÁÉÍÓÚÜÑÀÈÌÒÙÂÊÎÔÛáéíóúüñàèìòùâêîôû', 'AEIOUUNAEIOUAEIOUaeiouunaeiouaeiou'), '\s+', ' ', 'g'))) as k
from (values
  ('Agua Cascada Vocatus 500Ml'), ('Evian Sparkling 330Ml'),
  ('Moet & Chandon Ice Imperial 750Ml'), ('Red Bull 250Ml'),
  ('Jugo Motts 32Oz'), ('Agua De Coco Goya 350Ml'),
  ('Coca Cola 400Ml'), ('Sprite 400Ml'),
  ('Barcelo Imperial 750Ml'), ('Barcelo Now 750Ml'),
  ('Soda Amarga Canada Dry 400Ml'),
  ('Don Julio 1942 750Ml'), ('Don Julio Reposado 750Ml'),
  ('Johnnie Blue Label 750Ml'), ('Johnnie Gold Label Reserva 750Ml'),
  ('Johnnie Negro 750Ml'), ('Johnnie Walker 18 750Ml'),
  ('Old Parr 12 Años 750Ml'), ('Old Parr 18 Años 750Ml')
) as v(name);

create temp table _ids on commit drop as
select mi.id, mi.name, mi.category_id
from public.menu_items mi
join _f f on f.k = upper(btrim(regexp_replace(translate(mi.name, 'ÁÉÍÓÚÜÑÀÈÌÒÙÂÊÎÔÛáéíóúüñàèìòùâêîôû', 'AEIOUUNAEIOUAEIOUaeiouunaeiouaeiou'), '\s+', ' ', 'g')))
where mi.business_id = '6d13ed3f-0fb9-40e3-a695-f4c09759fbfd';

do $$
declare n int; ejemplos text;
begin
  select count(*), string_agg(distinct i.name, ' | ')
    into n, ejemplos
  from _ids i
  where exists (select 1 from public.order_items oi where oi.product_id = i.id);
  if n > 0 then
    raise exception 'ABORTA: % de esos productos YA TIENEN VENTAS (%). Desactivalos en vez de borrarlos.', n, left(coalesce(ejemplos,''), 300);
  end if;
end $$;

delete from public.menu_item_taxes where item_id in (select id from _ids);
delete from public.menu_item_links where item_id in (select id from _ids);
delete from public.menu_items     where id      in (select id from _ids);

delete from public.categories c
where c.business_id = '6d13ed3f-0fb9-40e3-a695-f4c09759fbfd'
  and c.created_at >= now() - interval '24 hours'
  and c.id in (select distinct category_id from _ids where category_id is not null)
  and not exists (select 1 from public.menu_items mi where mi.category_id = c.id);

select (select count(*) from _ids) as productos_borrados,
       (select count(*) from public.menu_items where business_id = '6d13ed3f-0fb9-40e3-a695-f4c09759fbfd') as quedan_en_catalogo;

commit;
