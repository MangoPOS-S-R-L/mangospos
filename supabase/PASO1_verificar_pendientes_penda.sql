-- =============================================================================
-- PASO 1 · LA PENDA EXPRESS — ¿cuáles de los 13 «PENDIENTES EN SISTEMA»
-- faltan todavía?
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- Los 35 renglones del conteo de la hoja «cocina» YA existen todos — se
-- verificó contra el Excel, los 35 traen su id de sistema. Lo que puede
-- faltar sale de la hoja 3.
--
-- Esta consulta NO crea nada. Dice qué hay y qué no, para crear solo lo que
-- de verdad falta y no volver a duplicar como pasó con los 15 que hubo que
-- fusionar.
--
-- El match es por nombre normalizado (sin tildes, sin dobles espacios) porque
-- el papel escribe «peperoni pedrollo» y el sistema «Pepperoni Pedrollo».
-- Por eso también se busca por CÓDIGO cuando el papel lo trae.
-- =============================================================================

with papel(nom, cant, uni, codigo) as (values
  ('PASTRAMI',                       6.0,   'libra',  '2403111012548'),
  ('Salami genoa',                   9.0,   'libras', null),
  ('peperoni pedrollo',              3.3,   'libras', '2754491014623'),
  ('picantes red hot',               1.0,   'unidad', '41500055602'),
  ('Genjibre',                       1.69,  'libras', null),
  ('Aceite especial lata 30 libras', 1.0,   'lata',   '7468612640312'),
  ('salmon penca',                   2.0,   'libras', null),
  ('chicharon 10 onza',              66.0,  'bolsas', null),
  ('pollo mechado 4 onza',           126.0, 'bolsas', null),
  ('pechurina 6 onza',               10.0,  'bolsas', null),
  ('cativia de queso',               150.0, 'unidad', null),
  ('Pasta penne',                    17.0,  'bolsas', null),
  ('pasta linguini',                 15.0,  'bolsas', null)
),
-- normalizador: minúsculas, sin tildes, un solo espacio
norm as (
  select p.*,
         regexp_replace(
           lower(translate(btrim(p.nom), 'áéíóúÁÉÍÓÚñÑ', 'aeiouAEIOUnN')),
           '\s+', ' ', 'g') as k
  from papel p
),
cat as (
  select i.id, i.name, i.sku, i.unit, i.cost, i.created_at,
         regexp_replace(
           lower(translate(btrim(i.name), 'áéíóúÁÉÍÓÚñÑ', 'aeiouAEIOUnN')),
           '\s+', ' ', 'g') as k,
         coalesce((select sum(s.quantity) from public.inventory_stock s
                    where s.item_id = i.id), 0) as existencia
  from public.inventory_items i
  where i.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
    and coalesce(i.is_active, true)
)
select
  n.nom                                   as dice_la_hoja,
  n.cant                                  as contado,
  n.uni                                   as unidad_papel,
  c.name                                  as en_el_sistema,
  c.unit                                  as unidad_sistema,
  round(coalesce(c.cost, 0), 2)           as costo,
  c.existencia,
  c.sku,
  case
    when c.id is null              then '❌ FALTA — hay que crearlo'
    when c.existencia = 0          then '⚠️ existe pero en CERO'
    when coalesce(c.cost, 0) = 0   then '⚠️ existe, sin costo'
    else                                '✅'
  end                                     as estado,
  c.id
from norm n
left join lateral (
  select * from cat
   where cat.k = n.k
      or (n.codigo is not null and cat.sku = n.codigo)
      -- «pechurina 6 onza» debe encontrar «PECHURINA»
      or cat.k = split_part(n.k, ' ', 1)
   order by (cat.k = n.k) desc, cat.created_at desc
   limit 1
) c on true
order by (c.id is null) desc, n.nom;
