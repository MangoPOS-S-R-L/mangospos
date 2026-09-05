-- =============================================================================
-- ECO BAR & LOUNGE — cerrar lo que quedó a medias tras correr ECOBAR_1.
-- Negocio: fc3065c8-cb40-45ad-bec1-aecb388001c1
--
-- QUÉ PASÓ: se corrió ECOBAR_1_CARGAR_MENU.sql. El menú quedó bien —284
-- productos, cotejados contra el PDF sin un solo precio distinto— pero
-- arrastró dos cosas:
--
--   1. SOLO SE VINCULÓ EL ITBIS. El script replicaba "el set de impuestos que
--      usaba la mayoría del menú viejo", y en el menú viejo la LEY estaba en
--      3 de 280 productos: no era mayoría, así que no la replicó y cayó al
--      fallback de ITBIS. Hoy la carta factura 18% en vez de 28%.
--
--   2. Las categorías se recrearon en MAYÚSCULAS y en posiciones 1..33. Antes
--      estaban en Capitalización normal y en el orden curado 10, 20, 30...
--      que el dueño había armado. Eso se recupera aquí.
--
--   3. NINGÚN producto estaba enlazado a un menú. El POS filtra por menú
--      (v_menu_items_list.eq('menu_id')) y ese menu_id sale de
--      menu_item_links: producto sin vínculo = producto que NO aparece
--      cuando hay un menú seleccionado. Aquí se enlaza la carta completa al
--      menú principal.
--
-- No toca precios, ni nombres de productos, ni el histórico de ventas.
-- Pega TODO de una vez en el SQL Editor de Supabase.
-- =============================================================================


-- ---------------------------------------------------------------------------
-- 0. CORTAFUEGOS: la LEY no puede ser is_service_fee (eso factura doble), y
--    no puede haber cuentas abiertas mientras se cambia la tasa.
-- ---------------------------------------------------------------------------
do $$
declare
  v_biz constant uuid := 'fc3065c8-cb40-45ad-bec1-aecb388001c1';
  v_open int;
  v_bad  text;
begin
  select string_agg(name, ', ') into v_bad
    from public.taxes
   where business_id = v_biz and is_active and is_service_fee is true;

  if v_bad is not null then
    raise exception 'El impuesto "%" tiene is_service_fee = true. Apágalo primero: con eso prendido el servidor lo mete en oi.tax y el cliente lo saca aparte, o sea la factura lo cobra DOS VECES.', v_bad;
  end if;

  if not exists (select 1 from public.taxes
                  where business_id = v_biz and is_active and name ilike '%ley%') then
    raise exception 'No hay un impuesto LEY activo en este negocio.';
  end if;

  select count(distinct o.id) into v_open
    from public.orders o
    join public.order_items oi on oi.order_id = o.id
    join public.menu_items mi on mi.id = oi.product_id
   where mi.business_id = v_biz and o.status = 'open';

  if v_open > 0 then
    raise exception 'Hay % cuenta(s) abierta(s). Espera a cerrarlas: los ítems ya cargados guardaron la tasa vieja.', v_open;
  end if;
end $$;


-- ---------------------------------------------------------------------------
-- 1. LA LEY 10% A TODA LA CARTA. Esto es lo urgente.
-- ---------------------------------------------------------------------------
insert into public.menu_item_taxes (item_id, tax_id)
select mi.id, t.id
  from public.menu_items mi
  cross join public.taxes t
 where mi.business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1'
   and mi.is_active
   and t.business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1'
   and t.is_active
   and t.name ilike '%ley%'
on conflict do nothing;

update public.menu_items
   set updated_at = now()
 where business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1' and is_active;


-- ---------------------------------------------------------------------------
-- 2. DEVOLVER A LAS CATEGORÍAS SU NOMBRE Y SU ORDEN.
--    Se empareja por el nombre en MAYÚSCULAS que dejó ECOBAR_1.
-- ---------------------------------------------------------------------------
drop table if exists _ren;
create temp table _ren(de text primary key, a text, pos int);
insert into _ren(de, a, pos) values
  ('PLATOS FUERTES',              'Platos Fuertes',              10),
  ('ENTRADAS',                    'Entradas',                    20),
  ('MOFONGO',                     'Mofongo',                     30),
  ('CÓCTELES',                    'Cócteles',                    40),
  ('ANTOJOS',                     'Antojos',                     50),
  ('RINCOCITOS DE LOS ECOPEQUES', 'Rincocitos de los Ecopeques', 60),
  ('DELICIAS DEL MAR',            'Delicias del Mar',            70),
  ('ENSALADAS',                   'Ensaladas',                   80),
  ('ARROCES AL ESTILO ECOBAR',    'Arroces al Estilo Ecobar',    90),
  ('ADICIONALES',                 'Adicionales',                 95),
  ('PASTAS',                      'Pastas',                     100),
  ('HAMBURGUESAS',                'Hamburguesas',               110),
  ('GUARNICIONES',                'Guarniciones',               120),
  ('POSTRES',                     'Postres',                    130),
  ('AGUAS / SABORIZADAS',         'Aguas / Saborizadas',        140),
  ('JUGOS / MIXERS',              'Jugos / Mixers',             150),
  ('RONES / TRAGOS',              'Rones',                      160),
  ('WHISKEY / TRAGOS',            'Whiskey',                    170),
  ('VODKA',                       'Vodka',                      180),
  ('GINEBRA',                     'Ginebra',                    190),
  ('TEQUILA',                     'Tequila',                    200),
  ('DIGESTIVOS',                  'Digestivos',                 210),
  ('GIN TONIC',                   'Gin Tonic',                  220),
  ('COPAS DE VINO',               'Copas de Vino',              230),
  ('VINOS TINTO',                 'Vinos Tinto',                240),
  ('VINOS BLANCOS',               'Vinos Blancos',              250),
  ('VINOS ROSADO',                'Vinos Rosado',               260),
  ('CAVA / PROSECCO',             'Cava / Prosecco',            270),
  ('CHAMPAGNE',                   'Champagne',                  280),
  ('CERVEZAS',                    'Cervezas',                   290),
  ('CIGARROS',                    'Cigarros',                   300),
  ('CIGARRILLOS',                 'Cigarrillos',                310),
  ('CAFÉ',                        'Café',                       320);

update public.categories c
   set name = r.a, position = r.pos
  from _ren r
 where c.business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1'
   and c.is_active
   and c.name = r.de;


-- ---------------------------------------------------------------------------
-- 3. Las categorías viejas quedaron apagadas pero con el MISMO nombre que las
--    nuevas. Se les pone un sufijo para que nadie —ni una consulta futura—
--    las confunda con las buenas.
-- ---------------------------------------------------------------------------
update public.categories
   set name = name || ' (anterior)'
 where business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1'
   and not is_active
   and name not like '% (anterior)';


-- ---------------------------------------------------------------------------
-- 3b. TODA LA CARTA AL MENÚ PRINCIPAL.
--
--     Si el negocio no tiene ningún menú, se crea "Menú Principal". Si tiene
--     uno, se usa ese. Si tiene VARIOS, el script se detiene: "principal" ya
--     no sería obvio y no me toca adivinar cuál.
-- ---------------------------------------------------------------------------
drop table if exists _menu;
create temp table _menu(menu_id uuid);

do $$
declare
  v_biz   constant uuid := 'fc3065c8-cb40-45ad-bec1-aecb388001c1';
  v_n     int;
  v_lista text;
begin
  select count(*), string_agg(name, ', ' order by created_at)
    into v_n, v_lista
    from public.menus
   where business_id = v_biz and is_active;

  if v_n > 1 then
    raise exception 'Este negocio tiene % menús activos (%). Dime en cuál va la carta completa y lo fijo en el script.', v_n, v_lista;
  end if;

  if v_n = 0 then
    insert into public.menus (id, business_id, name, is_active)
    values (gen_random_uuid(), v_biz, 'Menú Principal', true);
    raise notice 'No había ningún menú: se creó "Menú Principal".';
  end if;

  insert into _menu
  select id from public.menus where business_id = v_biz and is_active;
end $$;

-- Vínculos a cualquier OTRO menú: se van, para que la carta viva en uno solo.
-- (La vista se queda con el primer vínculo por posición, así que dos menús
--  para el mismo producto es una lotería silenciosa.)
delete from public.menu_item_links l
 using public.menu_items mi
 where mi.id = l.item_id
   and mi.business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1'
   and l.menu_id not in (select menu_id from _menu);

-- Y ahora sí: los 284 al menú principal, en el orden del catálogo
-- (posición de la categoría × 1000 + posición del producto).
insert into public.menu_item_links (menu_id, item_id, position)
select m.menu_id,
       mi.id,
       coalesce(c.position, 0) * 1000 + coalesce(mi.position, 0)
  from public.menu_items mi
  cross join _menu m
  left join public.categories c on c.id = mi.category_id
 where mi.business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1'
   and mi.is_active
on conflict (menu_id, item_id) do nothing;


-- ---------------------------------------------------------------------------
-- 4. RESULTADO. Las cuatro de la derecha tienen que dar 0.
-- ---------------------------------------------------------------------------
select count(*)                                                    as productos_activos,
       count(*) filter (where not exists (
         select 1 from public.menu_item_taxes t
          join public.taxes tx on tx.id = t.tax_id and tx.name ilike '%itbis%'
         where t.item_id = menu_items.id))                          as SIN_ITBIS,
       count(*) filter (where not exists (
         select 1 from public.menu_item_taxes t
          join public.taxes tx on tx.id = t.tax_id and tx.name ilike '%ley%'
         where t.item_id = menu_items.id))                          as SIN_LEY,
       count(*) filter (where print_area_code is null)              as SIN_AREA,
       count(*) filter (where not exists (
         select 1 from public.menu_item_links l
          where l.item_id = menu_items.id))                          as SIN_MENU,
       count(*) filter (where tax_mode <> 'exclusive')              as TAX_MODE_MALO
  from public.menu_items
 where business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1' and is_active;


-- 4b. La carta como la va a ver el mesero.
select c.position as orden, c.name as categoria, count(mi.id) as productos,
       min(mi.print_area_code) as area
  from public.categories c
  left join public.menu_items mi on mi.category_id = c.id and mi.is_active
 where c.business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1' and c.is_active
 group by c.position, c.name
 order by c.position;


-- 4bb. El menú y cuántos productos le quedaron colgados.
select mn.name as menu, mn.is_active, count(l.item_id) as productos
  from public.menus mn
  left join public.menu_item_links l on l.menu_id = mn.id
 where mn.business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1'
 group by mn.name, mn.is_active
 order by mn.name;


-- 4c. Un precio de ejemplo, ya con los dos impuestos.
select mi.name, mi.price as carta,
       round(mi.price * 0.18, 2) as itbis,
       round(mi.price * 0.10, 2) as ley,
       round(mi.price * 1.28, 2) as total_cliente
  from public.menu_items mi
 where mi.business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1' and mi.is_active
   and mi.name in ('Presidente Regular', 'Ribeye', 'Eco Spritz')
 order by mi.price;


-- ---------------------------------------------------------------------------
-- 5. PRODUCTOS DUPLICADOS POR EL CAMBIO.
--
--    ECOBAR_1 no borró los productos que ya tenían ventas: los desactivó, y
--    creó uno nuevo con el mismo nombre. O sea que esos productos existen dos
--    veces: la fila vieja (apagada) que sostiene las ventas anteriores, y la
--    nueva (encendida) que recibe las de ahora. En los reportes por producto
--    van a salir partidos en dos.
-- ---------------------------------------------------------------------------
select mi.name                                        as producto,
       mi.price,
       (select count(*) from public.order_items oi
         where oi.product_id = mi.id)                 as ventas_que_sostiene,
       mi.created_at::date                            as creado
  from public.menu_items mi
 where mi.business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1'
   and not mi.is_active
 order by mi.name;


-- ---------------------------------------------------------------------------
-- 6. OPCIONAL — unificar esos duplicados.
--
--    Reapunta las ventas viejas al producto nuevo y borra la fila apagada,
--    para que el histórico por producto quede en una sola línea. Es el MISMO
--    producto (mismo nombre, mismo precio), así que la atribución no miente.
--    El ticket impreso no cambia: order_items guarda product_name aparte.
--
--    Descomenta y corre SOLO si el listado del paso 5 te cuadra.
-- ---------------------------------------------------------------------------
-- update public.order_items oi
--    set product_id = nuevo.id
--   from public.menu_items viejo
--   join public.menu_items nuevo
--     on nuevo.business_id = viejo.business_id
--    and nuevo.name = viejo.name
--    and nuevo.is_active
--  where oi.product_id = viejo.id
--    and viejo.business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1'
--    and not viejo.is_active;
--
-- delete from public.menu_items mi
--  where mi.business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1'
--    and not mi.is_active
--    and not exists (select 1 from public.order_items oi where oi.product_id = mi.id)
--    and not exists (select 1 from public.order_item_modifiers om where om.menu_item_id = mi.id);


-- ---------------------------------------------------------------------------
-- 7. PARA DESPUÉS:
--
--    · Con ITBIS 18% + LEY 10% la tasa suma 28%. Si este negocio activa e-CF,
--      hay un bug conocido que declara EXENTO lo que lleva Ley cuando la tasa
--      sumada no es 18. Hay que arreglarlo ANTES de prender e-CF aquí.
--
--    · La LEY hoy está en apply_on_takeout = true: se cobra también en pedidos
--      para llevar. Decide con el dueño si eso queda así.
--
--    · Los respaldos del menú anterior siguen ahí por si acaso. Cuando estés
--      tranquilo:
--      drop table if exists public.zzz_ecobar_bk_menu_items;
--      drop table if exists public.zzz_ecobar_bk_categories;
--      drop table if exists public.zzz_ecobar_bk_menu_item_taxes;
--      drop table if exists public.zzz_ecobar_bk_menu_item_print_areas;
--      drop table if exists public.zzz_ecobar_bk_recipes;
--      drop table if exists public.zzz_ecobar_bk_recipe_ingredients;
-- ---------------------------------------------------------------------------
