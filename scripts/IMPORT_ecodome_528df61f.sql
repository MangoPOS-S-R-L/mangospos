-- =============================================================================
-- Carga de catalogo ECODOME VILLAGE — Business 528df61f-7136-4591-9e87-ee19f5882037
--
-- Origen : export_items (2).csv  (export de Loyverse)
-- Genera : scripts/build_ecodome_import_528df61f.py  (NO editar a mano)
--
--   42 productos | 8 categorias
--
-- SIN IMPUESTOS: no se escribe una sola fila en menu_item_taxes. Esa tabla
-- es la UNICA fuente del impuesto por producto, asi que la factura sale con
-- ITBIS 0.00 — decision del dueno, no un descuido. Los precios del archivo
-- son FINALES y redondos (50, 250, 1200): el cliente paga lo que dice el
-- menu, no hay nada que sumar ni que sacar.
--
-- DECISIONES QUE NO SALEN DEL ARCHIVO:
--   * 7 productos venian SIN categoria en Loyverse. Los 4 tragos
--     (Margarita, Mojito, Pina Colada, Sangria Roja) van a `Cocteles`,
--     categoria NUEVA; los 3 Smirnoff van a la `Cerveza` que ya existe.
--   * `Plato del dia - Nino` (sku 10028) traia el precio literal
--     "variable". Entra en 0.00 pero con is_active = FALSE, para que nadie
--     lo despache gratis. Ponle precio en la app y actualo.
--   * Las existencias de Loyverse (11 productos) NO se cargan aqui.
--   * cost queda NULL: el archivo trae 0.00 en los 42, y 0 se leeria como
--     "cuesta cero" dando 100%% de margen en los reportes.
--
-- ANTI-DUPLICADOS: el match es por NOMBRE normalizado (mayusculas, sin
-- acentos, espacios colapsados), no por sku — un producto creado a mano en
-- la app no tiene sku y se duplicaria. Tres reglas:
--   A. Nombre unico en el archivo Y unico en el catalogo -> ACTUALIZA + sku.
--   B. Nombre que no existe en el catalogo               -> INSERTA.
--   C. Nombre ambiguo                                    -> NO SE TOCA.
-- Con el catalogo vacio todo cae en la regla B y entra limpio.
--
-- IDEMPOTENTE: re-ejecutarlo no duplica. Todo en UNA transaccion.
--
-- DESPUES corre scripts/AREAS_ecodome_528df61f.sql, si no los productos
-- quedan sin area y "Enviar a cocina" se bloquea sin decir por que.
--
-- Correr en Supabase Studio -> SQL Editor.
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 0) El negocio tiene que existir
-- ---------------------------------------------------------------------------
do $$
declare
  v_business uuid := '528df61f-7136-4591-9e87-ee19f5882037';
begin
  if not exists (select 1 from public.businesses b where b.id = v_business) then
    raise exception 'El negocio % no existe', v_business;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 1) Categorias (crea solo las que falten; respeta las que ya esten)
-- ---------------------------------------------------------------------------
insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), '528df61f-7136-4591-9e87-ee19f5882037'::uuid, v.name, v.pos, true
from (values
  ('Bebida sin Alcohol', 1),
  ('Cerveza', 2),
  ('Comida', 3),
  ('Cócteles', 4),
  ('Ron', 5),
  ('Tequila', 6),
  ('Vino', 7),
  ('Whiskey', 8)
) as v(name, pos)
where not exists (
  select 1 from public.categories c
  where c.business_id = '528df61f-7136-4591-9e87-ee19f5882037'::uuid and c.name = v.name
);

-- ---------------------------------------------------------------------------
-- 2) El archivo
-- ---------------------------------------------------------------------------
create temp table _stage (
  sku text primary key, name text, cat text,
  price numeric, cost numeric, active boolean
) on commit drop;

insert into _stage (sku, name, cat, price, cost, active) values
  ('10020', 'Agua', 'Bebida sin Alcohol', 50.00, NULL, true),
  ('10030', 'Baso con Heilo', 'Bebida sin Alcohol', 25.00, NULL, true),
  ('10033', 'Brugal Añejo', 'Ron', 200.00, NULL, true),
  ('10014', 'Brugal Doble Reserva', 'Ron', 300.00, NULL, true),
  ('10005', 'Brugal Extra Viejo', 'Ron', 250.00, NULL, true),
  ('10013', 'Buchanan''s', 'Whiskey', 400.00, NULL, true),
  ('10023', 'Cafe', 'Bebida sin Alcohol', 50.00, NULL, true),
  ('10029', 'Carga de Hielo', 'Bebida sin Alcohol', 50.00, NULL, true),
  ('10025', 'Carne Salada con Papa', 'Comida', 350.00, NULL, true),
  ('10024', 'Carne Salada con Tostone', 'Comida', 350.00, NULL, true),
  ('10018', 'Coca Cola', 'Bebida sin Alcohol', 50.00, NULL, true),
  ('10009', 'Corona Pequeña', 'Cerveza', 250.00, NULL, true),
  ('10036', 'Corona Pequeña Light', 'Cerveza', 250.00, NULL, true),
  ('10016', 'Don Julio Shot', 'Tequila', 500.00, NULL, true),
  ('10041', 'Frontera Botella', 'Vino', 1200.00, NULL, true),
  ('10011', 'Heineken Pequeña', 'Cerveza', 200.00, NULL, true),
  ('10015', 'Johnnie Walker Black Label', 'Whiskey', 400.00, NULL, true),
  ('10002', 'Jugo de Chinola', 'Bebida sin Alcohol', 100.00, NULL, true),
  ('10022', 'Jugo de Fruit Punch', 'Bebida sin Alcohol', 100.00, NULL, true),
  ('10021', 'Jugo de Limon', 'Bebida sin Alcohol', 100.00, NULL, true),
  ('10003', 'Margarita', 'Cócteles', 350.00, NULL, true),
  ('10004', 'Mojito', 'Cócteles', 300.00, NULL, true),
  ('10017', 'Patron Shot', 'Tequila', 500.00, NULL, true),
  ('10032', 'Pechurina con Papa', 'Comida', 350.00, NULL, true),
  ('10031', 'Pechurina con Tostone', 'Comida', 350.00, NULL, true),
  ('10035', 'Picadera Fría', 'Comida', 200.00, NULL, true),
  ('10034', 'Picadera Mixta', 'Comida', 400.00, NULL, true),
  ('10001', 'Piña Colada', 'Cócteles', 275.00, NULL, true),
  ('10027', 'Plato de Día - extra', 'Comida', 550.00, NULL, true),
  ('10026', 'Plato del Día', 'Comida', 450.00, NULL, true),
  ('10028', 'Plato del dia - Nino', 'Comida', 0.00, NULL, false),
  ('10000', 'Presidente Pequeña', 'Cerveza', 150.00, NULL, true),
  ('10037', 'Presidente Pequeña Light', 'Cerveza', 150.00, NULL, true),
  ('10012', 'Sangria Roja', 'Cócteles', 275.00, NULL, true),
  ('10039', 'Smirnoff Green Apple', 'Cerveza', 250.00, NULL, true),
  ('10040', 'Smirnoff Original', 'Cerveza', 250.00, NULL, true),
  ('10010', 'Smirnoff Raspberry', 'Cerveza', 250.00, NULL, true),
  ('10019', 'Sprite', 'Bebida sin Alcohol', 50.00, NULL, true),
  ('10038', 'Tonic', 'Bebida sin Alcohol', 50.00, NULL, true),
  ('10007', 'Vino Blanco', 'Vino', 275.00, NULL, true),
  ('10006', 'Vino Rojo', 'Vino', 275.00, NULL, true),
  ('10008', 'Vino Rose', 'Vino', 275.00, NULL, true);

create temp table _arch on commit drop as
select s.*, upper(btrim(regexp_replace(translate(s.name, 'ÁÉÍÓÚÜÑÀÈÌÒÙÂÊÎÔÛáéíóúüñàèìòùâêîôû', 'AEIOUUNAEIOUAEIOUaeiouunaeiouaeiou'), '\s+', ' ', 'g'))) as k from _stage s;
create index on _arch (k);

-- ---------------------------------------------------------------------------
-- 3) El catalogo actual, con la misma clave
-- ---------------------------------------------------------------------------
create temp table _actual on commit drop as
select mi.id, mi.name, mi.sku, upper(btrim(regexp_replace(translate(mi.name, 'ÁÉÍÓÚÜÑÀÈÌÒÙÂÊÎÔÛáéíóúüñàèìòùâêîôû', 'AEIOUUNAEIOUAEIOUaeiouunaeiouaeiou'), '\s+', ' ', 'g'))) as k
from public.menu_items mi
where mi.business_id = '528df61f-7136-4591-9e87-ee19f5882037'::uuid;
create index on _actual (k);

-- ---------------------------------------------------------------------------
-- 4) Regla A — emparejamiento 1:1 sin ambiguedad
-- ---------------------------------------------------------------------------
create temp table _match on commit drop as
select a.sku, x.id as item_id
from _arch a
join _actual x on x.k = a.k
where (select count(*) from _arch   a2 where a2.k = a.k) = 1
  and (select count(*) from _actual x2 where x2.k = a.k) = 1;

-- ---------------------------------------------------------------------------
-- 5) ACTUALIZA los emparejados y les graba el sku
-- ---------------------------------------------------------------------------
update public.menu_items mi
set sku         = s.sku,
    name        = s.name,
    price       = s.price,
    cost        = s.cost,
    category_id = c.id,
    tax_mode    = 'exclusive',
    is_active   = s.active,
    updated_at  = now()
from _match m
join _stage s on s.sku = m.sku
left join lateral (
  select c2.id from public.categories c2
  where c2.business_id = '528df61f-7136-4591-9e87-ee19f5882037'::uuid and c2.name = s.cat
  order by c2.created_at asc limit 1
) c on true
where mi.id = m.item_id;

-- ---------------------------------------------------------------------------
-- 6) Regla B — INSERTA solo los nombres que NO existen. Este `not exists`
--    es el candado anti-duplicados.
-- ---------------------------------------------------------------------------
insert into public.menu_items
  (business_id, category_id, name, price, cost, tax_mode, sku, is_active)
select '528df61f-7136-4591-9e87-ee19f5882037'::uuid, c.id, a.name, a.price, a.cost, 'exclusive', a.sku, a.active
from _arch a
left join lateral (
  select c2.id from public.categories c2
  where c2.business_id = '528df61f-7136-4591-9e87-ee19f5882037'::uuid and c2.name = a.cat
  order by c2.created_at asc limit 1
) c on true
where not exists (select 1 from _actual x where x.k = a.k);

-- ---------------------------------------------------------------------------
-- 7) Menu: reusa el activo que tenga el negocio; si no hay, crea uno.
--    Sin fila en menu_item_links el producto NO aparece en la caja.
-- ---------------------------------------------------------------------------
insert into public.menus (id, business_id, name, is_active)
select gen_random_uuid(), '528df61f-7136-4591-9e87-ee19f5882037'::uuid, 'MENU PRINCIPAL', true
where not exists (
  select 1 from public.menus m
  where m.business_id = '528df61f-7136-4591-9e87-ee19f5882037'::uuid and coalesce(m.is_active, true)
);

insert into public.menu_item_links (menu_id, item_id, position)
select m.id, mi.id,
       row_number() over (order by c.position nulls last, mi.name)
from public.menu_items mi
join _stage s on s.sku = mi.sku
left join public.categories c on c.id = mi.category_id
join lateral (
  select m2.id from public.menus m2
  where m2.business_id = mi.business_id and coalesce(m2.is_active, true)
  order by m2.created_at asc limit 1
) m on true
where mi.business_id = '528df61f-7136-4591-9e87-ee19f5882037'::uuid
  and not exists (
    select 1 from public.menu_item_links l
    where l.item_id = mi.id and l.menu_id = m.id
  );

-- ---------------------------------------------------------------------------
-- 8) Control.
--    en_archivo = 42. con_impuesto / sin_categoria / fuera_del_menu /
--    no_exclusive deben dar 0. desactivados = 1 (el Plato del dia - Nino).
-- ---------------------------------------------------------------------------
select
  (select count(*) from _arch)  as en_archivo,
  (select count(*) from _match) as actualizados,
  (select count(*) from _arch a
    where not exists (select 1 from _actual x where x.k = a.k)) as insertados,
  (select count(*) from _arch a
    where not exists (select 1 from _match m where m.sku = a.sku)
      and exists (select 1 from _actual x where x.k = a.k)) as ambiguos_sin_tocar,
  (select count(*) from public.menu_items
    where business_id = '528df61f-7136-4591-9e87-ee19f5882037'::uuid) as total_catalogo,
  (select count(*) from public.categories
    where business_id = '528df61f-7136-4591-9e87-ee19f5882037'::uuid) as categorias,
  (select count(*) from public.menu_items mi join _stage s on s.sku = mi.sku
    where mi.business_id = '528df61f-7136-4591-9e87-ee19f5882037'::uuid and mi.tax_mode <> 'exclusive') as no_exclusive,
  (select count(*) from public.menu_items mi join _stage s on s.sku = mi.sku
    where mi.business_id = '528df61f-7136-4591-9e87-ee19f5882037'::uuid
      and exists (select 1 from public.menu_item_taxes x where x.item_id = mi.id)
   ) as con_impuesto,
  (select count(*) from public.menu_items mi join _stage s on s.sku = mi.sku
    where mi.business_id = '528df61f-7136-4591-9e87-ee19f5882037'::uuid and mi.category_id is null) as sin_categoria,
  (select count(*) from public.menu_items mi join _stage s on s.sku = mi.sku
    where mi.business_id = '528df61f-7136-4591-9e87-ee19f5882037'::uuid
      and not exists (select 1 from public.menu_item_links l where l.item_id = mi.id)
   ) as fuera_del_menu,
  (select count(*) from public.menu_items mi join _stage s on s.sku = mi.sku
    where mi.business_id = '528df61f-7136-4591-9e87-ee19f5882037'::uuid and not mi.is_active) as desactivados;

-- ---------------------------------------------------------------------------
-- 9) El catalogo que queda, por categoria. Para leerlo de un vistazo.
-- ---------------------------------------------------------------------------
select coalesce(c.name, '(sin categoria)') as categoria,
       count(*) as productos,
       min(mi.price) as precio_min,
       max(mi.price) as precio_max,
       count(*) filter (where not mi.is_active) as inactivos
from public.menu_items mi
left join public.categories c on c.id = mi.category_id
where mi.business_id = '528df61f-7136-4591-9e87-ee19f5882037'::uuid
group by 1
order by 1;

commit;
