-- =============================================================================
-- Hoja "Inventario de Penda Express" vs. el catálogo del sistema.
--
-- DOS COSAS QUE SE DESCUBRIERON MIRANDO EL CATÁLOGO (2026-09-01):
--
-- 1. EL CÓDIGO DE BARRAS VIVE EN `sku`, NO EN `barcode`.
--    `CHEETOS PUFFS` tiene sku 028400025409 y barcode vacío. Todo el
--    catálogo es así. Por eso esta consulta compara contra AMBAS columnas:
--    preguntar solo por `barcode` diría "no tiene código" de casi todo.
--
-- 2. LOS INSUMOS CUYO NOMBRE ES UN CÓDIGO SON LOS CÓDIGOS QUE FALTAN.
--    Alguien escaneó en el anaquel, el producto no existía, y se creó un
--    insumo llamado `4054500119331`. Esos números RECUPERAN lo que Excel
--    destruyó: la hoja dice `4.0545E+12` y el sistema tiene el código
--    entero. No hace falta el Excel original para esos.
--
-- CÓMO SE RECUPERA UN CÓDIGO REDONDEADO:
--    `8.42595E+11` no es un truncado, es un redondeo a 6 cifras — pero los
--    dígitos que quedaron SÍ son el principio del código. Buscando
--    `842595%` en sku, barcode y nombre aparecen los candidatos reales.
--    Si sale más de uno, hay que distinguirlos a mano: el redondeo perdió
--    los últimos dígitos y no hay forma de saber cuál es cuál desde acá.
--
-- Correr entera. Una fila por renglón de la hoja.
-- =============================================================================

with hoja(dice_la_hoja, codigo_hoja, nombre_hoja, cantidad) as (values
  -- ── Página 1: "no están en el sistema" ──
  ('crear','8.41308E+12','Aceituna Goumet con hueso',1),
  ('crear','2.05E+12','Anis Estrella',1),
  ('crear','7.87545E+11','Sazon completo baldom de 8 libras',1),
  ('crear','8.41107E+12','Jengibre molido',1),
  ('crear','41331013703','Alcaparra',1),
  ('crear','6.07767E+11','Papicra',1),
  ('crear','33844005115','Ajo granulado',1),
  ('crear','7.46612E+12','Jugo de manzana Aloe Vera de 350 ml',1),
  ('crear','38000846755','Pringles de queso pequena',1),
  ('crear','7.50611E+12','Trident Feshmind',1),
  ('crear','7.6222E+12','Trident Menta Fuerte',1),
  ('crear','7.46114E+12','Refresco Top Top Cola',2),
  ('crear','2.05E+12','Pasta Penne del bravo',2),
  ('crear','2.05E+12','Pasta de coditos del bravo',2),
  ('crear','2.05E+12','Crema de leche Bravo pequena',2),
  ('crear','41500819389','Mostaza Frenchs',2),
  ('crear','8.41107E+12','Nuez mocada bravo',2),
  ('crear','8.41107E+12','Perejil Risado',2),
  ('crear','6.07766E+11','Azucar liquida blue agave',2),
  ('crear','7.51685E+11','Lata de maiz dulce de 70 oz Linda',2),
  ('crear','41224871229','Sesame Oil de 6.28 on',3),
  ('crear','7.46862E+12','Chispas de chocolates NTD de 5 libras',3),
  ('crear','8.0768E+12','Pasta Penne',4),
  ('crear','8.0768E+12','Pasta Linguine',4),
  ('crear','7.46012E+12','Leche Condesada Nestle',5),
  ('crear','2.05E+12','malagueta bravo',5),
  ('crear','6.33148E+11','Tajin',5),
  ('crear','6.07767E+11','Balsamic vinagre de 1 lt',5),
  ('crear','33844005351','Cebolla granulada',5),
  ('crear','2.05E+12','Cocoa Amarga',6),
  ('crear','2.05E+12','Vainilla Blanca de 16 oz',6),
  ('crear','2.05E+12','Leche de Almendra de 1 lt',6),
  ('crear','5.00027E+12','JOHnnie Walker Gold Resever',7),
  ('crear','31200200075','Canberry de 64 oz',7),
  ('crear','33844005115','Pote de cinamon',7),
  ('crear','7.51685E+11','Lata de tomatos triturados 6.6 lib',7),
  ('crear','2.05E+12','bicarbonato barvo',8),
  ('crear','2.05E+12','Espaguetis Primavera',9),
  ('crear','2.05E+12','Azucar Pulverizada',11),
  ('crear','7.46677E+12','Leche Parmalat Sin lactorsa',12),
  ('crear','7.87693E+11','Crunchy Proteins cookies double chocolate',12),
  ('crear','2.05E+12','Cocoa dulce',13),
  ('crear','7.46055E+12','Gatorade Fresa Sandia',21),
  ('crear','2.05E+12','Leche Condesada Condesada',25),
  ('crear','6.9211E+12','Huevos Sorpresas',120),
  ('crear','7.70235E+12','Caja de sopita dona gallina',168),
  ('crear',null,'Sazon azafran ranchero',180),
  -- ── Página 2: "solo falta el código de barra" ──
  ('codigo','6.21095E+12','Alhambra',null),
  ('codigo','82000727477','Smirnoff Green apple',null),
  ('codigo','8.00197E+12','Lunaedi merlot italy',null),
  ('codigo','8.11751E+11','Stoli Gold',null),
  ('codigo','7.21733E+11','Patron Silver',null),
  ('codigo','8.00197E+12','Lunardi pinot grigio',null),
  ('codigo','7.46074E+12','Lagrange melocoton',null),
  ('codigo','82184000335','Jack Daniels Hanney Botella',null),
  ('codigo','41508015','Agua Perrier de 350 ml pequena',null),
  ('codigo','7478545','Agua Perrier de 700 ml grande',null),
  ('codigo','4.0545E+12','Zahringer premiu plis 4.8%',null),
  ('codigo','4.0545E+12','Zahringe schwarz bier negra 4.9%',null),
  ('codigo','8.42595E+11','Bloom Pop Fresa',null),
  ('codigo','8.42595E+11','C4 Pink Limanade',null),
  ('codigo','8.42595E+11','C4 Orange',null),
  ('codigo','8.42595E+11','C4 Cosmic Rainbow',null),
  ('codigo','7.46055E+12','Gatorlit Uva',null),
  ('codigo','52000067002','Muscle Milk pro Strawberry',null),
  ('codigo','52000066944','Muscle Milk pro Chocolate',null),
  ('codigo','8.02014E+12','Agua Santa Ana',null),
  ('codigo','79298000078','Agua Evian 1litro',null),
  ('codigo','7.46677E+12','Leche Parmalat Descremada 1lt',null),
  ('codigo','7.46677E+12','Leche Parmalat Entera 1 lt',null),
  ('codigo','3.80021E+12','My Motto Cocoa y Cocoa',null),
  ('codigo','3.80021E+12','My Motto Tiramisu',null),
  ('codigo','7.87693E+11','cruchy Protein Cookies',null),
  ('codigo','7.50895E+11','Sopa con Sabor a Pollo ISSIMA',null),
  ('codigo','41449003153','Arina de panques',null),
  ('codigo','8.71043E+12','Ensure advance Fresa',null),
  ('codigo','8.71043E+12','Ensure de chocolate',null),
  ('codigo','7.46012E+12','Leche evaporada carnation',null),
  ('codigo','7.87545E+11','Salsa china Ranchera Galon',null),
  ('codigo','4.0545E+12','Eichbaun radler lemon o.o%',null),
  ('codigo','4.0545E+12','Eichbaun radler gratefruits',null)
),
-- Normalizar: sin acentos, sin mayúsculas, sin nada que no sea letra o
-- dígito. "Azúcar Pulverizada" y "AZUCAR PULVERIZADA" tienen que casar.
h as (
  select dice_la_hoja, codigo_hoja, nombre_hoja, cantidad,
         -- Los dígitos que sobrevivieron al redondeo de Excel: '8.42595E+11'
         -- deja '842595', que es el PRINCIPIO del código real.
         case when codigo_hoja like '%E+%'
              then regexp_replace(split_part(codigo_hoja, 'E', 1), '\\D', '', 'g')
              else regexp_replace(coalesce(codigo_hoja,''), '\\D', '', 'g')
         end as prefijo,
         regexp_replace(
           translate(lower(nombre_hoja),
                     'áéíóúüñÁÉÍÓÚÜÑ', 'aeiouunaeiouun'),
           '[^a-z0-9]', '', 'g') as n
    from hoja
),
s as (
  select id, name,
         coalesce(sku,'') as sku, coalesce(barcode,'') as barcode,
         -- El código REAL del insumo, esté donde esté guardado.
         coalesce(nullif(barcode,''), nullif(sku,''), '') as codigo,
         is_active,
         regexp_replace(
           translate(lower(name),
                     'áéíóúüñÁÉÍÓÚÜÑ', 'aeiouunaeiouun'),
           '[^a-z0-9]', '', 'g') as n
    from public.inventory_items
   where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
)
select
  -- Lo que AFIRMA la hoja, no lo que verificamos. 'crear' = la hoja dice que
  -- no está en el sistema; 'codigo' = dice que está y solo le falta el
  -- código. Quien decide es `veredicto`.
  h.dice_la_hoja,
  h.nombre_hoja,
  h.cantidad,
  case when h.codigo_hoja like '%E+%' or h.codigo_hoja is null
       then 'CODIGO INUTILIZABLE' else h.codigo_hoja end as codigo_hoja,
  m.name    as nombre_en_sistema,
  m.codigo  as codigo_en_sistema,
  case
    when m.id is null then 'NO EXISTE'
    when m.codigo = '' then 'EXISTE, SIN CODIGO'
    else 'EXISTE, CON CODIGO'
  end as veredicto,
  -- Insumos cuyo código EMPIEZA con lo que sobrevivió del redondeo. Acá es
  -- donde aparecen los insumos con nombre de código: son el código perdido.
  p.candidatos_por_codigo,
  case when m.id is not null and not m.is_active then 'INACTIVO' end as ojo,
  -- ¿La hoja tenía razón? Esto es lo que hay que mirar primero.
  case
    when h.dice_la_hoja = 'crear'  and m.id is null     then 'ok'
    when h.dice_la_hoja = 'codigo' and m.id is not null then 'ok'
    when h.dice_la_hoja = 'crear'  and m.id is not null
      then 'LA HOJA SE EQUIVOCA: ya existe, NO crear'
    else 'LA HOJA SE EQUIVOCA: no existe, hay que crearlo'
  end as contraste
from h
left join lateral (
  -- El más parecido: primero coincidencia exacta normalizada, después uno
  -- que contenga al otro, prefiriendo el de largo más parecido.
  select s.*
    from s
   where s.n = h.n
      or (length(h.n) >= 5 and s.n like '%' || h.n || '%')
      or (length(s.n) >= 5 and h.n like '%' || s.n || '%')
   order by (s.n = h.n) desc, abs(length(s.n) - length(h.n))
   limit 1
) m on true
left join lateral (
  select string_agg(x.name || ' [' || x.codigo || ']', ' | '
                    order by x.name) as candidatos_por_codigo
    from s x
   where length(h.prefijo) >= 5
     and (x.codigo like h.prefijo || '%' or x.name like h.prefijo || '%')
) p on true
order by contraste desc, h.dice_la_hoja, h.nombre_hoja;
