-- =============================================================================
-- ECO BAR & LOUNGE — los dos últimos pendientes.
-- Negocio: fc3065c8-cb40-45ad-bec1-aecb388001c1
--
--   1. Enlazar los 284 productos al MENÚ PRINCIPAL.
--      El POS filtra por menú: consulta v_menu_items_list con .eq('menu_id'),
--      y ese menu_id sale de menu_item_links. Un producto sin vínculo tiene
--      menu_id NULL y NO APARECE cuando hay un menú seleccionado.
--
--   2. LEY 10% → apply_on_takeout = false. El 10% de ley deja de cobrarse en
--      pedidos para llevar. Lo respetan las dos capas: el servidor en
--      fn_resolve_order_item_tax_profile y la app en tax_engine.dart.
--
-- OJO CON EL ITBIS: se queda en apply_on_takeout = true a propósito. El ITBIS
-- se cobra igual en para llevar; apagárselo dejaría esas facturas sin ITBIS.
--
-- Es IDEMPOTENTE: si ya corriste la parte del menú en ECOBAR_6, esto no
-- duplica nada, solo completa lo que falte.
--
-- Pega TODO de una vez en el SQL Editor de Supabase.
-- =============================================================================


-- ---------------------------------------------------------------------------
-- 0. CORTAFUEGOS. Los ítems ya cargados en una cuenta abierta guardaron su
--    tasa al momento de agregarse: cambiar la config debajo de ellos deja
--    la cuenta a medio camino entre las dos reglas.
-- ---------------------------------------------------------------------------
do $$
declare
  v_biz constant uuid := 'fc3065c8-cb40-45ad-bec1-aecb388001c1';
  v_open int;
begin
  select count(distinct o.id) into v_open
    from public.orders o
    join public.order_items oi on oi.order_id = o.id
    join public.menu_items mi on mi.id = oi.product_id
   where mi.business_id = v_biz and o.status = 'open';

  if v_open > 0 then
    raise exception 'Hay % cuenta(s) abierta(s). Espera a cerrarlas.', v_open;
  end if;
end $$;


-- ---------------------------------------------------------------------------
-- 1. TODA LA CARTA AL MENÚ PRINCIPAL.
--    Sin menús: se crea "Menú Principal". Con uno: se usa ese. Con varios:
--    el script para, porque "principal" ya no sería obvio.
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
    raise exception 'Este negocio tiene % menús activos (%). Dime en cuál va la carta y lo fijo.', v_n, v_lista;
  end if;

  if v_n = 0 then
    insert into public.menus (id, business_id, name, is_active)
    values (gen_random_uuid(), v_biz, 'Menú Principal', true);
  end if;

  insert into _menu
  select id from public.menus where business_id = v_biz and is_active;
end $$;

-- Vínculos a cualquier OTRO menú se van: la vista se queda con el primer
-- vínculo por posición, así que un producto en dos menús es una lotería.
delete from public.menu_item_links l
 using public.menu_items mi
 where mi.id = l.item_id
   and mi.business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1'
   and l.menu_id not in (select menu_id from _menu);

-- Los 284, en el orden del catálogo: categoría × 1000 + posición del producto.
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


-- Y CORREGIR LA POSICIÓN de los vínculos que ya existían. El insert de
-- arriba los respeta (on conflict do nothing), así que si alguien los creó
-- antes —desde la app o en otra corrida— se quedaron en position 0 y el POS
-- muestra los 284 en una sola lista alfabética, sin respetar la carta.
-- Esto los reordena siempre.
update public.menu_item_links l
   set position = coalesce(c.position, 0) * 1000 + coalesce(mi.position, 0)
  from public.menu_items mi
  left join public.categories c on c.id = mi.category_id
 where mi.id = l.item_id
   and mi.business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1'
   and l.menu_id in (select menu_id from _menu)
   and l.position is distinct from
       (coalesce(c.position, 0) * 1000 + coalesce(mi.position, 0));


-- ---------------------------------------------------------------------------
-- 2. LA LEY 10% DEJA DE COBRARSE EN PARA LLEVAR.
-- ---------------------------------------------------------------------------
update public.taxes
   set apply_on_takeout = false
 where business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1'
   and name ilike '%ley%';

-- Y el ITBIS se queda cobrándose en para llevar, por si alguien lo apagó.
update public.taxes
   set apply_on_takeout = true
 where business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1'
   and name ilike '%itbis%'
   and apply_on_takeout is not true;

-- Toca los productos para que el POS invalide su caché de catálogo.
update public.menu_items
   set updated_at = now()
 where business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1' and is_active;


-- ---------------------------------------------------------------------------
-- 3. RESULTADO.
-- ---------------------------------------------------------------------------
-- 3a. El menú y su carga. Tiene que decir 284.
select mn.name as menu, mn.is_active, count(l.item_id) as productos
  from public.menus mn
  left join public.menu_item_links l on l.menu_id = mn.id
 where mn.business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1'
 group by mn.name, mn.is_active
 order by mn.name;

-- 3b. Nadie puede quedar fuera del menú.
select count(*)                                                as productos_activos,
       count(*) filter (where not exists (
         select 1 from public.menu_item_links l
          where l.item_id = menu_items.id))                     as SIN_MENU
  from public.menu_items
 where business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1' and is_active;

-- 3bb. Vínculos con posición 0: tienen que ser 0. Si sale un número, el
--      menú se muestra alfabético en vez de en el orden de la carta.
select count(*) as vinculos_sin_posicion
  from public.menu_item_links l
  join public.menu_items mi on mi.id = l.item_id
 where mi.business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1'
   and mi.is_active
   and l.position = 0;


-- 3c. Las banderas como deben quedar: ITBIS takeout=true, LEY takeout=false.
select name, rate, is_active, is_service_fee, apply_on_takeout
  from public.taxes
 where business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1'
 order by rate desc;

-- 3d. Qué va a cobrar la caja ahora, en mesa y para llevar.
select mi.name                              as producto,
       mi.price                             as carta,
       round(mi.price * 1.28, 2)            as en_mesa_28pct,
       round(mi.price * 1.18, 2)            as para_llevar_18pct,
       round(mi.price * 0.10, 2)            as ley_que_se_ahorra
  from public.menu_items mi
 where mi.business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1'
   and mi.is_active
   and mi.name in ('Presidente Regular', 'Eco Spritz', 'Ribeye')
 order by mi.price;

-- 3e. Los primeros productos del menú, para ver que el orden quedó bien.
select l.position, c.name as categoria, mi.name as producto
  from public.menu_item_links l
  join public.menu_items mi on mi.id = l.item_id
  left join public.categories c on c.id = mi.category_id
  join _menu m on m.menu_id = l.menu_id
 order by l.position, mi.name
 limit 12;


-- ---------------------------------------------------------------------------
-- 4. DESPUÉS DE CORRERLO: cierra y abre la app en la tablet. El POS decide si
--    recarga el catálogo comparando count y max(updated_at), y el paso 2 ya
--    movió el updated_at de los 284.
-- ---------------------------------------------------------------------------
