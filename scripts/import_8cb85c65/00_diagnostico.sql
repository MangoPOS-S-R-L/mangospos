-- ============================================================================
-- EL RINCÓN DE ADDA — DIAGNÓSTICO PREVIO A LA CARGA DEL MENÚ
-- Business 8cb85c65-ae49-4384-a678-0d8a201a955e
--
-- CORRE ESTO PRIMERO Y PÉGAME EL RESULTADO. No escribe nada.
-- Es UNA sola consulta: el SQL Editor de Supabase solo muestra la última.
--    0) el negocio
--    1) ajustes (Ley por orden, cocina, inventario)
--    2) impuestos: hace falta UN ITBIS 18% y UNA Ley 10%, los dos activos
--    3) áreas de comanda y cuántas impresoras tiene cada una
--    4) menús
--    5) catálogo actual, categorías y grupos de modificadores
--    6) productos que YA existen con un nombre de la carta
--    7) el resto del catálogo actual (hasta 80)
--
-- Este archivo lo arma build_import_8cb85c65.py. No lo edites a mano.
-- ============================================================================

with
biz as (
  select '8cb85c65-ae49-4384-a678-0d8a201a955e'::uuid as id
),
lista(name, impreso) as (
  values
    ('Carpaccio de Lomito', 'Carpaccio de Lomito'),
    ('Aros de Calamar Rebozados', 'Aros de Calamar Rebozados'),
    ('Bruquetas de Camarón', 'Bruquetas de Camarón'),
    ('Bruquetas Caprese', 'Bruquetas Caprese'),
    ('Croquetas de Pollo', 'Croquetas de Pollo'),
    ('Focaccia', 'Focaccia'),
    ('Ensalada Verde', 'Ensalada Verde'),
    ('Ensalada Caprese', 'Ensalada Caprese'),
    ('Ensalada César', 'Ensalada César'),
    ('Ensalada César con Pollo', 'Ensalada César con Pollo'),
    ('Ensalada César con Camarones', 'Ensalada César con Camarones'),
    ('Ensalada de Aguacate', 'Ensalada de Aguacate'),
    ('Pasta Alfredo', 'Pasta Alfredo'),
    ('Pasta Carbonara', 'Pasta Carbonara'),
    ('Pasta Marinara', 'Pasta Marinara'),
    ('Pasta Caprese', 'Pasta Caprese'),
    ('Pasta a la Crema', 'Pasta a la Crema'),
    ('Pasta Cuatro Quesos', 'Pasta Cuatro Quesos'),
    ('Pizza Romana', 'Pizza Romana'),
    ('Pizza Prosciutto e Funghi', 'Pizza Prosciutto e Funghi'),
    ('Pizza Prosciutto', 'Pizza Prosciutto'),
    ('Pizza Caprese', 'Pizza Caprese'),
    ('Pizza de Vegetales', 'Pizza de Vegetales'),
    ('Pizza Pepperoni', 'Pizza Pepperoni'),
    ('Pizza Cuatro Quesos', 'Pizza Cuatro Quesos'),
    ('Pizza Marinera', 'Pizza Marinera'),
    ('Pizza Chicken Crispy', 'Pizza Chicken Crispy'),
    ('Pizza El Rincón de Adda', 'Pizza El Rincón de Adda'),
    ('Pizza de Atún y Cebolla', 'Pizza de Atún y Cebolla'),
    ('Churrasco Prime Importado', 'Churrasco Prime Importado'),
    ('Flap Meat Prime Angus', 'Flap Meat Prime Angus'),
    ('Picaña Prime Importada', 'Picaña Prime Importada'),
    ('Ribeye Prime Importado', 'Ribeye Prime Importado'),
    ('T-Bone Angus Choice Importado', 'T-Bone Angus Choice Importado'),
    ('Tomahawk Angus Choice Importado (2.5 lb)', 'Tomahawk Angus Choice Importado (2.5lb)'),
    ('Pollo a la Plancha', 'Pollo a la Plancha'),
    ('Pechuga de Pollo a la Crema', 'Pechuga de Pollo a la Crema'),
    ('Pollo a la Torre', 'Pollo a la Torre'),
    ('Lomo de Cerdo', 'Lomo de Cerdo'),
    ('Chuleta de Cerdo', 'Chuleta de Cerdo'),
    ('Costillas de Cerdo', 'Costillas de Cerdo'),
    ('Chillo Entero', 'Chillo Entero'),
    ('Filete de Mero Barsa', 'Filete de Mero Barsa'),
    ('Lomo de Atún Rojo', 'Lomo de Atún Rojo'),
    ('Filete de Salmón', 'Filete de Salmón'),
    ('Filete de Salmón en Salsa de Ajo', 'Filete de Salmón (en salsa de ajo)'),
    ('Lambí', 'Lambí'),
    ('Ceviche de Mero', 'Ceviche de Mero'),
    ('Masa de Cangrejo', 'Masa de Cangrejo'),
    ('Camarones', 'Camarones'),
    ('Pulpo', 'Pulpo'),
    ('Calamar a la Plancha', 'Calamar a la Plancha'),
    ('Aros de Calamar Salteados', 'Aros de calamar salteado'),
    ('Cola de Langosta', 'Cola de Langosta'),
    ('Cazuela de Mariscos', 'Cazuela de Mariscos'),
    ('Sopa de Mariscos', 'Sopa de Mariscos'),
    ('Salpicón de Mariscos', 'Salpicón de Mariscos'),
    ('Lambí y Pulpo', 'Lambí y Pulpo'),
    ('Mejillones al Vapor', 'Mejillones al Vapor'),
    ('Parrillada Mar y Tierra (2 personas)', 'Parrillada Mar y Tierra x2P'),
    ('Parrillada Mixta (2 personas)', 'Parrillada Mixta x2P'),
    ('Parrillada de Mariscos (2 personas)', 'Parrillada de Mariscos x2P'),
    ('Paella (2 personas)', 'Paella x2P'),
    ('Mofongo de Camarones', 'Mofongo de Camarones'),
    ('Mofongo de Pollo', 'Mofongo de Pollo'),
    ('Arroz Blanco', 'Arroz Blanco'),
    ('Vegetales', 'Vegetales al grill, salteados o al vapor'),
    ('Papas', 'Papas fritas, salteadas, al vapor o en puré'),
    ('Tostones', 'Tostones'),
    ('Pan con Ajo', 'Pan con Ajo'),
    ('Addana Apple', 'Addana Apple'),
    ('Addita', 'Addita'),
    ('Papá Chelo', 'Papá Chelo'),
    ('La Ex', 'La Ex'),
    ('La Rabiosa', 'La Rabiosa'),
    ('La Insoportable', 'La Insoportable'),
    ('Piña Colada', 'Piña Colada'),
    ('Watermelon Sunset', 'Watermelon Sunset'),
    ('Wild Forest', 'Wild Forest'),
    ('Ruso Blanco', 'Ruso Blanco'),
    ('Ruso Negro', 'Ruso Negro'),
    ('Vodka Sunrise', 'Vodka Sunrise'),
    ('Vodka Tonic', 'Vodka Tonic'),
    ('Screwdriver', 'Screwdriver'),
    ('Pink Tonic', 'Pink Tonic'),
    ('Gin Tonic', 'Gin Tonic'),
    ('Mojito de Pitahaya', 'Mojito de Pitahaya'),
    ('Mojito de Limón', 'Mojito de Limón'),
    ('Mojito de Morir Soñando', 'Mojito de Morir Soñando'),
    ('Mojito de Chinola', 'Mojito de Chinola'),
    ('Margarita de Limón', 'Margarita de Limón'),
    ('Margarita de Fresa', 'Margarita de Fresa'),
    ('Margarita de Chinola', 'Margarita de Chinola'),
    ('Cuba Libre', 'Cuba Libre'),
    ('Cuba Libre Doble Reserva', 'Cuba Libre Doble Reserva'),
    ('Smoothie de Fresa', 'Smoothie de Fresa'),
    ('Limonada Coco', 'Limonada Coco'),
    ('Sangría', 'Sangría'),
    ('Frozen', 'Frozen'),
    ('Shot de Canelilla', 'Shot de Canelilla'),
    ('Shot de Barceló', 'Shot de Barceló'),
    ('Shot de Baileys', 'Shot de Baileys'),
    ('Shot de Tequila', 'Shot de Tequila'),
    ('Trago Johnnie Walker Black Label', 'Trago Johnny Walker Black Label'),
    ('Trago Old Parr', 'Trago Old Parr'),
    ('Trago Jack Daniel''s', 'Trago Jack Daniel''s'),
    ('Porto Tinto', 'Porto Tinto'),
    ('Casillero del Diablo Tinto Merlot', 'Casillero del Diablo Tinto Merlot'),
    ('Bogle Tinto', 'Bogle Tinto'),
    ('Casillero del Diablo Cabernet Tinto', 'Casillero del Diablo Cabernet Tinto'),
    ('19 Crimes', '19 Crimemenes'),
    ('Carlo Rossi', 'Carlo Rossi'),
    ('Copa de Vino de la Casa', 'Copa de Vino de la Casa'),
    ('Copa de Vino Porto', 'Copa de Vino Porto'),
    ('Copa de Vino 19 Crimes', 'Copa de Vino 19 Crimes'),
    ('Copa de Vino Casillero del Diablo', 'Copa de Vino Casillero del Diablo'),
    ('Copa de Vino Bogle', 'Copa de Vino Bogle'),
    ('Cerveza Corona', 'Cerveza Corona'),
    ('Cerveza Presidente', 'Cerveza Presidente'),
    ('Cerveza Smirnoff', 'Cerveza Smirnoff'),
    ('Cerveza Modelo', 'Cerveza Modelo'),
    ('Jugo de Sandía con Limón', 'Jugo de Sandía con Limón'),
    ('Limonada Natural', 'JUGO DE LIMON'),
    ('Jugo de Chinola', 'Jugo de Chinola'),
    ('Jugo de Piña', 'Jugo de Piña'),
    ('Café Negro', 'Café Negro'),
    ('AGUA DASANI', 'Agua'),
    ('Enriquillo', 'Enriquillo'),
    ('Agua Tónica', 'Agua Tónica'),
    ('Refresco Coca Cola Peq.', 'Refresco Coca Cola Peq.'),
    ('Refresco Merengue Peq.', 'Refresco Merengue Peq.'),
    ('Refresco Naranja Peq.', 'Refresco Naranja Peq.'),
    ('Refresco Seven Up Peq.', 'Refresco Seven Up Peq.'),
    ('Refresco Sprite Peq.', 'Refresco Sprite Peq.'),
    ('Refresco Coca Cola 2 Litros', 'Refresco Coca Cola 2 Litros')
),
nk as (
  select translate(lower(regexp_replace(btrim(name), '\s+', ' ', 'g')),
                   'áéíóúüñÁÉÍÓÚÜÑ', 'aeiouunaeiouun') as k1,
         translate(lower(regexp_replace(btrim(impreso), '\s+', ' ', 'g')),
                   'áéíóúüñÁÉÍÓÚÜÑ', 'aeiouunaeiouun') as k2
  from lista
),
prods as (
  select mi.*,
         translate(lower(regexp_replace(btrim(mi.name), '\s+', ' ', 'g')),
                   'áéíóúüñÁÉÍÓÚÜÑ', 'aeiouunaeiouun') as k,
         exists (select 1 from public.order_items oi
                 where oi.product_id = mi.id) as vendido
  from public.menu_items mi, biz
  where mi.business_id = biz.id
),
choca as (
  select p.id
  from prods p
  where p.k in (select k1 from nk) or p.k in (select k2 from nk)
),
tx as (
  select t.*, to_jsonb(t) as j
  from public.taxes t, biz
  where t.business_id = biz.id
),
r(orden, sub, seccion, detalle) as (
  select 0, 0, '0 Negocio',
         format('%s%s · tipo=%s · creado %s',
                coalesce(b.j->>'business_name', '—'),
                coalesce(' · ' || nullif(btrim(b.j->>'branch_name'), ''), ''),
                coalesce(b.j->>'business_type', '—'),
                coalesce(to_char((b.j->>'created_at')::timestamptz
                                 at time zone 'America/Santo_Domingo', 'DD/MM/YYYY'), '—'))
  from (select to_jsonb(x) as j from public.businesses x, biz where x.id = biz.id) b
  union all
  select 0, 0, '0 Negocio', 'NO EXISTE'
  where not exists (select 1 from public.businesses x, biz where x.id = biz.id)

  union all
  select 1, 1, '1 Ajustes',
         format('service_fee_enabled=%s · kitchen_enabled=%s · printerless_kitchen=%s · '
                'auto_print_order=%s · inventory_mode=%s · moneda=%s',
                coalesce(s.j->>'service_fee_enabled', '—'),
                coalesce(s.j->>'kitchen_enabled', '—'),
                coalesce(s.j->>'printerless_kitchen', '—'),
                coalesce(s.j->>'auto_print_order', '—'),
                coalesce(s.j->>'inventory_mode', '—'),
                coalesce(s.j->>'currency_code', '—'))
  from (select to_jsonb(bs) as j
        from public.business_settings bs, biz
        where bs.business_id = biz.id) s
  union all
  select 1, 1, '1 Ajustes', 'sin fila en business_settings'
  where not exists (select 1 from public.business_settings bs, biz where bs.business_id = biz.id)

  union all
  select 2, 0, '2 Impuesto',
         format('%s %s%% · activo=%s · is_service_fee=%s · include_in_ecf=%s · '
                'zona=%s manual=%s rápida=%s llevar=%s delivery=%s · productos vinculados=%s',
                t.name, t.rate,
                coalesce(t.j->>'is_active', '—'), coalesce(t.j->>'is_service_fee', '—'),
                coalesce(t.j->>'include_in_ecf', '—'),
                coalesce(t.j->>'apply_on_zone', '—'), coalesce(t.j->>'apply_on_manual', '—'),
                coalesce(t.j->>'apply_on_quick', '—'),
                coalesce(t.j->>'apply_on_takeout', '—'),
                coalesce(t.j->>'apply_on_delivery', '—'),
                (select count(*) from public.menu_item_taxes x where x.tax_id = t.id))
  from tx t
  union all
  select 2, 0, '2 Impuesto', 'ninguno: crea el ITBIS 18% y la Ley 10% en la app'
  where not exists (select 1 from tx)

  union all
  select 3, 0, '3 Área de comanda',
         format('%s (code %s) · activa=%s · impresoras=%s · productos=%s',
                a.name, a.code, a.is_active,
                (select count(*) from public.print_area_printers p where p.area_id = a.id),
                (select count(*) from public.menu_item_print_areas x
                 where x.print_area_id = a.id))
  from public.print_areas a, biz
  where a.business_id = biz.id
  union all
  select 3, 0, '3 Área de comanda', 'ninguna'
  where not exists (select 1 from public.print_areas a, biz where a.business_id = biz.id)

  union all
  select 4, 0, '4 Menú',
         format('%s · activo=%s · productos enlazados=%s',
                m.name, m.is_active,
                (select count(*) from public.menu_item_links l where l.menu_id = m.id))
  from public.menus m, biz
  where m.business_id = biz.id
  union all
  select 4, 0, '4 Menú', 'ninguno (la carga crea «Menú Principal»)'
  where not exists (select 1 from public.menus m, biz where m.business_id = biz.id)

  union all
  select 5, 0, '5 Catálogo',
         format('categorías=%s · productos=%s (activos %s) · con ventas=%s · '
                'grupos de modificadores=%s · tax_mode: inclusive %s / exclusive %s',
                (select count(*) from public.categories c, biz where c.business_id = biz.id),
                (select count(*) from prods),
                (select count(*) from prods where is_active),
                (select count(*) from prods where vendido),
                (select count(*) from public.modifier_groups g, biz where g.business_id = biz.id),
                (select count(*) from prods where tax_mode = 'inclusive'),
                (select count(*) from prods where tax_mode = 'exclusive'))
  union all
  select 5, 1, '5 Categoría',
         format('%s · posición %s · activa=%s · productos activos=%s',
                c.name, c.position, c.is_active,
                (select count(*) from prods p where p.category_id = c.id and p.is_active))
  from public.categories c, biz
  where c.business_id = biz.id
  union all
  select 5, 2, '5 Grupo de modificadores',
         format('%s · min %s / max %s · activo=%s · opciones=%s · productos=%s',
                g.name, g.min_select, g.max_select, g.is_active,
                (select count(*) from public.modifiers m where m.group_id = g.id),
                (select count(*) from public.menu_item_groups y where y.group_id = g.id))
  from public.modifier_groups g, biz
  where g.business_id = biz.id

  union all
  select 6, 0, '6 Ya existe (nombre de la carta)',
         format('%s · $%s %s · activo=%s · categoría %s · área %s · ventas=%s',
                p.name, p.price, p.tax_mode, p.is_active,
                coalesce((select c.name from public.categories c
                          where c.id = p.category_id), '—'),
                coalesce(p.print_area_code, '—'),
                case when p.vendido then 'sí' else 'no' end)
  from prods p
  where p.id in (select id from choca)
  union all
  select 6, 0, '6 Ya existe (nombre de la carta)', 'ninguno'
  where not exists (select 1 from choca)

  union all
  select 7, 0, '7 Otro producto del catálogo',
         format('%s · $%s %s · activo=%s · categoría %s · área %s · ventas=%s',
                p.name, p.price, p.tax_mode, p.is_active,
                coalesce((select c.name from public.categories c
                          where c.id = p.category_id), '—'),
                coalesce(p.print_area_code, '—'),
                case when p.vendido then 'sí' else 'no' end)
  from (select * from prods
        where id not in (select id from choca)
        order by name
        limit 80) p
)
select seccion, detalle
from r
order by orden, sub, detalle;
