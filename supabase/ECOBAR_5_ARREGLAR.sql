-- =============================================================================
-- ECO BAR & LOUNGE — arreglar lo que SÍ está roto del menú ya cargado.
-- Negocio: fc3065c8-cb40-45ad-bec1-aecb388001c1
--
-- EL MENÚ ESTÁ BIEN. Lo que está roto es lo de alrededor, y es grave:
--
--   · IMPUESTOS: de 280 productos, solo 2 tienen ITBIS y 3 tienen LEY.
--     `menu_item_taxes` es la ÚNICA fuente del impuesto (PRD 2.5 quitó el
--     fallback a default_tax_rate). Sin vínculo, el producto factura con
--     ITBIS 0 — y eso es lo que se declara en el 607.
--
--   · ÁREAS DE IMPRESIÓN: solo 3 productos tienen área. Los otros 277 hacen
--     que "Enviar a cocina" los rechace con error.
--
--   · Faltan los 4 acompañamientos de los arroces ($250 c/u).
--
-- DECIDIDO CON EL DUEÑO (3-sep-2026): toda la carta lleva ITBIS 18% + LEY 10%,
-- y los adicionales van como categoría propia.
--
-- NO borra ni renombra nada del menú existente. Solo agrega vínculos que
-- faltan y rellena áreas vacías.
--
-- Pega TODO de una vez en el SQL Editor de Supabase (corre en una transacción).
-- =============================================================================


-- ---------------------------------------------------------------------------
-- 0. CORTAFUEGOS.
--
--    is_service_fee = true en la LEY es veneno: el servidor la mete dentro de
--    oi.tax Y el cliente la vuelve a sacar aparte, o sea factura DOBLE. Si
--    alguien la prendió, este script se detiene antes de tocar nada.
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
    raise exception 'El impuesto "%" tiene is_service_fee = true. Apágalo antes de seguir: con eso prendido la factura cobra el cargo dos veces.', v_bad;
  end if;

  if not exists (select 1 from public.taxes
                  where business_id = v_biz and is_active and name ilike '%itbis%') then
    raise exception 'No hay un impuesto ITBIS activo en este negocio.';
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
    raise exception 'Hay % cuenta(s) abierta(s). Cámbialo con la caja cerrada: los ítems ya cargados guardan su tasa vieja.', v_open;
  end if;
end $$;


-- ---------------------------------------------------------------------------
-- 1. RESPALDO de lo que se va a tocar.
-- ---------------------------------------------------------------------------
drop table if exists public.zzz_ecobar_fix_menu_items;
create table public.zzz_ecobar_fix_menu_items as
  select * from public.menu_items
   where business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1';

drop table if exists public.zzz_ecobar_fix_menu_item_taxes;
create table public.zzz_ecobar_fix_menu_item_taxes as
  select mit.* from public.menu_item_taxes mit
   join public.zzz_ecobar_fix_menu_items b on b.id = mit.item_id;

drop table if exists public.zzz_ecobar_fix_menu_item_print_areas;
create table public.zzz_ecobar_fix_menu_item_print_areas as
  select p.* from public.menu_item_print_areas p
   join public.zzz_ecobar_fix_menu_items b on b.id = p.menu_item_id;


-- ---------------------------------------------------------------------------
-- 2. MAPA categoría → área. Por nombre normalizado, para que no importen
--    tildes ni mayúsculas. Lo que no esté aquí NO se toca y sale reportado
--    al final: prefiero dejar un hueco visible que adivinar mal.
-- ---------------------------------------------------------------------------
create or replace function pg_temp.norm(t text) returns text
  language sql immutable as $fn$
  select regexp_replace(
           translate(lower(coalesce(t,'')), 'áéíóúüñç', 'aeiouunc'),
           '[^a-z0-9]', '', 'g')
$fn$;

drop table if exists _mapa;
create temp table _mapa(cat_norm text primary key, kind text);
insert into _mapa(cat_norm, kind) values
  ('platosfuertes','cocina'),
  ('entradas','cocina'),
  ('mofongo','cocina'),
  ('antojos','cocina'),
  ('rincocitosdelosecopeques','cocina'),
  ('deliciasdelmar','cocina'),
  ('ensaladas','cocina'),
  ('arrocesalestiloecobar','cocina'),
  ('pastas','cocina'),
  ('hamburguesas','cocina'),
  ('guarniciones','cocina'),
  ('postres','cocina'),
  ('adicionales','cocina'),
  ('cocteles','bar'),
  ('aguassaborizadas','bar'),
  ('jugosmixers','bar'),
  ('rones','bar'),
  ('ronestragos','bar'),
  ('whiskey','bar'),
  ('whiskeytragos','bar'),
  ('vodka','bar'),
  ('ginebra','bar'),
  ('tequila','bar'),
  ('digestivos','bar'),
  ('gintonic','bar'),
  ('copasdevino','bar'),
  ('vinostinto','bar'),
  ('vinosblancos','bar'),
  ('vinosrosado','bar'),
  ('cavaprosecco','bar'),
  ('champagne','bar'),
  ('cervezas','bar'),
  ('cigarros','bar'),
  ('cigarrillos','bar'),
  ('cafe','bar');

-- Resolver las dos áreas reales del negocio (existen: 'cocina' y 'bar').
drop table if exists _area;
create temp table _area(kind text primary key, area_id uuid, code text);

insert into _area(kind, area_id, code)
select 'cocina', id, code from public.print_areas
 where business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1' and is_active
   and code in ('cocina','kitchen_hot','kitchen')
 order by case code when 'cocina' then 0 when 'kitchen_hot' then 1 else 2 end
 limit 1;

insert into _area(kind, area_id, code)
select 'bar', id, code from public.print_areas
 where business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1' and is_active
   and code = 'bar'
 limit 1;

do $$
begin
  if (select count(*) from _area) < 2 then
    raise exception 'No se resolvieron las dos áreas (cocina y bar). Revisa Ajustes → Impresión.';
  end if;
end $$;


-- ---------------------------------------------------------------------------
-- 3. CREAR LA CATEGORÍA "ADICIONALES" Y SUS 4 PRODUCTOS.
--    Posición 95: justo después de Arroces (90), que es donde se piden.
-- ---------------------------------------------------------------------------
insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), 'fc3065c8-cb40-45ad-bec1-aecb388001c1', 'Adicionales', 95, true
 where not exists (
   select 1 from public.categories
    where business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1'
      and pg_temp.norm(name) = 'adicionales');

insert into public.menu_items (
  business_id, category_id, name, price, tax_mode, is_active, description,
  is_beverage, sold_by, position, print_area_code, updated_at)
select 'fc3065c8-cb40-45ad-bec1-aecb388001c1',
       c.id, v.n, 250, 'exclusive', true,
       'Acompañamiento adicional para los arroces.',
       false, 'unit', v.p, a.code, now()
  from (values ('Adicional Chicken',1),
               ('Adicional Beef',2),
               ('Adicional Shrimps',3),
               ('Adicional Chicharrón',4)) as v(n,p)
  join public.categories c
    on c.business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1'
   and pg_temp.norm(c.name) = 'adicionales' and c.is_active
  join _area a on a.kind = 'cocina'
 where not exists (
   select 1 from public.menu_items mi
    where mi.business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1'
      and pg_temp.norm(mi.name) = pg_temp.norm(v.n));


-- ---------------------------------------------------------------------------
-- 4. IMPUESTOS: ITBIS 18% + LEY 10% a TODA la carta activa.
--    on conflict do nothing: los 5 que ya tenían algo se quedan como están.
-- ---------------------------------------------------------------------------
insert into public.menu_item_taxes (item_id, tax_id)
select mi.id, t.id
  from public.menu_items mi
  cross join public.taxes t
 where mi.business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1'
   and mi.is_active
   and t.business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1'
   and t.is_active
   and (t.name ilike '%itbis%' or t.name ilike '%ley%')
on conflict do nothing;


-- ---------------------------------------------------------------------------
-- 5. TAX MODE: el PDF dice "los precios no incluyen ITBIS", así que todo va
--    exclusive. Si alguno quedó inclusive, el precio se estaría comiendo el
--    impuesto y el neto saldría más bajo de lo que el dueño cree cobrar.
-- ---------------------------------------------------------------------------
update public.menu_items
   set tax_mode = 'exclusive', updated_at = now()
 where business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1'
   and is_active
   and tax_mode <> 'exclusive';


-- ---------------------------------------------------------------------------
-- 6. ÁREAS DE IMPRESIÓN.
--
--    6a. El N:M, que es el que manda. Se agrega el área de la categoría; lo
--        que ya estuviera asignado a mano sobrevive.
-- ---------------------------------------------------------------------------
insert into public.menu_item_print_areas (menu_item_id, print_area_id)
select mi.id, a.area_id
  from public.menu_items mi
  join public.categories c on c.id = mi.category_id
  join _mapa m on m.cat_norm = pg_temp.norm(c.name)
  join _area a on a.kind = m.kind
 where mi.business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1'
   and mi.is_active
on conflict do nothing;

--    6b. El legacy print_area_code. Solo se rellena si está vacío o si apunta
--        a un código que este negocio NO tiene (típico: 'kitchen_hot' heredado
--        del default viejo, que aquí no existe).
update public.menu_items mi
   set print_area_code = a.code, updated_at = now()
  from public.categories c, _mapa m, _area a
 where mi.category_id = c.id
   and m.cat_norm = pg_temp.norm(c.name)
   and a.kind = m.kind
   and mi.business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1'
   and mi.is_active
   and (mi.print_area_code is null
        or mi.print_area_code = ''
        or not exists (
          select 1 from public.print_areas pa
           where pa.business_id = mi.business_id
             and pa.code = mi.print_area_code
             and pa.is_active));


-- ---------------------------------------------------------------------------
-- 7. RESULTADO. Las cuatro columnas de la derecha tienen que dar 0.
-- ---------------------------------------------------------------------------
select count(*)                                                   as productos_activos,
       count(*) filter (where not exists (
         select 1 from public.menu_item_taxes t
          join public.taxes tx on tx.id = t.tax_id and tx.name ilike '%itbis%'
         where t.item_id = menu_items.id))                         as SIN_ITBIS,
       count(*) filter (where not exists (
         select 1 from public.menu_item_taxes t
          join public.taxes tx on tx.id = t.tax_id and tx.name ilike '%ley%'
         where t.item_id = menu_items.id))                         as SIN_LEY,
       count(*) filter (where not exists (
         select 1 from public.menu_item_print_areas p
          where p.menu_item_id = menu_items.id))                   as SIN_AREA,
       count(*) filter (where tax_mode <> 'exclusive')             as TAX_MODE_MALO
  from public.menu_items
 where business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1' and is_active;


-- 7b. Categorías que el mapa no reconoció: sus productos quedaron sin área.
--     Si sale alguna, dime el nombre y la agrego al mapa.
select c.name as categoria_sin_mapear, count(mi.id) as productos
  from public.categories c
  left join public.menu_items mi on mi.category_id = c.id and mi.is_active
 where c.business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1' and c.is_active
   and not exists (select 1 from _mapa m where m.cat_norm = pg_temp.norm(c.name))
 group by c.name;


-- 7e. PRODUCTOS EN DOS ÁREAS. Si sale alguno, su comanda se imprime DOS
--     VECES (una en cocina y otra en bar). Pasa cuando alguien le asignó a
--     mano un área que no es la de su categoría. No lo toco solo: dime cuál
--     área es la buena y le quito la otra.
select mi.name as producto,
       c.name  as categoria,
       string_agg(pa.name, ' + ' order by pa.name) as areas
  from public.menu_items mi
  join public.menu_item_print_areas mipa on mipa.menu_item_id = mi.id
  join public.print_areas pa on pa.id = mipa.print_area_id
  left join public.categories c on c.id = mi.category_id
 where mi.business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1' and mi.is_active
 group by mi.name, c.name
having count(*) > 1;


-- 7c. Ruteo final de comandas.
select pa.name as area, pa.code, count(*) as productos
  from public.menu_items mi
  join public.menu_item_print_areas mipa on mipa.menu_item_id = mi.id
  join public.print_areas pa on pa.id = mipa.print_area_id
 where mi.business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1' and mi.is_active
 group by pa.name, pa.code
 order by count(*) desc;


-- 7d. Cómo queda un precio de ejemplo con los dos impuestos encima.
select mi.name, mi.price as carta,
       round(mi.price * 0.18, 2) as itbis,
       round(mi.price * 0.10, 2) as ley,
       round(mi.price * 1.28, 2) as total_cliente
  from public.menu_items mi
 where mi.business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1' and mi.is_active
   and mi.name in ('Presidente Regular', 'Ribeye', 'Eco Spritz')
 order by mi.price;


-- ---------------------------------------------------------------------------
-- 8. OJO PARA DESPUÉS (no lo arregla este script):
--
--    · Con ITBIS 18% + LEY 10% la tasa sumada da 28%. Si este negocio activa
--      e-CF, hay un bug conocido: el generador manda al indicador de
--      facturación equivocado cuando la tasa sumada no es 18 y termina
--      declarando EXENTO lo que lleva Ley. Antes de prender e-CF aquí, hay
--      que arreglar eso.
--
--    · La LEY normalmente NO se cobra en para llevar. Revisa
--      taxes.apply_on_takeout de la LEY (hoy default = true) y decide.
--
--    · Cuando verifiques que todo quedó bien, bota los respaldos:
--      drop table if exists public.zzz_ecobar_fix_menu_items;
--      drop table if exists public.zzz_ecobar_fix_menu_item_taxes;
--      drop table if exists public.zzz_ecobar_fix_menu_item_print_areas;
-- ---------------------------------------------------------------------------
