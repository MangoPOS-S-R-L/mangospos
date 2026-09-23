-- ============================================================================
-- AZOTEA 046 BAR & GRILL — CARGA DEL MENÚ DE CÓCTELES
-- Business e7a63240-6492-4ed5-8057-319ab91a748c
--
-- Fuente: foto de la libreta con los precios escritos a mano (2026-09-22).
-- ============================================================================
--
-- QUÉ CARGA
--   21 productos. Todo es bebida: va al área de comanda BAR (code `bar`).
--   * los 18 cócteles van a la categoría COCTELES, que el dueño ya creó y
--     estaba vacía, en el orden de la libreta: clásicos, tropicales y de la
--     casa;
--   * los 3 tragos van a TRAGOS, una categoría nueva en MAYÚSCULAS y en la
--     posición 0, como las demás del negocio.
--   Precios con los impuestos INCLUIDOS (tax_mode = 'inclusive'): lo que dice
--   la libreta es lo que paga el cliente. Una Cuba Libre de $375 con ITBIS +
--   LEY queda en base 292.97 + ITBIS 52.73 + LEY 29.30.
--
-- DIAGNÓSTICO (2026-09-22)
--   ITBIS 18% y LEY 10% activos, ninguno con is_service_fee;
--   service_fee_enabled = false; los 2 productos que ya hay (AGUAS Y SODAS)
--   llevan ITBIS + LEY. Área BAR (`bar`) con 1 impresora. Un solo menú, MENU
--   PRINCIPAL. Ninguno de los 21 existe todavía.
--
-- QUÉ NO CARGA
--   * Bahama Mama y Blue Lagoon: en la libreta no tienen precio.
--   * Mango: está tachado.
--
-- CÓMO CORRERLO
--   Corre antes 00_diagnostico.sql. Después pega este entero en el SQL Editor
--   de Supabase y dale Run. La tabla que sale al final es el reporte: todas
--   las filas deben decir ✓.
--
-- TODO O NADA
--   Va en UNA transacción. Primero comprueba todo (negocio, ITBIS, Ley, menú,
--   área, nombres repetidos) y después, antes del commit, verifica los 21 uno
--   por uno. Si algo no cuadra lanza excepción y REVIERTE ENTERO.
--
-- SE PUEDE RE-CORRER
--   Empareja por nombre, sin mayúsculas ni tildes ("MOJITO DE LIMON" es el
--   mismo que "Mojito de Limón"). El que ya existe se ACTUALIZA (precio,
--   categoría, impuestos, área) y conserva su nombre; el que falta se INSERTA.
--   Para corregir un precio: cámbialo en la lista y vuelve a correrlo.
--
-- IMPUESTOS
--   menu_item_taxes es la ÚNICA fuente del impuesto por producto: sin fila ahí
--   la factura sale con ITBIS 0.00. Siempre se vincula el ITBIS 18%. La Ley
--   10% depende de la decisión de abajo. Cualquier otro impuesto que ya
--   tuviera uno de estos productos se le quita.
--   Con 'inclusive' la Ley NO sube el precio: se saca de adentro. La Cuba
--   Libre de $375 con ITBIS + Ley queda en 292.97 + 52.73 + 29.30.
--
-- ÁREA DE COMANDA (cómo la escoge)
--   * cocina apagada en Ajustes (kitchen_enabled = false): ninguna. La venta
--     marca los ítems como listos sin comanda;
--   * si hay un área activa "bar" o "barra" (por code o por nombre), esa;
--   * si no, y hay UNA sola área activa, esa;
--   * si no hay ninguna, reactiva "bar"/"barra" si existe apagada, o CREA
--     "Bar" (code `bar`), sin impresora: se vincula en la app;
--   * si hay varias y ninguna es del bar, ABORTA y las lista.
--   Las áreas de sistema (cashier, fiscal, cash_close) no cuentan.
--   Escribe LOS DOS mecanismos: menu_item_print_areas (N:M) y el legacy
--   menu_items.print_area_code, que fn_add_item_from_menu copia al
--   order_item. Sin el legacy, un bache de red manda la comanda a otro lado.
--
-- MENÚ
--   La caja filtra los productos por menú (menu_item_links). Si el negocio no
--   tiene menú se crea "Menú Principal"; si tiene uno se reusa; si tiene más
--   de uno, ABORTA.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- ▶ DECISIÓN: ¿estos tragos llevan la Ley 10%?
--     'auto' → si el negocio no tiene Ley, no. Si la tiene, copia lo que hace
--              el catálogo actual (≥ 90% la lleva → sí; ≤ 10% → no). Si no
--              hay catálogo o está mezclado, ABORTA y pregunta.
--     'si'   → ITBIS + Ley.
--     'no'   → solo ITBIS.
--   Va en 'si': el diagnóstico mostró que el negocio tiene la LEY y que el
--   resto de la carta la lleva. Se fija en vez de dejar 'auto' porque 'auto'
--   dependería de solo 2 productos.
-- ---------------------------------------------------------------------------
create temp table _cf_cfg on commit drop as
select 'si'::text as ley;

-- Nombre normalizado: sin mayúsculas, sin tildes, sin espacios repetidos.
create function pg_temp.norm(t text) returns text
language sql immutable as $f$
  select translate(lower(regexp_replace(btrim(t), '\s+', ' ', 'g')),
                   'áéíóúüñÁÉÍÓÚÜÑ', 'aeiouunaeiouun')
$f$;

-- ---------------------------------------------------------------------------
-- 0) El menú, en tablas temporales que mueren con la transacción.
-- ---------------------------------------------------------------------------

create temp table _cf_categorias (
  name     text not null,
  posicion int  not null
) on commit drop;

-- COCTELES ya existe: se reusa con su nombre y posición. La posición de aquí
-- solo se usa si hay que crearla.
insert into _cf_categorias (name, posicion) values
  ('COCTELES', 0),
  ('TRAGOS',   0);

create temp table _cf_productos (
  categoria text not null,
  name      text not null,
  price     numeric(12,2) not null,
  posicion  int not null
) on commit drop;

insert into _cf_productos (categoria, name, price, posicion) values
  -- Libreta: "Mojitos (coco, limón, fresa) = 330" (350 y 380 tachados).
  ('COCTELES', 'Mojito de Coco',          330.00,  1),
  ('COCTELES', 'Mojito de Limón',         330.00,  2),
  ('COCTELES', 'Mojito de Fresa',         330.00,  3),
  ('COCTELES', 'Piña Colada con Alcohol', 330.00,  4),
  -- Libreta: 400 tachado, 450.
  ('COCTELES', 'Margarita',               450.00,  5),
  ('COCTELES', 'Martini',                 350.00,  6),
  ('COCTELES', 'Long Island Iced Tea',    450.00,  7),
  ('COCTELES', 'Cuba Libre',              375.00,  8),
  -- Libreta: "Gin tonic - Sangría = 350 ambos".
  ('COCTELES', 'Gin Tonic',               350.00,  9),
  ('COCTELES', 'Sangría',                 350.00, 10),

  ('COCTELES', 'Sex on the Beach',        450.00, 11),
  -- Libreta: "(400 - 360)". POR CONFIRMAR: se carga a 400.
  ('COCTELES', 'Tequila Sunrise',         400.00, 12),
  ('COCTELES', 'Coco Paradise',           400.00, 13),

  ('COCTELES', 'Velvet Sunset',           375.00, 14),
  ('COCTELES', 'Tropical Azotea',         375.00, 15),
  ('COCTELES', 'Brisa Tropical',          375.00, 16),
  ('COCTELES', 'Deseo Prohibido',         375.00, 17),
  ('COCTELES', 'Passion Mamey',           375.00, 18),

  ('TRAGOS',   'Trago de Chivas',         400.00, 19),
  ('TRAGOS',   'Trago de Tequila',        400.00, 20),
  ('TRAGOS',   'Trago de la Casa',        375.00, 21);

do $$
declare
  v_business  uuid := 'e7a63240-6492-4ed5-8057-319ab91a748c';
  v_esperados int;
  v_cfg_ley   text;
  v_itbis_id  uuid;
  v_ley_id    uuid;
  v_con_ley   boolean;
  v_kitchen   boolean;
  v_area_id   uuid;
  v_area_code text;
  v_menu_id   uuid;
  v_menus     int;
  v_base      int;
  v_con       int;
  v_n         int;
  v_list      text;
begin
  select count(*) into v_esperados from _cf_productos;
  select lower(btrim(ley)) into v_cfg_ley from _cf_cfg;

  if v_cfg_ley not in ('auto', 'si', 'no') then
    raise exception 'La decisión de la Ley debe ser auto, si o no (dice "%").', v_cfg_ley;
  end if;

  -- =========================================================================
  -- 1) GUARDAS: se comprueba todo ANTES de escribir una sola fila.
  -- =========================================================================

  -- 1a) El negocio existe.
  if not exists (select 1 from public.businesses where id = v_business) then
    raise exception 'El negocio % no existe.', v_business;
  end if;

  -- 1b) Un ITBIS 18% activo, y uno solo.
  select count(*) into v_n
  from public.taxes t
  where t.business_id = v_business
    and t.name ilike '%itbis%'
    and t.rate = 18
    and coalesce(t.is_active, true);

  if v_n = 0 then
    select string_agg(format('%s %s%% (%s)', t.name, t.rate,
             case when coalesce(t.is_active, true) then 'activo' else 'INACTIVO' end),
           ', ')
      into v_list
    from public.taxes t
    where t.business_id = v_business;

    raise exception
      'No hay un ITBIS 18%% activo en este negocio (impuestos que tiene: %). '
      'Créalo en Ajustes → Impuestos y vuelve a correr.',
      coalesce(v_list, 'ninguno');
  elsif v_n > 1 then
    raise exception
      'Hay % impuestos ITBIS 18%% activos. Deja uno solo antes de cargar.', v_n;
  end if;

  select t.id into v_itbis_id
  from public.taxes t
  where t.business_id = v_business
    and t.name ilike '%itbis%'
    and t.rate = 18
    and coalesce(t.is_active, true);

  -- 1c) is_service_fee apagado en el ITBIS: encendido, la factura lo cobra
  --     DOS veces (el servidor lo suma dentro y la app lo saca aparte).
  if exists (select 1 from public.taxes
             where id = v_itbis_id and coalesce(is_service_fee, false)) then
    raise exception
      'El ITBIS tiene is_service_fee = true: la factura lo cobraría DOS veces. '
      'Revísalo antes de cargar.';
  end if;

  -- 1d) La Ley 10%: un impuesto activo al 10% que no sea el ITBIS.
  select count(*), string_agg(t.name, ', ')
    into v_n, v_list
  from public.taxes t
  where t.business_id = v_business
    and t.rate = 10
    and t.name not ilike '%itbis%'
    and coalesce(t.is_active, true);

  if v_n > 1 then
    raise exception
      'Hay % impuestos activos del 10%% (%). Deja uno solo o dime cuál es la Ley.',
      v_n, v_list;
  end if;

  select t.id into v_ley_id
  from public.taxes t
  where t.business_id = v_business
    and t.rate = 10
    and t.name not ilike '%itbis%'
    and coalesce(t.is_active, true);

  if v_cfg_ley = 'no' then
    v_con_ley := false;
  elsif v_cfg_ley = 'si' then
    if v_ley_id is null then
      raise exception
        'Pediste la Ley 10%% pero el negocio no tiene un impuesto activo del 10%%. '
        'Créalo en Ajustes → Impuestos (con is_service_fee apagado).';
    end if;
    v_con_ley := true;
  elsif v_ley_id is null then
    v_con_ley := false;
  else
    -- auto con Ley configurada: copiar lo que hace el catálogo activo, sin
    -- contar los productos de este menú.
    select count(*),
           count(*) filter (where exists (
             select 1 from public.menu_item_taxes x
             where x.item_id = mi.id and x.tax_id = v_ley_id))
      into v_base, v_con
    from public.menu_items mi
    where mi.business_id = v_business
      and mi.is_active
      and pg_temp.norm(mi.name) not in (select pg_temp.norm(name) from _cf_productos)
      and exists (select 1 from public.menu_item_taxes x
                  where x.item_id = mi.id and x.tax_id = v_itbis_id);

    if v_base = 0 then
      raise exception
        'El negocio tiene la Ley "%" pero ningún otro producto con ITBIS para copiar. '
        'Dime si los tragos la llevan: cambia ''auto'' por ''si'' o ''no'' arriba.',
        v_list;
    elsif v_con * 100 >= v_base * 90 then
      v_con_ley := true;
    elsif v_con * 100 <= v_base * 10 then
      v_con_ley := false;
    else
      raise exception
        'La Ley "%" está en % de % productos: no está claro si va. '
        'Cambia ''auto'' por ''si'' o ''no'' arriba.',
        v_list, v_con, v_base;
    end if;
  end if;

  -- 1e) Con Ley vinculada, nada de cobrarla dos veces.
  if v_con_ley then
    if exists (select 1 from public.taxes
               where id = v_ley_id and coalesce(is_service_fee, false)) then
      raise exception
        'La Ley tiene is_service_fee = true: vinculada al producto se factura DOBLE. '
        'No la vinculo. Dime cómo seguir.';
    end if;
    if exists (select 1 from public.business_settings
               where business_id = v_business
                 and coalesce(service_fee_enabled, false)) then
      raise exception
        'service_fee_enabled está en true: la Ley saldría por producto Y por orden. '
        'Dime cómo seguir.';
    end if;
  end if;

  -- 1f) Ningún nombre del menú repetido en el catálogo: no sabría cuál
  --     actualizar.
  select string_agg(format('%s (%s veces)', p.name, x.n), ', ')
    into v_list
  from _cf_productos p
  cross join lateral (
    select count(*) as n from public.menu_items mi
    where mi.business_id = v_business
      and pg_temp.norm(mi.name) = pg_temp.norm(p.name)
  ) x
  where x.n > 1;

  if v_list is not null then
    raise exception
      'Productos repetidos en el catálogo actual, no sé cuál actualizar: %', v_list;
  end if;

  -- 1g) Menú: 0 se crea, 1 se reusa, más de 1 aborta.
  select count(*) into v_menus
  from public.menus
  where business_id = v_business and coalesce(is_active, true);

  if v_menus > 1 then
    select string_agg(name, ', ' order by created_at) into v_list
    from public.menus
    where business_id = v_business and coalesce(is_active, true);

    raise exception
      'El negocio tiene % menús activos (%). Dime a cuál van los productos.',
      v_menus, v_list;
  end if;

  -- 1h) Área de comanda (ver encabezado).
  select coalesce(bs.kitchen_enabled, true) into v_kitchen
  from public.business_settings bs
  where bs.business_id = v_business;
  v_kitchen := coalesce(v_kitchen, true);

  if v_kitchen then
    select a.id, a.code into v_area_id, v_area_code
    from public.print_areas a
    where a.business_id = v_business
      and a.is_active
      and (a.code in ('bar', 'barra') or pg_temp.norm(a.name) in ('bar', 'barra'))
    order by (a.code = 'bar') desc, (a.code = 'barra') desc, a.created_at
    limit 1;

    if v_area_id is null then
      select count(*), string_agg(format('%s (%s)', name, code), ', ')
        into v_n, v_list
      from public.print_areas
      where business_id = v_business
        and is_active
        and code not in ('cashier', 'fiscal', 'cash_close');

      if v_n = 1 then
        select id, code into v_area_id, v_area_code
        from public.print_areas
        where business_id = v_business
          and is_active
          and code not in ('cashier', 'fiscal', 'cash_close');
      elsif v_n = 0 then
        select a.id, a.code into v_area_id, v_area_code
        from public.print_areas a
        where a.business_id = v_business
          and (a.code in ('bar', 'barra') or pg_temp.norm(a.name) in ('bar', 'barra'))
        order by (a.code = 'bar') desc, a.created_at
        limit 1;

        if v_area_id is not null then
          update public.print_areas set is_active = true where id = v_area_id;
        else
          v_area_id   := gen_random_uuid();
          v_area_code := 'bar';
          insert into public.print_areas (id, business_id, name, code, is_active)
          values (v_area_id, v_business, 'Bar', v_area_code, true);
        end if;
      else
        raise exception
          'Hay % áreas de comanda activas (%) y ninguna es del bar. '
          'Dime a cuál van los tragos.', v_n, v_list;
      end if;
    end if;
  end if;

  -- =========================================================================
  -- 2) MENÚ
  -- =========================================================================

  select id into v_menu_id
  from public.menus
  where business_id = v_business and coalesce(is_active, true)
  order by created_at
  limit 1;

  if v_menu_id is null then
    v_menu_id := gen_random_uuid();
    insert into public.menus (id, business_id, name, is_active)
    values (v_menu_id, v_business, 'Menú Principal', true);
  end if;

  -- =========================================================================
  -- 3) CATEGORÍAS: crea las que falten; las que ya existen se respetan
  --    (nombre y posición), solo se reactivan.
  -- =========================================================================

  insert into public.categories (id, business_id, name, position, is_active)
  select gen_random_uuid(), v_business, c.name, c.posicion, true
  from _cf_categorias c
  where not exists (
    select 1 from public.categories x
    where x.business_id = v_business
      and pg_temp.norm(x.name) = pg_temp.norm(c.name)
  );

  update public.categories x
  set is_active = true
  from _cf_categorias c
  where x.business_id = v_business
    and pg_temp.norm(x.name) = pg_temp.norm(c.name)
    and not x.is_active;

  -- =========================================================================
  -- 4) PRODUCTOS: actualiza los que ya existen, inserta los que faltan.
  --    print_area_code se escribe aquí mismo.
  -- =========================================================================

  update public.menu_items mi
  set price           = p.price,
      category_id     = cat.id,
      tax_mode        = 'inclusive',
      is_active       = true,
      is_beverage     = true,
      position        = p.posicion,
      print_area_code = v_area_code,
      updated_at      = now()
  from _cf_productos p
  cross join lateral (
    select c.id from public.categories c
    where c.business_id = v_business
      and pg_temp.norm(c.name) = pg_temp.norm(p.categoria)
    order by c.is_active desc, c.created_at
    limit 1
  ) cat
  where mi.business_id = v_business
    and pg_temp.norm(mi.name) = pg_temp.norm(p.name);

  insert into public.menu_items (
    id, business_id, category_id, name, price,
    tax_mode, is_active, is_beverage, position, print_area_code
  )
  select gen_random_uuid(), v_business, cat.id, p.name, p.price,
         'inclusive', true, true, p.posicion, v_area_code
  from _cf_productos p
  cross join lateral (
    select c.id from public.categories c
    where c.business_id = v_business
      and pg_temp.norm(c.name) = pg_temp.norm(p.categoria)
    order by c.is_active desc, c.created_at
    limit 1
  ) cat
  where not exists (
    select 1 from public.menu_items mi
    where mi.business_id = v_business
      and pg_temp.norm(mi.name) = pg_temp.norm(p.name)
  );

  create temp table _cf_ids on commit drop as
  select mi.id, p.name
  from public.menu_items mi
  join _cf_productos p on pg_temp.norm(mi.name) = pg_temp.norm(p.name)
  where mi.business_id = v_business;

  create temp table _cf_taxes on commit drop as
  select v_itbis_id as tax_id
  union all
  select v_ley_id where v_con_ley;

  -- =========================================================================
  -- 5) IMPUESTOS: exactamente el juego decidido arriba.
  -- =========================================================================

  delete from public.menu_item_taxes mit
  using _cf_ids i
  where mit.item_id = i.id
    and mit.tax_id not in (select tax_id from _cf_taxes);

  insert into public.menu_item_taxes (item_id, tax_id)
  select i.id, t.tax_id
  from _cf_ids i
  cross join _cf_taxes t
  where not exists (
    select 1 from public.menu_item_taxes x
    where x.item_id = i.id and x.tax_id = t.tax_id
  );

  -- =========================================================================
  -- 6) ÁREA DE COMANDA (N:M). El legacy ya quedó escrito en el paso 4.
  --    Se borran asignaciones a otras áreas: si no, el trago saldría por DOS
  --    impresoras. Con cocina apagada no queda ninguna.
  -- =========================================================================

  delete from public.menu_item_print_areas x
  using _cf_ids i
  where x.menu_item_id = i.id
    and x.print_area_id is distinct from v_area_id;

  if v_area_id is not null then
    insert into public.menu_item_print_areas (menu_item_id, print_area_id)
    select i.id, v_area_id
    from _cf_ids i
    where not exists (
      select 1 from public.menu_item_print_areas x
      where x.menu_item_id = i.id and x.print_area_id = v_area_id
    );
  end if;

  -- =========================================================================
  -- 7) ENLACE AL MENÚ: sin esto el producto no aparece en la caja.
  -- =========================================================================

  insert into public.menu_item_links (menu_id, item_id, position)
  select v_menu_id, i.id, p.posicion
  from _cf_ids i
  join _cf_productos p on p.name = i.name
  where not exists (
    select 1 from public.menu_item_links l
    where l.menu_id = v_menu_id and l.item_id = i.id
  );

  -- =========================================================================
  -- 8) VERIFICACIÓN DENTRO DE LA TRANSACCIÓN: cualquier fallo revierte TODO.
  -- =========================================================================

  -- Los 21, cada uno exactamente una vez y activo.
  select count(*) into v_n
  from _cf_productos p
  where (select count(*) from public.menu_items mi
         where mi.business_id = v_business
           and pg_temp.norm(mi.name) = pg_temp.norm(p.name)
           and mi.is_active) <> 1;
  if v_n > 0 or (select count(*) from _cf_ids) <> v_esperados then
    raise exception '% productos del menú no quedaron (o quedaron repetidos). Revertido.', v_n;
  end if;

  -- Precio de la libreta, impuestos incluidos, con categoría y como bebida.
  select count(*) into v_n
  from _cf_ids i
  join public.menu_items mi on mi.id = i.id
  join _cf_productos p on p.name = i.name
  where mi.price <> p.price
     or mi.tax_mode <> 'inclusive'
     or mi.category_id is null
     or not mi.is_beverage;
  if v_n > 0 then
    raise exception '% productos con precio, modo de impuesto o categoría incorrectos. Revertido.', v_n;
  end if;

  -- Exactamente el juego de impuestos decidido.
  select count(*) into v_n
  from _cf_ids i
  where exists (select 1 from _cf_taxes t
                where not exists (select 1 from public.menu_item_taxes x
                                  where x.item_id = i.id and x.tax_id = t.tax_id))
     or exists (select 1 from public.menu_item_taxes x
                where x.item_id = i.id
                  and x.tax_id not in (select tax_id from _cf_taxes));
  if v_n > 0 then
    raise exception '% productos con un juego de impuestos distinto al decidido. Revertido.', v_n;
  end if;

  -- Área: una sola y el legacy de acuerdo con la N:M (o ninguna si la
  -- cocina está apagada).
  select count(*) into v_n
  from _cf_ids i
  join public.menu_items mi on mi.id = i.id
  where mi.print_area_code is distinct from v_area_code
     or (select count(*) from public.menu_item_print_areas x
         where x.menu_item_id = i.id) <> case when v_area_id is null then 0 else 1 end
     or (v_area_id is not null
         and not exists (select 1 from public.menu_item_print_areas x
                         where x.menu_item_id = i.id and x.print_area_id = v_area_id));
  if v_n > 0 then
    raise exception '% productos sin área de comanda o con legacy y N:M en desacuerdo. Revertido.', v_n;
  end if;

  -- Todos en el menú de la caja.
  select count(*) into v_n
  from _cf_ids i
  where not exists (select 1 from public.menu_item_links l
                    where l.menu_id = v_menu_id and l.item_id = i.id);
  if v_n > 0 then
    raise exception '% productos fuera del menú: no saldrían en la caja. Revertido.', v_n;
  end if;

  raise notice 'OK: % productos, Ley=%, área=%. Commit.',
    v_esperados, v_con_ley, coalesce(v_area_code, 'ninguna (cocina apagada)');
end $$;

commit;

-- ============================================================================
-- REPORTE: todas las filas deben decir ✓
-- ============================================================================

with
biz as (
  select 'e7a63240-6492-4ed5-8057-319ab91a748c'::uuid as id
),
menu(name, price) as (
  values
    ('Mojito de Coco', 330.00), ('Mojito de Limón', 330.00), ('Mojito de Fresa', 330.00),
    ('Piña Colada con Alcohol', 330.00), ('Margarita', 450.00), ('Martini', 350.00),
    ('Long Island Iced Tea', 450.00), ('Cuba Libre', 375.00), ('Gin Tonic', 350.00),
    ('Sangría', 350.00),
    ('Sex on the Beach', 450.00), ('Tequila Sunrise', 400.00), ('Coco Paradise', 400.00),
    ('Velvet Sunset', 375.00), ('Tropical Azotea', 375.00), ('Brisa Tropical', 375.00),
    ('Deseo Prohibido', 375.00), ('Passion Mamey', 375.00),
    ('Trago de Chivas', 400.00), ('Trago de Tequila', 400.00), ('Trago de la Casa', 375.00)
),
items as (
  select mi.*, m.price as precio_menu
  from public.menu_items mi
  join biz on mi.business_id = biz.id
  join menu m on pg_temp.norm(mi.name) = pg_temp.norm(m.name)
  where mi.is_active
),
itbis as (
  select t.* from public.taxes t, biz
  where t.business_id = biz.id
    and t.name ilike '%itbis%' and t.rate = 18 and coalesce(t.is_active, true)
  limit 1
),
juegos as (
  select i.id,
         coalesce((select string_agg(format('%s %s%%', t.name, t.rate), ' + '
                                     order by t.rate desc, t.name)
                   from public.menu_item_taxes x
                   join public.taxes t on t.id = x.tax_id
                   where x.item_id = i.id), 'SIN IMPUESTO') as juego,
         coalesce((select sum(t.rate) from public.menu_item_taxes x
                   join public.taxes t on t.id = x.tax_id
                   where x.item_id = i.id), 0) as tasa
  from items i
),
areas as (
  select distinct mipa.print_area_id as id
  from public.menu_item_print_areas mipa
  join items i on i.id = mipa.menu_item_id
),
cocina as (
  select coalesce((select bs.kitchen_enabled from public.business_settings bs, biz
                   where bs.business_id = biz.id), true) as encendida
),
parecidos as (
  select mi.name
  from public.menu_items mi, biz
  where mi.business_id = biz.id
    and mi.is_active
    and pg_temp.norm(mi.name) not in (select pg_temp.norm(name) from menu)
    and pg_temp.norm(mi.name) ~ '(mojito|colada|margarita|martini|long island|cuba|gin |gin$|sangria|sex on|sunrise|bahama|paradise|lagoon|velvet|azotea|brisa|deseo|pass?ion|mamey|chivas|tequila|trago)'
),
r(orden, concepto, encontrado, esperado, ok) as (
  select 1, 'Productos del menú (activos)',
         (select count(*) from items)::text, '21',
         (select count(*) from items) = 21
  union all
  select 2, 'Con precio distinto a la libreta',
         (select count(*) from items where price <> precio_menu)::text, '0',
         (select count(*) from items where price <> precio_menu) = 0
  union all
  select 3, 'Con impuestos incluidos (inclusive)',
         (select count(*) from items where tax_mode = 'inclusive')::text, '21',
         (select count(*) from items where tax_mode = 'inclusive') = 21
  union all
  select 4, 'Vinculados al ITBIS 18%',
         (select count(*) from items i where exists (
            select 1 from public.menu_item_taxes x join itbis t on t.id = x.tax_id
            where x.item_id = i.id))::text, '21',
         (select count(*) from items i where exists (
            select 1 from public.menu_item_taxes x join itbis t on t.id = x.tax_id
            where x.item_id = i.id)) = 21
  union all
  select 5, 'Juego de impuestos (el mismo en todos)',
         (select string_agg(format('%s (%s)', juego, n), ' · ')
          from (select juego, count(*) as n from juegos group by juego) g),
         'uno solo',
         (select count(distinct juego) from juegos) = 1
  union all
  select 6, 'Ejemplo: Cuba Libre $375',
         (select format('base %s + impuestos %s = 375',
                        round(375 / (1 + tasa / 100), 2),
                        375 - round(375 / (1 + tasa / 100), 2))
          from juegos j join items i on i.id = j.id
          where pg_temp.norm(i.name) = 'cuba libre'),
         'total 375',
         true
  union all
  select 7, 'Área de comanda: ' || case
            when not (select encendida from cocina) then 'ninguna (cocina apagada)'
            else coalesce((select string_agg(a.name || ' (' || a.code || ')', ', ')
                           from public.print_areas a where a.id in (select id from areas)), '—')
            end,
         (select count(*) from items i where exists (
            select 1 from public.menu_item_print_areas x where x.menu_item_id = i.id))::text,
         case when (select encendida from cocina) then '21' else '0' end,
         case when (select encendida from cocina)
              then (select count(*) from items i where exists (
                      select 1 from public.menu_item_print_areas x where x.menu_item_id = i.id)) = 21
                   and (select count(*) from areas) = 1
              else (select count(*) from areas) = 0
         end
  union all
  select 8, 'Legacy print_area_code igual a la N:M',
         (select count(*) from items i
          where i.print_area_code is not distinct from (
            select a.code from public.menu_item_print_areas x
            join public.print_areas a on a.id = x.print_area_id
            where x.menu_item_id = i.id limit 1))::text, '21',
         (select count(*) from items i
          where i.print_area_code is not distinct from (
            select a.code from public.menu_item_print_areas x
            join public.print_areas a on a.id = x.print_area_id
            where x.menu_item_id = i.id limit 1)) = 21
  union all
  select 9, 'Enlazados al menú de la caja',
         (select count(*) from items i where exists (
            select 1 from public.menu_item_links l where l.item_id = i.id))::text, '21',
         (select count(*) from items i where exists (
            select 1 from public.menu_item_links l where l.item_id = i.id)) = 21
  union all
  select 10, 'Impresoras en el área del bar',
         case when not (select encendida from cocina) then 'no aplica'
              else (select count(*) from public.print_area_printers p
                    where p.area_id in (select id from areas))::text end,
         '1 o más',
         not (select encendida from cocina)
         or (select count(*) from public.print_area_printers p
             where p.area_id in (select id from areas)) > 0
  union all
  select 11, 'ITBIS en mesa / rápida / llevar / delivery',
         coalesce((select concat_ws(' / ',
                     case when apply_on_zone     then 'sí' else 'NO' end,
                     case when apply_on_quick    then 'sí' else 'NO' end,
                     case when apply_on_takeout  then 'sí' else 'NO' end,
                     case when apply_on_delivery then 'sí' else 'NO' end) from itbis), '—'),
         'sí / sí / sí / sí',
         coalesce((select apply_on_zone and apply_on_quick
                          and apply_on_takeout and apply_on_delivery from itbis), false)
  union all
  select 12, 'Otros productos activos con nombre parecido',
         coalesce((select string_agg(name, ', ' order by name) from parecidos), '0'),
         '0',
         not exists (select 1 from parecidos)
)
select concepto, encontrado, esperado,
       case when ok then '✓' else '✗ REVISAR' end as estado
from r
order by orden;
