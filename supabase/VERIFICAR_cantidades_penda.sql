-- =============================================================================
-- LA PENDA EXPRESS — ¿las CANTIDADES del Excel están bien cargadas?
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- La verificación anterior dijo: de 54 renglones, 26 OK + 11 sin costo (que
-- también tienen la cantidad correcta) + 1 que difiere + 3 que el comparador
-- no encontró por typo + 13 sin cargar.
--
-- O sea: de los 41 que están cargados, 40 coinciden con el papel y UNO no.
-- Estas consultas dicen cuál, y descartan un problema que la verificación
-- anterior NO podía ver.
--
-- ── EL PROBLEMA QUE NO SE VE ──────────────────────────────────────────────
-- La verificación toma UNA sola línea por artículo (la más recientemente
-- tocada). Pero varios artículos están contados en DOS áreas — `Pasta Penne`
-- tiene 17 en cocina y 4 en el almacén principal. Comparar contra una sola
-- de las dos da un veredicto que parece bien y no lo está: el TOTAL del
-- artículo es 21, no 17.
--
-- Eso no es un error del conteo (contar lo mismo en dos áreas es legítimo y
-- se suma), pero sí cambia el número final, y el auditor lo va a ver.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. ¿CUÁL ES EL QUE DIFIERE? — los 41 cargados, con el papel al lado.
--
--    Solo salen los que NO coinciden. Si vuelve una sola fila, es esa.
-- ---------------------------------------------------------------------------
with papel(id, nom, cant) as (values
  ('e7dc40a8-5100-4b38-8e40-88f053ac8a80'::uuid,'Aji morron amarillo',0.5),
  ('e3147d55-5633-45ee-ba9a-29f9b330a760'::uuid,'CARNE SALADA',1.0),
  ('1777df41-1169-4614-a6c7-470bc0d75af9'::uuid,'SALSA BBQ',1.0),
  ('df112b8a-7458-416a-a666-db3036d994e1'::uuid,'FILETE DE SALMON',1.0),
  ('197d82fa-fe07-4552-93b4-849a8ce96eea'::uuid,'MANTEQUILLA DORINA 45OZ',2.0),
  ('cdee569a-f603-4818-a0cf-5675ddb1d6bd'::uuid,'Aji Cubanela',2.5),
  ('6ba4e779-fceb-4143-b71b-e231bcbc334d'::uuid,'TOMATE BARCELO',2.93),
  ('cc01f726-1955-47e4-8060-fa5afa9a9e65'::uuid,'Aji morron Rojo',3.0),
  ('26697de2-775a-4e4f-9d28-2f76ca7190fa'::uuid,'ZUCCHINI',3.0),
  ('122a3d3f-2e0e-4adf-891b-44f7672abd7e'::uuid,'PUERRO ANCHO',3.36),
  ('22c6c8f6-4237-407b-a954-0190d4596b43'::uuid,'PIMIENTA NEGRA MOLIDA',5.0),
  ('56da1160-5ff8-4224-b05c-634f99329432'::uuid,'Apio',5.0),
  ('8ec8627b-53fb-4a40-970e-6b081526469a'::uuid,'ZANAHORIA',5.0),
  ('e1890ea5-ef55-40da-9c5c-5cb00e281a1e'::uuid,'JAMON DE PAVO CASERIO LBS',6.5),
  ('68dff758-4461-49ec-b063-469cf3f8a1dd'::uuid,'CEPA DE APIO',8.0),
  ('777b31c5-301e-447b-ada1-de4013361f07'::uuid,'MANTECA NUESTRA',10.0),
  ('d5b7e98b-cbd9-4e1f-9648-e14be92f805f'::uuid,'QUIPE DE POLLO',52.0),
  ('eb3e5f70-a3be-43d5-9b1e-f99462e3f77b'::uuid,'QUIPE DE QUESO DE CABRA',12.0),
  ('d39590f7-c7d7-4fea-9e9e-b2e592fb940e'::uuid,'PEPINO FRESCO',13.0),
  ('e0c7950e-f20e-44d6-8735-f4d02c0f36bd'::uuid,'CHIVO GUISADO',13.0),
  ('b357c6d9-9735-4f0b-8f2a-d62abb25aa55'::uuid,'SALAMI SUPER ESPECIAL 3.47 LB',20.0),
  ('fde57faa-b1b2-4708-9eba-ab24acad3529'::uuid,'MORTADELA ALEGRIA',20.0),
  ('3306a200-6105-456d-b1b7-54ea5603e8e7'::uuid,'HUEVOS FRECOS',29.0),
  ('0cb23cb5-9d9f-4aa9-8796-d3d0d2b527a3'::uuid,'Berengena',30.0),
  ('5fd1d147-6508-449e-a9c9-83c79c6a98bb'::uuid,'FILETE DE PECHUGA DE POLLO FRESCO',32.0),
  ('6c892302-40bd-4543-a45d-4104cacfefa9'::uuid,'PALITOS YUQUITAS BOLSA',39.0),
  ('ea915c9a-fd40-420b-bff9-31e338ae39a9'::uuid,'ALITAS FRESCAS',46.0),
  ('9e3008df-1f98-4b53-8729-03f58c7f2afb'::uuid,'SANCOCHO PENDA',53.0),
  ('e27e130e-9506-452e-b837-dd145981fda0'::uuid,'QUESO DE FREIR BLANCO',60.0),
  ('67f5a7bd-e091-4e12-8ebf-fd460ebd82a8'::uuid,'EMPANADA DE POLLO',95.0),
  ('17f6b501-628d-4a5e-ab39-a3e05310221f'::uuid,'QUIPE DE RES',100.0),
  ('fb176a38-0946-4043-9f5a-991a133a0dbd'::uuid,'EMPANADA QUESO BOTANA',107.0),
  ('e0d2e3fc-bcf4-43b9-ba2c-356e5bfdf799'::uuid,'EMPANADA BOTANA PIZZA BOTANA',137.0),
  ('f1aebda2-0464-46eb-b3f8-7fadce9f9c7c'::uuid,'LONGANIZA CASERA ARTESANAL',110.0),
  ('3f361492-a768-408f-bd72-0197010e7ee1'::uuid,'LIMONES FRESCOS',25.0),
  -- hoja 2 · cocina B (los tres del typo van por ID, ya resueltos a mano)
  ('6af1283d-0af7-4e6e-8020-c9c9db6c78e7'::uuid,'CASABE NATURAL',43.0),
  ('434d8bea-0de7-4afb-9801-c940b4bf43fb'::uuid,'MANGU (ojo: este id es del PRODUCTO, ver nota)',41.0),
  ('6861e333-cb50-4922-99cf-a5604e00bfa6'::uuid,'COCOA AMARGA',2.0),
  -- hoja 3 · pendientes
  ('d6c63496-fd67-42ce-9cd6-b4d99e1b2d92'::uuid,'PASTRAMI',6.0),
  ('485d54f4-8499-4de5-a683-0c7f9e1ff1bb'::uuid,'Salami Genoa',9.0),
  ('6fcd25a7-f89d-4e32-b3c2-72139c65b15d'::uuid,'Pepperoni Pedrollo',3.3),
  ('4775fcb3-8759-47b0-81aa-9819351de75d'::uuid,'Picante Red Hot',1.0),
  ('1f814aac-9429-4616-b02f-028506747f7f'::uuid,'Genjibre',1.69),
  ('0970382d-2832-499c-9368-c23a1ab3fa84'::uuid,'Aceite especial lata 30 libras',1.0),
  ('914856c3-dfb0-42f2-a984-01a36498a1a3'::uuid,'Salmón penca',2.0),
  ('4b5aaf6e-7efe-4b6f-bc7b-3ff06e4ae3ac'::uuid,'Chicharrón 10 oz',66.0),
  ('61b0c503-5ad6-428a-912e-f3e242d8c87a'::uuid,'Pollo mechado 4 oz',126.0),
  ('97857b62-04cd-47c2-bdfb-5b87cf4b3530'::uuid,'PECHURINA',10.0),
  ('4073534c-f9bf-4d86-ab65-8077b0e246bb'::uuid,'Cativía de queso',150.0),
  ('cf27f185-e99d-4502-8578-906e453eb004'::uuid,'Pasta Penne',17.0),
  ('44a5e30a-3df1-4596-8e5c-723f8d607fdc'::uuid,'Pasta Linguine',15.0)
)
select
  p.nom                                   as articulo,
  p.cant                                  as dice_el_papel,
  sum(l.counted_quantity)                 as total_en_el_sistema,
  count(l.*)                              as en_cuantas_areas,
  string_agg(coalesce(nullif(btrim(s.notes),''), s.code)
             || ' = ' || l.counted_quantity::text,
             '  |  ' order by s.code)     as desglose,
  round(sum(l.counted_quantity) - p.cant, 4) as diferencia,
  case
    when count(l.*) = 0                          then '❌ SIN CARGAR'
    when abs(sum(l.counted_quantity) - p.cant) <= 0.001
         and count(l.*) = 1                      then 'OK'
    when abs(sum(l.counted_quantity) - p.cant) <= 0.001
                                                 then 'OK (sumando áreas)'
    when count(l.*) > 1                          then '⚠️ en varias áreas — el total no da'
    else                                              '⚠️ DIFIERE'
  end                                     as veredicto
from papel p
left join public.physical_count_lines l on l.item_id = p.id
left join public.physical_count_sessions s
       on s.id = l.session_id
      and s.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
      and s.status in ('draft','in_progress','completed')
      and l.counted_quantity is not null
group by p.id, p.nom, p.cant
having count(l.*) = 0
    or abs(coalesce(sum(l.counted_quantity),0) - p.cant) > 0.001
    or count(l.*) > 1
order by 7, p.nom;
-- Si NO vuelve ninguna fila, TODAS las cantidades cargadas están correctas.


-- ---------------------------------------------------------------------------
-- 2. LOS QUE ESTÁN EN DOS ÁREAS — el desglose para el auditor.
--
--    Contar lo mismo en dos áreas es legítimo. Pero el total del artículo es
--    la SUMA, y si el Excel de cocina dice 17 y el sistema tiene 21 repartido
--    en dos áreas, no es un error: es que el almacén principal también tenía.
--    Hay que verlo antes de firmar, no después.
-- ---------------------------------------------------------------------------
select
  i.name                                  as articulo,
  coalesce(i.unit,'unidad')               as unidad,
  count(*)                                as areas,
  string_agg(coalesce(nullif(btrim(s.notes),''), s.code)
             || ' = ' || l.counted_quantity::text,
             '  |  ' order by s.code)     as desglose,
  sum(l.counted_quantity)                 as total,
  round(coalesce(i.cost,0),2)             as costo,
  round(sum(l.counted_quantity) * coalesce(i.cost,0), 2) as valor_total
from public.physical_count_lines l
join public.physical_count_sessions s on s.id = l.session_id
join public.inventory_items i on i.id = l.item_id
where s.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and s.status in ('draft','in_progress','completed')
  and l.counted_quantity is not null
group by i.id, i.name, i.unit, i.cost
having count(*) > 1
order by sum(l.counted_quantity) * coalesce(i.cost,0) desc;


-- ---------------------------------------------------------------------------
-- 3. MANGU / PAPAS FRITAS / VEGETALES SALTEADOS — verificar aparte.
--
--    En el paso 1 no los puse por id porque los insumos se crearon ayer y no
--    tengo los uuid a mano. Se resuelven por nombre exacto, que en estos tres
--    sí es fiable porque los creamos nosotros con ese nombre.
-- ---------------------------------------------------------------------------
with esperado(nom, q) as (values
  ('MANGU DE PLATANO - GUARNICION', 41.0),
  ('PAPAS FRITAS',                  16.0),
  ('VEGETALES SALTEADOS',           11.0),
  ('CROQUETAS DE POLLO',            17.0)
)
select
  e.nom                                   as articulo,
  e.q                                     as dice_el_papel,
  sum(l.counted_quantity)                 as en_el_sistema,
  count(l.*)                              as areas,
  case when count(l.*) = 0 then '❌ SIN CARGAR'
       when abs(coalesce(sum(l.counted_quantity),0) - e.q) <= 0.001 then 'OK'
       else '⚠️ DIFIERE' end              as veredicto
from esperado e
left join public.inventory_items i
       on i.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
      and upper(btrim(i.name)) = upper(btrim(e.nom))
      and coalesce(i.is_active, true)
left join public.physical_count_lines l on l.item_id = i.id
left join public.physical_count_sessions s
       on s.id = l.session_id and l.counted_quantity is not null
group by e.nom, e.q
order by e.nom;
