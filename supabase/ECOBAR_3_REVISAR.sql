-- =============================================================================
-- ECO BAR & LOUNGE — los puntos del PDF que quedaron a interpretación.
-- Negocio: fc3065c8-cb40-45ad-bec1-aecb388001c1
--
-- El PDF tiene la columna de precios desalineada en el bloque de WHISKEY y
-- un par de renglones contradictorios. Abajo está lo que se cargó y el UPDATE
-- listo para corregir lo que el dueño confirme. NADA de esto se corre solo:
-- descoméntalo cuando tengas la respuesta.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- A. WHISKEY: el PDF trae 18 precios para 17 marcas. Estos son los que se
--    dedujeron por coherencia (marca más cara = precio más alto). Confírmalos.
-- ---------------------------------------------------------------------------
select name, price
  from public.menu_items
 where business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1' and is_active
   and name ~* '^(Jack Daniel|Jim Beam|JW |Old Parr|Glenfiddich|The Glenlivet|The Macallan)'
 order by name;

-- Cargado hoy (botella / trago):
--   Jack Daniel's           3,500 / 350
--   Jim Beam Bourbon        3,000 / 350
--   JW Black Label          4,500 / 500
--   JW Doble Black          5,500 / 600
--   JW Gold Label           7,000 / 700
--   Old Parr 12             4,500 / 450
--   Glenfiddich 12          6,000 (sin trago en el PDF)
--   The Glenlivet Founders  4,500 (sin trago en el PDF)
--   The Macallan 12        11,000 (sin trago en el PDF)
--
-- Para corregir uno:
-- update public.menu_items set price = 4000, updated_at = now()
--  where business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1'
--    and name = 'Jim Beam Bourbon (Botella)';


-- ---------------------------------------------------------------------------
-- B. "19 Crime Cali Rosé" sale DOS VECES en el PDF con precios distintos:
--    $1,300 en VINOS TINTO y $2,300 en VINOS ROSADO.
--    Se cargó UNA sola vez, en ROSADO, a $2,300.
-- ---------------------------------------------------------------------------
-- update public.menu_items set price = 1300, updated_at = now()
--  where business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1'
--    and name = '19 Crimes Cali Rosé';


-- ---------------------------------------------------------------------------
-- C. "Schweppes Ginger Ale" aparece dentro de CÓCTELES a $550, descrito como
--    refresco. Si es refresco, muévelo a JUGOS / MIXERS y ajusta el precio.
-- ---------------------------------------------------------------------------
-- update public.menu_items mi
--    set price = 155,
--        category_id = (select id from public.categories
--                        where business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1'
--                          and name = 'JUGOS / MIXERS' and is_active),
--        updated_at = now()
--  where mi.business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1'
--    and mi.name = 'Schweppes Ginger Ale';


-- ---------------------------------------------------------------------------
-- D. "Piña Colada DOP $400/300" — dos precios sin decir de qué.
--    Se cargó a $400. Y la versión CON alcohol sale más barata ($350) que la
--    de sin alcohol: eso casi seguro está al revés en el PDF.
-- ---------------------------------------------------------------------------
select name, price from public.menu_items
 where business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1' and is_active
   and name ilike 'Piña Colada%';


-- ---------------------------------------------------------------------------
-- E. Langosta y Chillo son "precio por libra". Se cargaron como unidad, con
--    la aclaración en el nombre. Si quieres cobrarlos por peso real:
-- ---------------------------------------------------------------------------
-- update public.menu_items set sold_by = 'weight', updated_at = now()
--  where business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1'
--    and name in ('Langosta Caribeña (por libra)', 'Chillo del Mar Caribe (por libra)');


-- ---------------------------------------------------------------------------
-- F. Vodka, Ginebra y Tequila: el PDF SOLO trae precio de botella, así que se
--    cargaron solo como "(Botella)". Si venden trago de estas marcas, hay que
--    crear el producto. Plantilla (repite por marca y ajusta el precio):
-- ---------------------------------------------------------------------------
-- insert into public.menu_items (
--   business_id, category_id, name, price, tax_mode, is_active, description,
--   is_beverage, sold_by, position, print_area_code, updated_at)
-- select 'fc3065c8-cb40-45ad-bec1-aecb388001c1', c.id,
--        'Absolut (Trago)', 350, 'exclusive', true, 'Trago / shot.',
--        true, 'unit', 99,
--        (select code from public.print_areas
--          where business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1' and code = 'bar'),
--        now()
--   from public.categories c
--  where c.business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1'
--    and c.name = 'VODKA' and c.is_active;
--
-- -- y NO OLVIDES vincularle los impuestos y el área, o factura en ITBIS 0:
-- insert into public.menu_item_taxes (item_id, tax_id)
-- select mi.id, mit.tax_id
--   from public.menu_items mi
--   join public.menu_item_taxes mit on mit.item_id = (
--        select id from public.menu_items
--         where business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1'
--           and name = 'Absolut (Botella)')
--  where mi.business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1'
--    and mi.name = 'Absolut (Trago)'
-- on conflict do nothing;
