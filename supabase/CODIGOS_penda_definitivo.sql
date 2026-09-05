-- =============================================================================
-- Los 73 renglones de la hoja, emparejados POR CÓDIGO contra TODO el catálogo.
--
-- POR QUÉ POR CÓDIGO Y NO POR NOMBRE:
--   El emparejado por nombre falló demasiado: `AGUA SANTA ANNA` con doble N,
--   `C4 PINK LEMONADE` donde la hoja escribió "Limanade", `bloom pop
--   stramberry` por "Bloom Pop Fresa". Un código o lo tiene alguien o no lo
--   tiene nadie: no hay interpretación.
--
--   El nombre queda como respaldo, sólo para los que no casen por código.
--
-- OJO: en este catálogo el código vive en `sku`. Se buscan las dos columnas.
-- =============================================================================

with hoja(pagina, codigo, nombre, cantidad) as (values
  -- ── Página 1 (con cantidad contada) ──
  (1,'8413080006145','Aceituna Gourmet con hueso',1),
  (1,'2050001115645','Anis Estrella',1),
  (1,'787545193793','Sazon completo baldom de 8 libras',1),
  (1,'8411070033867','Jengibre molido',1),
  (1,'41331013703','Alcaparra',1),
  (1,'607766553346','Papicra',1),
  (1,'33844005115','Ajo granulado',1),
  (1,'7622202375774','Trident Menta Fuerte',1),
  (1,'2050001119407','Pasta Penne del bravo',2),
  (1,'2050001119414','Pasta de coditos del bravo',2),
  (1,'2050001132840','Crema de leche Bravo pequena',2),
  (1,'41500819389','Mostaza Frenchs',2),
  (1,'8411070032268','Nuez mocada bravo',2),
  (1,'607766046411','Azucar liquida blue agave',2),
  (1,'751685110002','Lata de maiz dulce de 70 oz Linda',2),
  (1,'41224871229','Sesame Oil de 6.28 on',3),
  (1,'7468622644454','Chispas de chocolates NTD de 5 libras',3),
  (1,'8076802085738','Pasta Penne',4),
  (1,'8076800195132','Pasta Linguine',4),
  (1,'7460123450718','Leche Condesada Nestle',5),
  (1,'2050001106599','malagueta bravo',5),
  (1,'633148100013','Tajin',5),
  (1,'607766705059','Balsamic vinagre de 1 lt',5),
  (1,'33844005351','Cebolla granulada',5),
  (1,'2050001285522','Cocoa Amarga',6),
  (1,'2050001107213','Vainilla Blanca de 16 oz',6),
  (1,'2050001213884','Leche de Almendra de 1 lt',6),
  (1,'33844005115','Pote de cinamon',7),
  (1,'751685002925','Lata de tomatos triturados 6.6 lib',7),
  (1,'2050001106186','bicarbonato barvo',8),
  (1,'2050001366528','Espaguetis Primavera',9),
  (1,'2050001398321','Azucar Pulverizada',11),
  (1,'7466774656202','Leche Parmalat Sin lactorsa',12),
  (1,'2050001277725','Cocoa dulce',13),
  (1,'7460548002660','Gatorade Fresa Sandia',21),
  (1,'2050001222282','Leche Condesada Condesada',25),
  (1,'6921101250368','Huevos Sorpresas',120),
  (1,'7702354501891','Caja de sopita dona gallina',168),
  (1,null,'Sazon azafran ranchero',180),
  -- ── Página 2 (sin cantidad) ──
  (2,'6210947538205','Alhambra',null),
  (2,'82000727477','Smirnoff Green apple',null),
  (2,'8001968001759','Lunaedi merlot italy',null),
  (2,'811751021943','Stoli Gold',null),
  (2,'721733000929','Patron Silver',null),
  (2,'8001968001759','Lunardi pinot grigio',null),
  (2,'7460736960123','Lagrange melocoton',null),
  (2,'82184000335','Jack Daniels Hanney Botella',null),
  (2,'41508015','Agua Perrier de 350 ml pequena',null),
  (2,'7478545','Agua Perrier de 700 ml grande',null),
  (2,'4054500131746','Zahringer premiu plis 4.8%',null),
  (2,'4054500131746','Zahringe schwarz bier negra 4.9%',null),
  (2,'842595138375','Bloom Pop Fresa',null),
  (2,'842595139778','C4 Pink Limanade',null),
  (2,'842595109368','C4 Orange',null),
  (2,'842595121766','C4 Cosmic Rainbow',null),
  (2,'7460548002166','Gatorlit Uva',null),
  (2,'52000067002','Muscle Milk pro Strawberry',null),
  (2,'52000066944','Muscle Milk pro Chocolate',null),
  (2,'8020141203001','Agua Santa Ana',null),
  (2,'79298000078','Agua Evian 1litro',null),
  (2,'7466774656240','Leche Parmalat Descremada 1lt',null),
  (2,'7466774656226','Leche Parmalat Entera 1 lt',null),
  (2,'3800205871705','My Motto Cocoa y Cocoa',null),
  (2,'3800205876878','My Motto Tiramisu',null),
  (2,'787692870011','cruchy Protein Cookies',null),
  (2,'750894680037','Sopa con Sabor a Pollo ISSIMA',null),
  (2,'41449003153','Arina de panques',null),
  (2,'8710428018586','Ensure advance Fresa',null),
  (2,'8710428018595','Ensure de chocolate',null),
  (2,'7460123476220','Leche evaporada carnation',null),
  (2,'787545004624','Salsa china Ranchera Galon',null),
  (2,'4054500119317','Eichbaun radler lemon o.o%',null),
  (2,'4054500119331','Eichbaun radler gratefruits',null)
),
s as (
  select id, name, coalesce(sku,'') as sku, coalesce(barcode,'') as barcode,
         coalesce(nullif(barcode,''), nullif(sku,''), '') as codigo_actual,
         is_active,
         regexp_replace(translate(lower(name),'áéíóúüñ','aeiouun'),
                        '[^a-z0-9]','','g') as n
    from public.inventory_items
   where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
)
select * from (
select
  h.pagina,
  h.nombre                as en_la_hoja,
  h.codigo                as codigo_hoja,
  h.cantidad,
  -- (A) Quién tiene YA ese código. Es la respuesta dura.
  (select string_agg(x.name || case when x.is_active then '' else ' (inactivo)' end,
                     ' | ' order by x.name)
     from s x where h.codigo is not null and x.codigo_actual = h.codigo)
                          as lo_tiene_por_codigo,
  -- (B) El insumo fantasma creado escaneando: su NOMBRE es el código.
  (select string_agg(x.name, ' | ') from s x where x.name = h.codigo)
                          as huerfano,
  -- (C) Respaldo por nombre, sólo informativo.
  (select x.name from s x
    where x.n = regexp_replace(translate(lower(h.nombre),'áéíóúüñ','aeiouun'),
                               '[^a-z0-9]','','g')
    limit 1)              as mismo_nombre_exacto,
  -- (D) El código, ¿está repetido dentro de la propia hoja?
  case when (select count(*) from hoja h2
              where h2.codigo = h.codigo and h.codigo is not null) > 1
       then 'REPETIDO EN LA HOJA' end as ojo_hoja
from hoja h
) r
-- El alias sólo se puede usar suelto en un order by; dentro de una
-- expresión hay que envolver la consulta. Primero lo que YA existe.
order by r.pagina, (r.lo_tiene_por_codigo is null), r.en_la_hoja;
