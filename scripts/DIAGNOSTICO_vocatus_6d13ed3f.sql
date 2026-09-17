-- =============================================================================
-- DIAGNOSTICO — antes de cargar la cotizacion S44868 (Vocatus)
-- Negocio: 6d13ed3f-0fb9-40e3-a695-f4c09759fbfd
--
-- Correr TAL CUAL en Supabase Studio -> SQL Editor.
-- Es UNA sola consulta a proposito: el editor solo muestra el ultimo resultado.
-- No escribe nada.
-- =============================================================================

with
bid as (select '6d13ed3f-0fb9-40e3-a695-f4c09759fbfd'::uuid as id),

-- Las 19 lineas de la cotizacion, con su categoria destino
f(name, cat) as (values
  ('Agua Cascada Vocatus 500Ml',        'AGUAS'),
  ('Evian Sparkling 330Ml',             'AGUAS'),
  ('Moet & Chandon Ice Imperial 750Ml', 'CHAMPAGNE'),
  ('Red Bull 250Ml',                    'ENERGIZANTES'),
  ('Jugo Motts 32Oz',                   'JUGOS'),
  ('Agua De Coco Goya 350Ml',           'PROVISIONES'),
  ('Coca Cola 400Ml',                   'REFRESCOS'),
  ('Sprite 400Ml',                      'REFRESCOS'),
  ('Barcelo Imperial 750Ml',            'RONES'),
  ('Barcelo Now 750Ml',                 'RONES'),
  ('Soda Amarga Canada Dry 400Ml',      'SODAS Y TONICAS'),
  ('Don Julio 1942 750Ml',              'TEQUILAS'),
  ('Don Julio Reposado 750Ml',          'TEQUILAS'),
  ('Johnnie Blue Label 750Ml',          'WHISKY'),
  ('Johnnie Gold Label Reserva 750Ml',  'WHISKY'),
  ('Johnnie Negro 750Ml',               'WHISKY'),
  ('Johnnie Walker 18 750Ml',           'WHISKY'),
  ('Old Parr 12 Anos 750Ml',            'WHISKY'),
  ('Old Parr 18 Anos 750Ml',            'WHISKY')
),
fk as (
  select name, cat,
    upper(btrim(regexp_replace(translate(name, 'ÁÉÍÓÚÜÑÀÈÌÒÙÂÊÎÔÛáéíóúüñàèìòùâêîôû', 'AEIOUUNAEIOUAEIOUaeiouunaeiouaeiou'), '\s+', ' ', 'g'))) as k,
    upper(btrim(regexp_replace(translate(cat,  'ÁÉÍÓÚÜÑÀÈÌÒÙÂÊÎÔÛáéíóúüñàèìòùâêîôû', 'AEIOUUNAEIOUAEIOUaeiouunaeiouaeiou'), '\s+', ' ', 'g'))) as ck
  from f
),
cat_actual as (
  select c.id, c.name,
    upper(btrim(regexp_replace(translate(c.name, 'ÁÉÍÓÚÜÑÀÈÌÒÙÂÊÎÔÛáéíóúüñàèìòùâêîôû', 'AEIOUUNAEIOUAEIOUaeiouunaeiouaeiou'), '\s+', ' ', 'g'))) as k
  from public.categories c, bid where c.business_id = bid.id
),
item_actual as (
  select mi.id, mi.name, mi.price, mi.cost, mi.is_active,
    upper(btrim(regexp_replace(translate(mi.name, 'ÁÉÍÓÚÜÑÀÈÌÒÙÂÊÎÔÛáéíóúüñàèìòùâêîôû', 'AEIOUUNAEIOUAEIOUaeiouunaeiouaeiou'), '\s+', ' ', 'g'))) as k
  from public.menu_items mi, bid where mi.business_id = bid.id
)

select 1 as orden, '1. NEGOCIO' as seccion,
       coalesce(b.business_name, '*** NO EXISTE ***') || ' — sucursal: ' || coalesce(b.branch_name,'(sin sucursal)')
       || ' — tipo: ' || coalesce(b.business_type,'(sin tipo)') || ' — estado: ' || coalesce(b.status,'?') as detalle
from bid left join public.businesses b on b.id = bid.id

union all
select 2, '2. IMPUESTOS',
       coalesce(string_agg(t.name || ' ' || t.rate || '%' || case when coalesce(t.is_active,true) then '' else ' (INACTIVO)' end, ', ' order by t.name),
                '*** NINGUNO — el import va a abortar ***')
from public.taxes t, bid where t.business_id = bid.id

union all
select 3, '3. MENUS',
       coalesce(string_agg(m.name || case when coalesce(m.is_active,true) then '' else ' (inactivo)' end, ', ' order by m.created_at), '(ninguno)')
from public.menus m, bid where m.business_id = bid.id

union all
select 4, '4. AREAS DE IMPRESION',
       coalesce(string_agg(pa.name || ' [' || pa.code || ']', ', ' order by pa.name), '(ninguna)')
from public.print_areas pa, bid where pa.business_id = bid.id and coalesce(pa.is_active,true)

union all
select 5, '5. CATALOGO ACTUAL',
       (select count(*)::text from item_actual) || ' productos, ' ||
       (select count(*)::text from cat_actual)  || ' categorias'

union all
select 6, '6. CATEGORIAS que se REUSAN',
       coalesce((select string_agg(distinct c.name, ', ' order by c.name)
                 from cat_actual c join fk on fk.ck = c.k), '(ninguna — se crean las 10)')

union all
select 7, '7. CATEGORIAS que se CREAN',
       coalesce((select string_agg(distinct fk.cat, ', ' order by fk.cat)
                 from fk where not exists (select 1 from cat_actual c where c.k = fk.ck)), '(ninguna)')

union all
select 8, '8. PRODUCTOS QUE YA EXISTEN (NO se insertan)',
       coalesce((select string_agg(i.name || ' [precio ' || i.price || ', costo ' || coalesce(i.cost::text,'—') || ']', ' | ' order by i.name)
                 from item_actual i join fk on fk.k = i.k), '(ninguno — entran los 19 nuevos)')

union all
select 9, '9. PARECIDOS (revisar a ojo, no bloquean)',
       coalesce((select string_agg(i.name, ' | ' order by i.name)
                 from item_actual i
                 where not exists (select 1 from fk where fk.k = i.k)
                   and exists (select 1 from fk where i.k like '%' || split_part(fk.k,' ',1) || '%'
                               and length(split_part(fk.k,' ',1)) >= 5)), '(ninguno)')

order by orden;
