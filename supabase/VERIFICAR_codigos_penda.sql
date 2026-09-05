-- =============================================================================
-- Los 34 códigos de la hoja: ¿qué producto los tiene, y quién los tiene ya?
--
-- NO ESCRIBE NADA. Contesta cuatro cosas por renglón:
--   1. ¿Existe el producto en el sistema?
--   2. ¿Ya tiene código, y es el mismo de la hoja o uno distinto?
--   3. ¿Ese código YA lo usa otro insumo? (asignarlo crearía un duplicado
--      que el escáner se niega a resolver, y con razón)
--   4. ¿Hay un insumo huérfano llamado como el código? Esos son los que se
--      crearon escaneando en el anaquel: hay que fusionarlos, no dejarlos.
--
-- OJO: en este catálogo el código vive en `sku`, no en `barcode`.
-- =============================================================================

with hoja(codigo, nombre) as (values
  ('6210947538205','Alhambra'),
  ('82000727477','Smirnoff Green apple'),
  ('8001968001759','Lunaedi merlot italy'),
  ('811751021943','Stoli Gold'),
  ('721733000929','Patron Silver'),
  ('8001968001759','Lunardi pinot grigio'),
  ('7460736960123','Lagrange melocoton'),
  ('82184000335','Jack Daniels Hanney Botella'),
  ('41508015','Agua Perrier de 350 ml pequena'),
  ('7478545','Agua Perrier de 700 ml grande'),
  ('4054500131746','Zahringer premiu plis 4.8%'),
  ('4054500131746','Zahringe schwarz bier negra 4.9%'),
  ('842595138375','Bloom Pop Fresa'),
  ('842595139778','C4 Pink Limanade'),
  ('842595109368','C4 Orange'),
  ('842595121766','C4 Cosmic Rainbow'),
  ('7460548002166','Gatorlit Uva'),
  ('52000067002','Muscle Milk pro Strawberry'),
  ('52000066944','Muscle Milk pro Chocolate'),
  ('8020141203001','Agua Santa Ana'),
  ('79298000078','Agua Evian 1litro'),
  ('7466774656240','Leche Parmalat Descremada 1lt'),
  ('7466774656226','Leche Parmalat Entera 1 lt'),
  ('3800205871705','My Motto Cocoa y Cocoa'),
  ('3800205876878','My Motto Tiramisu'),
  ('787692870011','cruchy Protein Cookies'),
  ('750894680037','Sopa con Sabor a Pollo ISSIMA'),
  ('41449003153','Arina de panques'),
  ('8710428018586','Ensure advance Fresa'),
  ('8710428018595','Ensure de chocolate'),
  ('7460123476220','Leche evaporada carnation'),
  ('787545004624','Salsa china Ranchera Galon'),
  ('4054500119317','Eichbaun radler lemon o.o%'),
  ('4054500119331','Eichbaun radler gratefruits')
),
h as (
  select codigo, nombre,
         regexp_replace(translate(lower(nombre),'áéíóúüñ','aeiouun'),
                        '[^a-z0-9]','','g') as n
    from hoja
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
select
  h.nombre                       as en_la_hoja,
  h.codigo                       as codigo_de_la_hoja,
  m.name                         as producto_en_sistema,
  m.codigo_actual,
  case
    when m.id is null                        then '1. NO EXISTE: hay que crearlo'
    when m.codigo_actual = ''                then '2. LISTO PARA PONERLE EL CODIGO'
    when m.codigo_actual = h.codigo          then '3. YA LO TIENE, igual'
    else '4. YA TIENE OTRO CODIGO: ' || m.codigo_actual
  end                            as veredicto,
  -- Quién más usa ese código. Si aparece algo, NO asignarlo sin revisar.
  (select string_agg(x.name, ' | ')
     from s x
    where x.codigo_actual = h.codigo and x.id is distinct from m.id)
                                 as ojo_codigo_ya_usado_por,
  -- El insumo fantasma que se creó escaneando: su NOMBRE es el código.
  (select string_agg(x.name, ' | ') from s x where x.name = h.codigo)
                                 as huerfano_a_fusionar
from h
left join lateral (
  select s.* from s
   where s.n = h.n
      or (length(h.n) >= 5 and s.n like '%' || h.n || '%')
      or (length(s.n) >= 5 and h.n like '%' || s.n || '%')
   order by (s.n = h.n) desc, abs(length(s.n) - length(h.n))
   limit 1
) m on true
order by veredicto, h.nombre;
