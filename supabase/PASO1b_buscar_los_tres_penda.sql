-- =============================================================================
-- PASO 1b · LA PENDA EXPRESS — buscar en serio los tres que salieron «FALTA»
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- El PASO 1 los reportó como faltantes, pero el normalizador tenía un hueco:
-- no equipara «onza» con «oz». El papel escribe «chicharon 10 onza» y el
-- sistema «Chicharrón 10 oz» — misma cosa, dos textos que no se cruzan.
-- (Y «chicharon» con una sola r contra «Chicharrón» con dos.)
--
-- Esta busca por PALABRA SUELTA, que es a prueba de esas diferencias.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. CHICHARRÓN — cualquier cosa que empiece por «chicharr» o «chichar».
-- ---------------------------------------------------------------------------
select i.id, i.name, i.unit, i.sku, round(coalesce(i.cost,0),2) as costo,
       coalesce((select sum(s.quantity) from public.inventory_stock s
                  where s.item_id = i.id), 0) as existencia,
       coalesce(i.is_active, true) as activo,
       i.created_at at time zone 'America/Santo_Domingo' as creado
from public.inventory_items i
where i.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and i.name ~* 'chicharr?[oó]n'
order by i.created_at desc;


-- ---------------------------------------------------------------------------
-- 2. POLLO MECHADO
-- ---------------------------------------------------------------------------
select i.id, i.name, i.unit, i.sku, round(coalesce(i.cost,0),2) as costo,
       coalesce((select sum(s.quantity) from public.inventory_stock s
                  where s.item_id = i.id), 0) as existencia,
       coalesce(i.is_active, true) as activo,
       i.created_at at time zone 'America/Santo_Domingo' as creado
from public.inventory_items i
where i.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and i.name ~* 'mechad'
order by i.created_at desc;


-- ---------------------------------------------------------------------------
-- 3. PASTA — todas, para ver si linguini está con otra escritura
--    (linguine con e, linguini con i, o dentro de otro nombre).
-- ---------------------------------------------------------------------------
select i.id, i.name, i.unit, i.sku, round(coalesce(i.cost,0),2) as costo,
       coalesce((select sum(s.quantity) from public.inventory_stock s
                  where s.item_id = i.id), 0) as existencia,
       coalesce(i.is_active, true) as activo
from public.inventory_items i
where i.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and i.name ~* '\m(pasta|linguin|penne|spaghetti|espagueti|fettuc|macarr)'
order by i.name;


-- ---------------------------------------------------------------------------
-- 4. LOS 13, OTRA VEZ — con el normalizador arreglado.
--
--    Ahora «onza/onzas» → «oz» y la doble r de chicharrón se colapsa, así que
--    el match no depende de cómo lo escribió quien llenó el papel.
-- ---------------------------------------------------------------------------
with papel(nom, cant, uni) as (values
  ('PASTRAMI', 6.0, 'libra'),                    ('Salami genoa', 9.0, 'libras'),
  ('peperoni pedrollo', 3.3, 'libras'),          ('picantes red hot', 1.0, 'unidad'),
  ('Genjibre', 1.69, 'libras'),                  ('Aceite especial lata 30 libras', 1.0, 'lata'),
  ('salmon penca', 2.0, 'libras'),               ('chicharon 10 onza', 66.0, 'bolsas'),
  ('pollo mechado 4 onza', 126.0, 'bolsas'),     ('pechurina 6 onza', 10.0, 'bolsas'),
  ('cativia de queso', 150.0, 'unidad'),         ('Pasta penne', 17.0, 'bolsas'),
  ('pasta linguini', 15.0, 'bolsas')
),
-- normalizador v2: sin tildes · «onzas/onza» → oz · consonantes dobles
-- colapsadas (chicharron = chicharon, peperoni = pepperoni) · un solo espacio
kn as (
  select nom, cant, uni,
    regexp_replace(
      regexp_replace(
        regexp_replace(
          lower(translate(btrim(nom), 'áéíóúÁÉÍÓÚñÑ', 'aeiouAEIOUnN')),
          '\m(onzas?|onz)\M', 'oz', 'g'),
        '([bcdfglmnprst])\1', '\1', 'g'),
      '\s+', ' ', 'g') as k
  from papel
),
kc as (
  select i.id, i.name, i.unit, i.sku, i.cost,
    coalesce((select sum(s.quantity) from public.inventory_stock s
               where s.item_id = i.id), 0) as existencia,
    regexp_replace(
      regexp_replace(
        regexp_replace(
          lower(translate(btrim(i.name), 'áéíóúÁÉÍÓÚñÑ', 'aeiouAEIOUnN')),
          '\m(onzas?|onz)\M', 'oz', 'g'),
        '([bcdfglmnprst])\1', '\1', 'g'),
      '\s+', ' ', 'g') as k
  from public.inventory_items i
  where i.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
    and coalesce(i.is_active, true)
)
select
  n.nom as dice_la_hoja, n.cant as contado, n.uni as unidad_papel,
  c.name as en_el_sistema, c.unit as unidad_sistema,
  round(coalesce(c.cost,0),2) as costo, c.existencia, c.sku,
  case
    when c.id is null then '❌ FALTA DE VERDAD'
    when lower(n.uni) like 'libra%' and lower(c.unit) not in ('lb','libra','libras')
      then '⚠️ unidad no cuadra: papel ' || n.uni || ' · sistema ' || c.unit
    when lower(n.uni) like 'bolsa%' and lower(c.unit) <> 'bolsa'
      then '⚠️ unidad no cuadra: papel ' || n.uni || ' · sistema ' || c.unit
    when coalesce(c.cost,0) = 0 then '⚠️ sin costo — no valúa'
    else '✅'
  end as estado,
  c.id
from kn n
left join lateral (
  select * from kc where kc.k = n.k limit 1
) c on true
order by (c.id is null) desc, n.nom;
