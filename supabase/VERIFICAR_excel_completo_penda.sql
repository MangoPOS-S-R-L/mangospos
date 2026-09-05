-- =============================================================================
-- LA PENDA EXPRESS — VERIFICACIÓN: ¿está TODO el Excel cargado y correcto?
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- Los 54 renglones CONTADOS de las tres hojas del archivo
-- «Inventario Cocina Robinson Penda express 01-09-26.xlsx», generados desde el
-- propio archivo — sin transcribir a mano.
--
--   hoja 1 «cocina»      35 renglones  (cocina A)
--   hoja 2 «cocina 2»     6 renglones  (cocina B; el quipe ya va sumado arriba)
--   hoja 3 «PENDIENTES»  13 renglones
--
-- QUIPE DE POLLO va con 52 = 10 (cocina A) + 42 (cocina B), según la regla del
-- dueño de que las dos áreas se suman.
--
-- La hoja 1 trae el id del sistema en el propio Excel; para las hojas 2 y 3 se
-- resuelve por nombre (exacto, y si no, normalizado: sin tildes, «onza»→«oz»,
-- consonantes dobles colapsadas, plural→singular).
--
-- CÓMO LEER LA SALIDA: la columna `veredicto`. Si TODAS dicen «OK», el Excel
-- está cargado completo. Cualquier otra cosa es un renglón que falta o que
-- quedó con un número distinto al del papel.
-- =============================================================================

with papel(item_id, nom, cant, uni, origen) as (values
  ('e7dc40a8-5100-4b38-8e40-88f053ac8a80'::uuid, 'Aji morron amarillo', 0.5, 'libras', 'hoja 1 · cocina A'),
  ('e3147d55-5633-45ee-ba9a-29f9b330a760'::uuid, 'CARNE SALADA 10 onzas', 1.0, 'bolsas', 'hoja 1 · cocina A'),
  ('1777df41-1169-4614-a6c7-470bc0d75af9'::uuid, 'SALSA BBQ', 1.0, 'unidad', 'hoja 1 · cocina A'),
  ('df112b8a-7458-416a-a666-db3036d994e1'::uuid, 'FILETE DE SALMON 8 onza', 1.0, 'unidad', 'hoja 1 · cocina A'),
  ('197d82fa-fe07-4552-93b4-849a8ce96eea'::uuid, 'MANTEQUILLA DORINA 45OZ', 2.0, 'unidad', 'hoja 1 · cocina A'),
  ('cdee569a-f603-4818-a0cf-5675ddb1d6bd'::uuid, 'Aji Cubanela', 2.5, 'libras', 'hoja 1 · cocina A'),
  ('6ba4e779-fceb-4143-b71b-e231bcbc334d'::uuid, 'TOMATE BARCELO', 2.93, 'libras', 'hoja 1 · cocina A'),
  ('cc01f726-1955-47e4-8060-fa5afa9a9e65'::uuid, 'Aji morron Rojo', 3.0, 'libras', 'hoja 1 · cocina A'),
  ('26697de2-775a-4e4f-9d28-2f76ca7190fa'::uuid, 'ZUCCHINI', 3.0, 'unidad', 'hoja 1 · cocina A'),
  ('122a3d3f-2e0e-4adf-891b-44f7672abd7e'::uuid, 'PUERRO ANCHO', 3.36, 'libras', 'hoja 1 · cocina A'),
  ('22c6c8f6-4237-407b-a954-0190d4596b43'::uuid, 'PIMIENTA NEGRA MOLIDA', 5.0, 'libras', 'hoja 1 · cocina A'),
  ('56da1160-5ff8-4224-b05c-634f99329432'::uuid, 'Apio', 5.0, 'libras', 'hoja 1 · cocina A'),
  ('8ec8627b-53fb-4a40-970e-6b081526469a'::uuid, 'ZANAHORIA', 5.0, 'libras', 'hoja 1 · cocina A'),
  ('e1890ea5-ef55-40da-9c5c-5cb00e281a1e'::uuid, 'JAMON DE PAVO CASERIO LBS', 6.5, 'LIBRAS', 'hoja 1 · cocina A'),
  ('68dff758-4461-49ec-b063-469cf3f8a1dd'::uuid, 'CEPA DE APIO 10 onzas', 8.0, 'bolsas', 'hoja 1 · cocina A'),
  ('777b31c5-301e-447b-ada1-de4013361f07'::uuid, 'MANTECA NUESTRA 50 libras', 10.0, 'caja', 'hoja 1 · cocina A'),
  ('d5b7e98b-cbd9-4e1f-9648-e14be92f805f'::uuid, 'QUIPE DE POLLO', 52.0, 'unidad', 'hoja 1 · cocina A'),
  ('eb3e5f70-a3be-43d5-9b1e-f99462e3f77b'::uuid, 'QUIPE DE QUESO DE  CABRA', 12.0, 'unidad', 'hoja 1 · cocina A'),
  ('d39590f7-c7d7-4fea-9e9e-b2e592fb940e'::uuid, 'PEPINO FRESCO', 13.0, 'unidad', 'hoja 1 · cocina A'),
  ('e0c7950e-f20e-44d6-8735-f4d02c0f36bd'::uuid, 'CHIVO GUISADO', 13.0, 'unidad', 'hoja 1 · cocina A'),
  ('b357c6d9-9735-4f0b-8f2a-d62abb25aa55'::uuid, 'SALAMI SUPER ESPECIAL 3.47 LB', 20.0, 'unidad', 'hoja 1 · cocina A'),
  ('fde57faa-b1b2-4708-9eba-ab24acad3529'::uuid, 'MORTADELA ALEGRIA', 20.0, 'LIBRAS', 'hoja 1 · cocina A'),
  ('3306a200-6105-456d-b1b7-54ea5603e8e7'::uuid, 'HUEVOS FRECOS', 29.0, 'cartones', 'hoja 1 · cocina A'),
  ('0cb23cb5-9d9f-4aa9-8796-d3d0d2b527a3'::uuid, 'Berengena', 30.0, 'unidad', 'hoja 1 · cocina A'),
  ('5fd1d147-6508-449e-a9c9-83c79c6a98bb'::uuid, 'FILETE DE PECHUGA DE POLLO FRESCO 10 onza', 32.0, 'bolsas', 'hoja 1 · cocina A'),
  ('6c892302-40bd-4543-a45d-4104cacfefa9'::uuid, 'PALITOS YUQUITAS BOLSA', 39.0, 'unidad', 'hoja 1 · cocina A'),
  ('ea915c9a-fd40-420b-bff9-31e338ae39a9'::uuid, 'ALITAS FRESCAS', 46.0, 'bolsas', 'hoja 1 · cocina A'),
  ('9e3008df-1f98-4b53-8729-03f58c7f2afb'::uuid, 'SANCOCHO PENDA', 53.0, 'unidad', 'hoja 1 · cocina A'),
  ('e27e130e-9506-452e-b837-dd145981fda0'::uuid, 'QUESO DE FREIR BLANCO', 60.0, 'LIBRAS', 'hoja 1 · cocina A'),
  ('67f5a7bd-e091-4e12-8ebf-fd460ebd82a8'::uuid, 'EMPANADA DE POLLO', 95.0, 'unidad', 'hoja 1 · cocina A'),
  ('17f6b501-628d-4a5e-ab39-a3e05310221f'::uuid, 'QUIPE DE RES', 100.0, 'unidad', 'hoja 1 · cocina A'),
  ('fb176a38-0946-4043-9f5a-991a133a0dbd'::uuid, 'EMPANADA QUESO BOTANA', 107.0, 'unidadd', 'hoja 1 · cocina A'),
  ('e0d2e3fc-bcf4-43b9-ba2c-356e5bfdf799'::uuid, 'EMPANADA BOTANA PIZZA BOTANA', 137.0, 'unidad', 'hoja 1 · cocina A'),
  ('f1aebda2-0464-46eb-b3f8-7fadce9f9c7c'::uuid, 'LONGANIZA CASERA ARTESANAL', 110.0, 'bolsas', 'hoja 1 · cocina A'),
  ('3f361492-a768-408f-bd72-0197010e7ee1'::uuid, 'LIMONES FRESCOS', 25.0, 'libras', 'hoja 1 · cocina A'),
  (null::uuid, 'CASABE', 43.0, 'paquetes', 'hoja 2 · cocina B'),
  (null::uuid, 'MANGU DE PLATANO - GUARNICION', 41.0, 'bolsas', 'hoja 2 · cocina B'),
  (null::uuid, 'CROQUETAS DE POLLO', 17.0, 'servicio', 'hoja 2 · cocina B'),
  (null::uuid, 'PAPAS FRITAS', 16.0, 'unidad', 'hoja 2 · cocina B'),
  (null::uuid, 'VEGETALES SALTEADOS', 11.0, 'bolsas', 'hoja 2 · cocina B'),
  (null::uuid, 'COCOA AMARGA', 2.0, 'unidad', 'hoja 2 · cocina B'),
  (null::uuid, 'PASTRAMI', 6.0, 'libra', 'hoja 3 · pendientes'),
  (null::uuid, 'Salami genoa', 9.0, 'libras', 'hoja 3 · pendientes'),
  (null::uuid, 'peperoni pedrollo', 3.3, 'libras', 'hoja 3 · pendientes'),
  (null::uuid, 'picantes red hot', 1.0, 'unidad', 'hoja 3 · pendientes'),
  (null::uuid, 'Genjibre', 1.69, 'libras', 'hoja 3 · pendientes'),
  (null::uuid, 'Aceite especial lata 30 libras', 1.0, 'lata', 'hoja 3 · pendientes'),
  (null::uuid, 'salmon penca', 2.0, 'libras', 'hoja 3 · pendientes'),
  (null::uuid, 'chicharon 10 onza', 66.0, 'bolsas', 'hoja 3 · pendientes'),
  (null::uuid, 'pollo mechado 4 onza', 126.0, 'bolsas', 'hoja 3 · pendientes'),
  (null::uuid, 'pechurina 6 onza', 10.0, 'bolsas', 'hoja 3 · pendientes'),
  (null::uuid, 'cativia de queso', 150.0, 'unidad', 'hoja 3 · pendientes'),
  (null::uuid, 'Pasta penne', 17.0, 'bolsas', 'hoja 3 · pendientes'),
  (null::uuid, 'pasta linguini', 15.0, 'bolsas', 'hoja 3 · pendientes')
),
-- normalizador para resolver por nombre lo que no trae id
norm as (
  select p.*,
    regexp_replace(regexp_replace(regexp_replace(
      lower(translate(btrim(p.nom), 'áéíóúÁÉÍÓÚñÑ', 'aeiouAEIOUnN')),
      '\m(onzas?|onz)\M', 'oz', 'g'),
      '([bcdfglmnprst])\1', '\1', 'g'),
      '\s+', ' ', 'g') as k
  from papel p
),
cat as (
  select i.id, i.name, i.unit, i.cost,
    regexp_replace(regexp_replace(regexp_replace(
      lower(translate(btrim(i.name), 'áéíóúÁÉÍÓÚñÑ', 'aeiouAEIOUnN')),
      '\m(onzas?|onz)\M', 'oz', 'g'),
      '([bcdfglmnprst])\1', '\1', 'g'),
      '\s+', ' ', 'g') as k
  from public.inventory_items i
  where i.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
    and coalesce(i.is_active, true)
),
resuelto as (
  select n.*, coalesce(n.item_id, c.id) as id_final
  from norm n
  left join lateral (
    select id from cat
     where n.item_id is null
       and (cat.k = n.k
         or cat.k = regexp_replace(n.k, 's$', '')          -- plural→singular
         or regexp_replace(cat.k,'s$','') = n.k
         or cat.k = split_part(n.k, ' ', 1))               -- «pechurina 6 oz»→«pechurina»
     order by (cat.k = n.k) desc limit 1
  ) c on true
)
select
  r.origen,
  r.nom                                         as dice_el_excel,
  r.cant                                        as papel,
  r.uni                                         as unidad_papel,
  i.name                                        as en_el_sistema,
  i.unit                                        as unidad_sistema,
  l.counted_quantity                            as cargado,
  s.code                                        as en_la_sesion,
  round(coalesce(i.cost,0), 2)                  as costo,
  round(coalesce(l.counted_quantity,0) * coalesce(i.cost,0), 2) as valor,
  case
    when i.id is null                          then '❌ NO EXISTE el insumo'
    when l.counted_quantity is null            then '❌ SIN CARGAR'
    when abs(l.counted_quantity - r.cant) > 0.001
                                               then '⚠️ DIFIERE — papel '
                                                    || r.cant::text || ' vs sistema '
                                                    || l.counted_quantity::text
    when coalesce(i.cost,0) = 0                then '⚠️ cargado pero SIN COSTO'
    else                                            'OK'
  end                                           as veredicto
from resuelto r
left join public.inventory_items i on i.id = r.id_final
left join lateral (
  select l2.counted_quantity, l2.session_id
    from public.physical_count_lines l2
    join public.physical_count_sessions s2 on s2.id = l2.session_id
   where l2.item_id = i.id
     and s2.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
     and s2.status in ('draft','in_progress','completed')
     and l2.counted_quantity is not null
   order by l2.updated_at desc nulls last limit 1
) l on true
left join public.physical_count_sessions s on s.id = l.session_id
order by
  case when i.id is null then 0
       when l.counted_quantity is null then 1
       when abs(l.counted_quantity - r.cant) > 0.001 then 2
       when coalesce(i.cost,0) = 0 then 3
       else 4 end,
  r.origen, r.nom;


-- ---------------------------------------------------------------------------
-- EL RESUMEN — una sola fila. Si `ok` = 54, el Excel está completo.
-- ---------------------------------------------------------------------------
with papel(item_id, nom, cant, uni, origen) as (values
  ('e7dc40a8-5100-4b38-8e40-88f053ac8a80'::uuid, 'Aji morron amarillo', 0.5, 'libras', 'hoja 1 · cocina A'),
  ('e3147d55-5633-45ee-ba9a-29f9b330a760'::uuid, 'CARNE SALADA 10 onzas', 1.0, 'bolsas', 'hoja 1 · cocina A'),
  ('1777df41-1169-4614-a6c7-470bc0d75af9'::uuid, 'SALSA BBQ', 1.0, 'unidad', 'hoja 1 · cocina A'),
  ('df112b8a-7458-416a-a666-db3036d994e1'::uuid, 'FILETE DE SALMON 8 onza', 1.0, 'unidad', 'hoja 1 · cocina A'),
  ('197d82fa-fe07-4552-93b4-849a8ce96eea'::uuid, 'MANTEQUILLA DORINA 45OZ', 2.0, 'unidad', 'hoja 1 · cocina A'),
  ('cdee569a-f603-4818-a0cf-5675ddb1d6bd'::uuid, 'Aji Cubanela', 2.5, 'libras', 'hoja 1 · cocina A'),
  ('6ba4e779-fceb-4143-b71b-e231bcbc334d'::uuid, 'TOMATE BARCELO', 2.93, 'libras', 'hoja 1 · cocina A'),
  ('cc01f726-1955-47e4-8060-fa5afa9a9e65'::uuid, 'Aji morron Rojo', 3.0, 'libras', 'hoja 1 · cocina A'),
  ('26697de2-775a-4e4f-9d28-2f76ca7190fa'::uuid, 'ZUCCHINI', 3.0, 'unidad', 'hoja 1 · cocina A'),
  ('122a3d3f-2e0e-4adf-891b-44f7672abd7e'::uuid, 'PUERRO ANCHO', 3.36, 'libras', 'hoja 1 · cocina A'),
  ('22c6c8f6-4237-407b-a954-0190d4596b43'::uuid, 'PIMIENTA NEGRA MOLIDA', 5.0, 'libras', 'hoja 1 · cocina A'),
  ('56da1160-5ff8-4224-b05c-634f99329432'::uuid, 'Apio', 5.0, 'libras', 'hoja 1 · cocina A'),
  ('8ec8627b-53fb-4a40-970e-6b081526469a'::uuid, 'ZANAHORIA', 5.0, 'libras', 'hoja 1 · cocina A'),
  ('e1890ea5-ef55-40da-9c5c-5cb00e281a1e'::uuid, 'JAMON DE PAVO CASERIO LBS', 6.5, 'LIBRAS', 'hoja 1 · cocina A'),
  ('68dff758-4461-49ec-b063-469cf3f8a1dd'::uuid, 'CEPA DE APIO 10 onzas', 8.0, 'bolsas', 'hoja 1 · cocina A'),
  ('777b31c5-301e-447b-ada1-de4013361f07'::uuid, 'MANTECA NUESTRA 50 libras', 10.0, 'caja', 'hoja 1 · cocina A'),
  ('d5b7e98b-cbd9-4e1f-9648-e14be92f805f'::uuid, 'QUIPE DE POLLO', 52.0, 'unidad', 'hoja 1 · cocina A'),
  ('eb3e5f70-a3be-43d5-9b1e-f99462e3f77b'::uuid, 'QUIPE DE QUESO DE  CABRA', 12.0, 'unidad', 'hoja 1 · cocina A'),
  ('d39590f7-c7d7-4fea-9e9e-b2e592fb940e'::uuid, 'PEPINO FRESCO', 13.0, 'unidad', 'hoja 1 · cocina A'),
  ('e0c7950e-f20e-44d6-8735-f4d02c0f36bd'::uuid, 'CHIVO GUISADO', 13.0, 'unidad', 'hoja 1 · cocina A'),
  ('b357c6d9-9735-4f0b-8f2a-d62abb25aa55'::uuid, 'SALAMI SUPER ESPECIAL 3.47 LB', 20.0, 'unidad', 'hoja 1 · cocina A'),
  ('fde57faa-b1b2-4708-9eba-ab24acad3529'::uuid, 'MORTADELA ALEGRIA', 20.0, 'LIBRAS', 'hoja 1 · cocina A'),
  ('3306a200-6105-456d-b1b7-54ea5603e8e7'::uuid, 'HUEVOS FRECOS', 29.0, 'cartones', 'hoja 1 · cocina A'),
  ('0cb23cb5-9d9f-4aa9-8796-d3d0d2b527a3'::uuid, 'Berengena', 30.0, 'unidad', 'hoja 1 · cocina A'),
  ('5fd1d147-6508-449e-a9c9-83c79c6a98bb'::uuid, 'FILETE DE PECHUGA DE POLLO FRESCO 10 onza', 32.0, 'bolsas', 'hoja 1 · cocina A'),
  ('6c892302-40bd-4543-a45d-4104cacfefa9'::uuid, 'PALITOS YUQUITAS BOLSA', 39.0, 'unidad', 'hoja 1 · cocina A'),
  ('ea915c9a-fd40-420b-bff9-31e338ae39a9'::uuid, 'ALITAS FRESCAS', 46.0, 'bolsas', 'hoja 1 · cocina A'),
  ('9e3008df-1f98-4b53-8729-03f58c7f2afb'::uuid, 'SANCOCHO PENDA', 53.0, 'unidad', 'hoja 1 · cocina A'),
  ('e27e130e-9506-452e-b837-dd145981fda0'::uuid, 'QUESO DE FREIR BLANCO', 60.0, 'LIBRAS', 'hoja 1 · cocina A'),
  ('67f5a7bd-e091-4e12-8ebf-fd460ebd82a8'::uuid, 'EMPANADA DE POLLO', 95.0, 'unidad', 'hoja 1 · cocina A'),
  ('17f6b501-628d-4a5e-ab39-a3e05310221f'::uuid, 'QUIPE DE RES', 100.0, 'unidad', 'hoja 1 · cocina A'),
  ('fb176a38-0946-4043-9f5a-991a133a0dbd'::uuid, 'EMPANADA QUESO BOTANA', 107.0, 'unidadd', 'hoja 1 · cocina A'),
  ('e0d2e3fc-bcf4-43b9-ba2c-356e5bfdf799'::uuid, 'EMPANADA BOTANA PIZZA BOTANA', 137.0, 'unidad', 'hoja 1 · cocina A'),
  ('f1aebda2-0464-46eb-b3f8-7fadce9f9c7c'::uuid, 'LONGANIZA CASERA ARTESANAL', 110.0, 'bolsas', 'hoja 1 · cocina A'),
  ('3f361492-a768-408f-bd72-0197010e7ee1'::uuid, 'LIMONES FRESCOS', 25.0, 'libras', 'hoja 1 · cocina A'),
  (null::uuid, 'CASABE', 43.0, 'paquetes', 'hoja 2 · cocina B'),
  (null::uuid, 'MANGU DE PLATANO - GUARNICION', 41.0, 'bolsas', 'hoja 2 · cocina B'),
  (null::uuid, 'CROQUETAS DE POLLO', 17.0, 'servicio', 'hoja 2 · cocina B'),
  (null::uuid, 'PAPAS FRITAS', 16.0, 'unidad', 'hoja 2 · cocina B'),
  (null::uuid, 'VEGETALES SALTEADOS', 11.0, 'bolsas', 'hoja 2 · cocina B'),
  (null::uuid, 'COCOA AMARGA', 2.0, 'unidad', 'hoja 2 · cocina B'),
  (null::uuid, 'PASTRAMI', 6.0, 'libra', 'hoja 3 · pendientes'),
  (null::uuid, 'Salami genoa', 9.0, 'libras', 'hoja 3 · pendientes'),
  (null::uuid, 'peperoni pedrollo', 3.3, 'libras', 'hoja 3 · pendientes'),
  (null::uuid, 'picantes red hot', 1.0, 'unidad', 'hoja 3 · pendientes'),
  (null::uuid, 'Genjibre', 1.69, 'libras', 'hoja 3 · pendientes'),
  (null::uuid, 'Aceite especial lata 30 libras', 1.0, 'lata', 'hoja 3 · pendientes'),
  (null::uuid, 'salmon penca', 2.0, 'libras', 'hoja 3 · pendientes'),
  (null::uuid, 'chicharon 10 onza', 66.0, 'bolsas', 'hoja 3 · pendientes'),
  (null::uuid, 'pollo mechado 4 onza', 126.0, 'bolsas', 'hoja 3 · pendientes'),
  (null::uuid, 'pechurina 6 onza', 10.0, 'bolsas', 'hoja 3 · pendientes'),
  (null::uuid, 'cativia de queso', 150.0, 'unidad', 'hoja 3 · pendientes'),
  (null::uuid, 'Pasta penne', 17.0, 'bolsas', 'hoja 3 · pendientes'),
  (null::uuid, 'pasta linguini', 15.0, 'bolsas', 'hoja 3 · pendientes')
),
norm as (
  select p.*,
    regexp_replace(regexp_replace(regexp_replace(
      lower(translate(btrim(p.nom), 'áéíóúÁÉÍÓÚñÑ', 'aeiouAEIOUnN')),
      '\m(onzas?|onz)\M', 'oz', 'g'),
      '([bcdfglmnprst])\1', '\1', 'g'),
      '\s+', ' ', 'g') as k
  from papel p
),
cat as (
  select i.id, i.cost,
    regexp_replace(regexp_replace(regexp_replace(
      lower(translate(btrim(i.name), 'áéíóúÁÉÍÓÚñÑ', 'aeiouAEIOUnN')),
      '\m(onzas?|onz)\M', 'oz', 'g'),
      '([bcdfglmnprst])\1', '\1', 'g'),
      '\s+', ' ', 'g') as k
  from public.inventory_items i
  where i.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
    and coalesce(i.is_active, true)
),
resuelto as (
  select n.*, coalesce(n.item_id, c.id) as id_final
  from norm n
  left join lateral (
    select id from cat
     where n.item_id is null
       and (cat.k = n.k or cat.k = regexp_replace(n.k,'s$','')
         or regexp_replace(cat.k,'s$','') = n.k
         or cat.k = split_part(n.k, ' ', 1))
     order by (cat.k = n.k) desc limit 1
  ) c on true
),
estado as (
  select r.*, i.id as iid, coalesce(i.cost,0) as costo, l.counted_quantity as cargado
  from resuelto r
  left join public.inventory_items i on i.id = r.id_final
  left join lateral (
    select l2.counted_quantity from public.physical_count_lines l2
      join public.physical_count_sessions s2 on s2.id = l2.session_id
     where l2.item_id = i.id
       and s2.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
       and l2.counted_quantity is not null
     order by l2.updated_at desc nulls last limit 1
  ) l on true
)
select
  count(*)                                                          as renglones_del_excel,
  count(*) filter (where iid is not null and cargado is not null
                     and abs(cargado - cant) <= 0.001 and costo > 0) as ok,
  count(*) filter (where iid is null)                               as no_existe,
  count(*) filter (where iid is not null and cargado is null)        as sin_cargar,
  count(*) filter (where cargado is not null
                     and abs(cargado - cant) > 0.001)                as difiere,
  count(*) filter (where iid is not null and cargado is not null
                     and abs(cargado - cant) <= 0.001 and costo = 0) as sin_costo
from estado;
