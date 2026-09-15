-- ============================================================================
-- TÍA SARA — CARGA COMPLETA DEL MENÚ
-- Business 6edecb1d-e940-45ff-83b5-044ca08319fb
--
-- Fuente: foto del menú impreso (2026-09-14). No hay CSV ni export.
-- ============================================================================
--
-- QUÉ CARGA
--   24 productos · 8 categorías · 5 grupos de modificadores obligatorios
--   Todo va al área de comanda de COCINA (el menú no tiene bebidas).
--
-- CÓMO CORRERLO
--   Corre antes 00_diagnostico.sql. Después pega este entero en el SQL Editor
--   de Supabase y dale Run. La tabla que sale al final es el reporte: todas
--   las filas deben decir ✓.
--
-- TODO O NADA
--   Va en UNA transacción. Primero comprueba todo (negocio, ITBIS, Ley, menú,
--   área, nombres repetidos) y después, antes del commit, verifica los 24 uno
--   por uno. Si algo no cuadra lanza excepción y REVIERTE ENTERO.
--
-- SE PUEDE RE-CORRER
--   Empareja por nombre (sin mayúsculas). El producto que ya existe se
--   ACTUALIZA (precio, categoría, ITBIS, área) y el que falta se INSERTA.
--   Correrlo dos veces no duplica nada. Para corregir un precio: cámbialo en
--   la lista de abajo y vuelve a correrlo.
--
-- DECISIONES DEL DUEÑO (2026-09-14)
--   * ITBIS 18% INCLUIDO en el precio (tax_mode = 'inclusive'). La Pechu Tía
--     de 6 piezas se cobra $425: base 360.17 + ITBIS 64.83. En 'exclusive'
--     el POS cobraría $501.50 y el menú sería mentira.
--     El vínculo en menu_item_taxes NO es cosmético: esa tabla es la ÚNICA
--     fuente del impuesto por producto. Sin fila ahí, la factura sale con
--     ITBIS 0.00 ante la DGII aunque el impuesto exista.
--   * NO cobran Ley 10%. Si alguno de estos productos ya tenía otro impuesto
--     vinculado, se le quita. El script aborta si service_fee_enabled está en
--     true o si el ITBIS tiene is_service_fee = true (cobraría dos veces).
--   * "PECHURINA" se llama "Pechu Tía" (corrección a mano en la foto).
--   * Los combos piden el acompañamiento al marcarlos. Son grupos de
--     modificadores de 1 sola opción y obligatorios ("Acompañamiento 1" a
--     "Acompañamiento 4"). Van en grupos separados, y no en uno de "elige 2",
--     porque el diálogo de la POS no deja escoger la misma opción dos veces:
--     así el Tía Sara 2 puede salir con dos papas fritas.
--     El Tía Sara Simple pide además "Muslo" (largo o corto).
--     Las opciones van en $0 y salen escritas en la comanda debajo del combo.
--
-- ÁREA DE COMANDA — cómo la escoge el script
--   * si existe el área `cocina`, esa;
--   * si no, y hay UNA sola área de comida activa, esa;
--   * si no hay ninguna, CREA "Cocina" (code `cocina`);
--   * si hay varias, ABORTA y las lista (me dices a cuál va).
--   Las áreas de sistema (cashier, fiscal, cash_close) no cuentan.
--   Se escriben LOS DOS mecanismos: menu_item_print_areas (N:M) y el legacy
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
-- 0) El menú, en tablas temporales que mueren con la transacción.
-- ---------------------------------------------------------------------------

create temp table _ts_categorias (
  name     text not null,
  posicion int  not null
) on commit drop;

insert into _ts_categorias (name, posicion) values
  ('Combos Tía Sara',  10),
  ('Pechu Tía',        20),
  ('Pica Pollo',       30),
  ('Alitas de Pollo',  40),
  ('Extra Tía Sara',   50),
  ('Tía Pops',         60),
  ('Agranda tu Orden', 70),
  ('Salsas',           80);

create temp table _ts_productos (
  categoria text not null,
  name      text not null,
  price     numeric(12,2) not null,
  descr     text,
  posicion  int not null
) on commit drop;

insert into _ts_productos (categoria, name, price, descr, posicion) values
  ('Combos Tía Sara', 'Tía Sara 1', 475.00,
   '2 piezas de Pechu Tía, 2 piezas de muslo (largo y corto), 1 pieza de alita + 1 acompañamiento.', 1),
  ('Combos Tía Sara', 'Tía Sara 2', 645.00,
   '3 piezas de Pechu Tía, 2 piezas de muslo (largo y corto), 2 piezas de alita + 2 acompañamientos.', 2),
  ('Combos Tía Sara', 'Tía Sara Simple', 350.00,
   '2 piezas de Pechu Tía, 1 pieza de muslo (largo o corto) + 1 acompañamiento.', 3),
  ('Combos Tía Sara', 'Tía Sara Feliz', 575.00,
   '3 piezas de Pechu Tía, 3 piezas de alitas + 1 acompañamiento.', 4),
  ('Combos Tía Sara', 'Tía Sara Súper Familiar', 1500.00,
   '1 servicio de Pechu Tía de 5 piezas, 1 servicio de pica pollo de 3 piezas, 1 servicio de alitas de 5 piezas + 4 acompañamientos.', 5),

  ('Pechu Tía', 'Pechu Tía 6 Piezas', 425.00, null, 6),
  ('Pechu Tía', 'Pechu Tía 8 Piezas', 495.00, null, 7),

  ('Pica Pollo', 'Pica Pollo 2 Piezas', 350.00, null, 8),
  ('Pica Pollo', 'Pica Pollo 3 Piezas', 425.00, null, 9),
  ('Pica Pollo', 'Pica Pollo 4 Piezas', 525.00, null, 10),
  ('Pica Pollo', 'Pica Pollo 5 Piezas', 650.00, null, 11),

  ('Alitas de Pollo', 'Alitas 5 Piezas', 445.00, null, 12),
  ('Alitas de Pollo', 'Alitas 6 Piezas', 495.00, null, 13),
  ('Alitas de Pollo', 'Alitas 8 Piezas', 700.00, null, 14),

  ('Extra Tía Sara', 'Alitas con Salsa Barbacoa', 550.00,
   '6 piezas de alitas crocantes, ahogadas en salsa BBQ Tía Sara. Especial sensacional, sabor único de la casa.', 15),
  ('Extra Tía Sara', 'Alitas Honey Mustard', 575.00,
   '6 piezas de alitas crocantes, bañadas en nuestra honey mustard Tía Sara. Unas alitas con una explosión de sabor Tía Sara.', 16),
  ('Extra Tía Sara', 'Tía Americana Buffalo', 575.00,
   '6 piezas de alitas crocantes, cada una bañada en nuestra salsa Buffalo americana. Pruébala y te quedarás por el sabor único Tía Americana.', 17),

  ('Tía Pops', 'Tía Pops', 300.00, null, 18),

  ('Agranda tu Orden', 'Papas Fritas',    150.00, null, 19),
  ('Agranda tu Orden', 'Tostones',        150.00, null, 20),
  ('Agranda tu Orden', 'Palitos de Yuca', 150.00, null, 21),

  ('Salsas', 'Salsa La Sobrina',        50.00, null, 22),
  ('Salsas', 'Salsa Especial Tía Sara', 50.00, null, 23),
  ('Salsas', 'Salsa Wasakaka',          50.00, null, 24);

-- Grupos de modificadores: todos de 1 opción y obligatorios.
create temp table _ts_grupos (
  name  text not null,
  orden int  not null
) on commit drop;

insert into _ts_grupos (name, orden) values
  ('Muslo',            10),
  ('Acompañamiento 1', 20),
  ('Acompañamiento 2', 30),
  ('Acompañamiento 3', 40),
  ('Acompañamiento 4', 50);

create temp table _ts_opciones (
  grupo text not null,
  name  text not null,
  orden int  not null
) on commit drop;

insert into _ts_opciones (grupo, name, orden)
select g.name, o.name, o.orden
from _ts_grupos g
cross join (values ('Papas Fritas', 10), ('Tostones', 20), ('Palitos de Yuca', 30))
  as o(name, orden)
where g.name like 'Acompañamiento %'
union all
select 'Muslo', o.name, o.orden
from (values ('Muslo largo', 10), ('Muslo corto', 20)) as o(name, orden);

-- Qué combo pide qué grupo.
create temp table _ts_enlaces (
  producto text not null,
  grupo    text not null
) on commit drop;

insert into _ts_enlaces (producto, grupo) values
  ('Tía Sara 1',              'Acompañamiento 1'),
  ('Tía Sara 2',              'Acompañamiento 1'),
  ('Tía Sara 2',              'Acompañamiento 2'),
  ('Tía Sara Simple',         'Muslo'),
  ('Tía Sara Simple',         'Acompañamiento 1'),
  ('Tía Sara Feliz',          'Acompañamiento 1'),
  ('Tía Sara Súper Familiar', 'Acompañamiento 1'),
  ('Tía Sara Súper Familiar', 'Acompañamiento 2'),
  ('Tía Sara Súper Familiar', 'Acompañamiento 3'),
  ('Tía Sara Súper Familiar', 'Acompañamiento 4');

do $$
declare
  v_business  uuid := '6edecb1d-e940-45ff-83b5-044ca08319fb';
  v_tax_id    uuid;
  v_area_id   uuid;
  v_area_code text;
  v_menu_id   uuid;
  v_menus     int;
  v_n         int;
  v_list      text;
begin
  -- =========================================================================
  -- 1) GUARDAS — se comprueba todo ANTES de escribir una sola fila.
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

  select t.id into v_tax_id
  from public.taxes t
  where t.business_id = v_business
    and t.name ilike '%itbis%'
    and t.rate = 18
    and coalesce(t.is_active, true);

  -- 1c) is_service_fee apagado: encendido, la factura lo cobra DOS veces.
  if exists (select 1 from public.taxes
             where id = v_tax_id and coalesce(is_service_fee, false)) then
    raise exception
      'El ITBIS tiene is_service_fee = true: la factura lo cobraría DOS veces. '
      'Apágalo antes de cargar el menú.';
  end if;

  -- 1d) Propina por orden apagada: Tía Sara no cobra Ley 10%.
  if exists (select 1 from public.business_settings
             where business_id = v_business
               and coalesce(service_fee_enabled, false)) then
    raise exception
      'business_settings.service_fee_enabled está en true: cobraría un 10%% '
      'por orden que Tía Sara no cobra. Apágalo primero.';
  end if;

  -- 1e) Ningún nombre del menú repetido en el catálogo: no sabría cuál
  --     actualizar.
  select string_agg(format('%s (%s veces)', p.name, x.n), ', ')
    into v_list
  from _ts_productos p
  cross join lateral (
    select count(*) as n from public.menu_items mi
    where mi.business_id = v_business
      and lower(btrim(mi.name)) = lower(p.name)
  ) x
  where x.n > 1;

  if v_list is not null then
    raise exception
      'Productos repetidos en el catálogo actual, no sé cuál actualizar: %', v_list;
  end if;

  -- 1f) Ningún grupo de modificadores repetido por nombre.
  select string_agg(format('%s (%s veces)', g.name, x.n), ', ')
    into v_list
  from _ts_grupos g
  cross join lateral (
    select count(*) as n from public.modifier_groups mg
    where mg.business_id = v_business
      and lower(btrim(mg.name)) = lower(g.name)
  ) x
  where x.n > 1;

  if v_list is not null then
    raise exception
      'Grupos de modificadores repetidos, no sé cuál usar: %', v_list;
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
  select count(*), string_agg(format('%s (%s)', name, code), ', ')
    into v_n, v_list
  from public.print_areas
  where business_id = v_business
    and is_active
    and code not in ('cashier', 'fiscal', 'cash_close');

  select id, code into v_area_id, v_area_code
  from public.print_areas
  where business_id = v_business and code = 'cocina';

  if v_area_id is not null then
    if not exists (select 1 from public.print_areas
                   where id = v_area_id and is_active) then
      if v_n > 0 then
        raise exception
          'El área "cocina" está desactivada y hay otras activas (%). '
          'Dime a cuál va la comida.', v_list;
      end if;
      update public.print_areas set is_active = true where id = v_area_id;
    end if;
  elsif v_n = 1 then
    select id, code into v_area_id, v_area_code
    from public.print_areas
    where business_id = v_business
      and is_active
      and code not in ('cashier', 'fiscal', 'cash_close');
  elsif v_n = 0 then
    v_area_id   := gen_random_uuid();
    v_area_code := 'cocina';
    insert into public.print_areas (id, business_id, name, code, is_active)
    values (v_area_id, v_business, 'Cocina', v_area_code, true);
  else
    raise exception
      'Hay % áreas de comanda activas (%) y ninguna es "cocina". '
      'Dime a cuál va la comida.', v_n, v_list;
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
  -- 3) CATEGORÍAS — crea las que falten; las que ya existen se respetan.
  -- =========================================================================

  insert into public.categories (id, business_id, name, position, is_active)
  select gen_random_uuid(), v_business, c.name, c.posicion, true
  from _ts_categorias c
  where not exists (
    select 1 from public.categories x
    where x.business_id = v_business
      and lower(btrim(x.name)) = lower(c.name)
  );

  -- =========================================================================
  -- 4) PRODUCTOS — actualiza los que ya existen, inserta los que faltan.
  --    print_area_code se escribe aquí mismo: si se omite, la columna cae en
  --    su default 'kitchen_hot', que este negocio no tiene, y "Enviar a
  --    cocina" revienta sin que salga ninguna comanda.
  -- =========================================================================

  update public.menu_items mi
  set price           = p.price,
      description     = coalesce(p.descr, mi.description),
      category_id     = cat.id,
      tax_mode        = 'inclusive',
      is_active       = true,
      position        = p.posicion,
      print_area_code = v_area_code,
      updated_at      = now()
  from _ts_productos p
  cross join lateral (
    select c.id from public.categories c
    where c.business_id = v_business
      and lower(btrim(c.name)) = lower(p.categoria)
    order by c.created_at
    limit 1
  ) cat
  where mi.business_id = v_business
    and lower(btrim(mi.name)) = lower(p.name);

  insert into public.menu_items (
    id, business_id, category_id, name, description, price,
    tax_mode, is_active, is_beverage, position, print_area_code
  )
  select gen_random_uuid(), v_business, cat.id, p.name, p.descr, p.price,
         'inclusive', true, false, p.posicion, v_area_code
  from _ts_productos p
  cross join lateral (
    select c.id from public.categories c
    where c.business_id = v_business
      and lower(btrim(c.name)) = lower(p.categoria)
    order by c.created_at
    limit 1
  ) cat
  where not exists (
    select 1 from public.menu_items mi
    where mi.business_id = v_business
      and lower(btrim(mi.name)) = lower(p.name)
  );

  create temp table _ts_ids on commit drop as
  select mi.id, p.name
  from public.menu_items mi
  join _ts_productos p on lower(btrim(mi.name)) = lower(p.name)
  where mi.business_id = v_business;

  -- =========================================================================
  -- 5) IMPUESTOS — exactamente el ITBIS. Otro impuesto vinculado (una Ley de
  --    antes) se quita: Tía Sara no la cobra.
  -- =========================================================================

  delete from public.menu_item_taxes mit
  using _ts_ids i
  where mit.item_id = i.id
    and mit.tax_id <> v_tax_id;

  insert into public.menu_item_taxes (item_id, tax_id)
  select i.id, v_tax_id
  from _ts_ids i
  where not exists (
    select 1 from public.menu_item_taxes x
    where x.item_id = i.id and x.tax_id = v_tax_id
  );

  -- =========================================================================
  -- 6) ÁREA DE COMANDA (N:M). El legacy ya quedó escrito en el paso 4.
  --    Se borran asignaciones a otras áreas: si no, el producto saldría por
  --    DOS impresoras.
  -- =========================================================================

  delete from public.menu_item_print_areas x
  using _ts_ids i
  where x.menu_item_id = i.id
    and x.print_area_id <> v_area_id;

  insert into public.menu_item_print_areas (menu_item_id, print_area_id)
  select i.id, v_area_id
  from _ts_ids i
  where not exists (
    select 1 from public.menu_item_print_areas x
    where x.menu_item_id = i.id and x.print_area_id = v_area_id
  );

  -- =========================================================================
  -- 7) ENLACE AL MENÚ — sin esto el producto no aparece en la caja.
  -- =========================================================================

  insert into public.menu_item_links (menu_id, item_id, position)
  select v_menu_id, i.id, p.posicion
  from _ts_ids i
  join _ts_productos p on p.name = i.name
  where not exists (
    select 1 from public.menu_item_links l
    where l.menu_id = v_menu_id and l.item_id = i.id
  );

  -- =========================================================================
  -- 8) MODIFICADORES DE LOS COMBOS
  --    min_select = max_select = 1 + display_type 'single': el diálogo de la
  --    POS no deja agregar el combo sin escoger ("Debes completar: ...").
  -- =========================================================================

  insert into public.modifier_groups (
    id, business_id, name, min_select, max_select, is_active,
    display_type, selection_mode, is_required, free_qty,
    max_qty_per_option, sort_order
  )
  select gen_random_uuid(), v_business, g.name, 1, 1, true,
         'single', 'modifier', true, 0, 1, g.orden
  from _ts_grupos g
  where not exists (
    select 1 from public.modifier_groups x
    where x.business_id = v_business
      and lower(btrim(x.name)) = lower(g.name)
  );

  update public.modifier_groups x
  set min_select   = 1,
      max_select   = 1,
      is_active    = true,
      display_type = 'single',
      is_required  = true
  from _ts_grupos g
  where x.business_id = v_business
    and lower(btrim(x.name)) = lower(g.name);

  insert into public.modifiers (
    id, business_id, group_id, name, price_delta, is_active, sort_order
  )
  select gen_random_uuid(), v_business, x.id, o.name, 0, true, o.orden
  from _ts_opciones o
  join public.modifier_groups x
    on x.business_id = v_business
   and lower(btrim(x.name)) = lower(o.grupo)
  where not exists (
    select 1 from public.modifiers m
    where m.group_id = x.id
      and lower(btrim(m.name)) = lower(o.name)
  );

  update public.modifiers m
  set is_active   = true,
      price_delta = 0
  from _ts_opciones o
  join public.modifier_groups x
    on x.business_id = v_business
   and lower(btrim(x.name)) = lower(o.grupo)
  where m.group_id = x.id
    and lower(btrim(m.name)) = lower(o.name)
    and (not m.is_active or m.price_delta <> 0);

  insert into public.menu_item_groups (menu_item_id, group_id)
  select i.id, x.id
  from _ts_enlaces e
  join _ts_ids i on i.name = e.producto
  join public.modifier_groups x
    on x.business_id = v_business
   and lower(btrim(x.name)) = lower(e.grupo)
  where not exists (
    select 1 from public.menu_item_groups y
    where y.menu_item_id = i.id and y.group_id = x.id
  );

  -- Orden de los grupos dentro del diálogo (Muslo antes que Acompañamiento,
  -- y 1-2-3-4 en el Súper Familiar). menu_item_groups.position existe en la
  -- BD viva pero no en las migraciones del repo: se escribe solo si está.
  if exists (select 1 from information_schema.columns
             where table_schema = 'public'
               and table_name   = 'menu_item_groups'
               and column_name  = 'position') then
    execute $q$
      update public.menu_item_groups y
      set position = g.orden
      from _ts_enlaces e
      join _ts_ids i    on i.name = e.producto
      join _ts_grupos g on g.name = e.grupo
      join public.modifier_groups x
        on x.business_id = $1
       and lower(btrim(x.name)) = lower(e.grupo)
      where y.menu_item_id = i.id
        and y.group_id = x.id
    $q$ using v_business;
  end if;

  -- =========================================================================
  -- 9) VERIFICACIÓN DENTRO DE LA TRANSACCIÓN — cualquier fallo revierte TODO.
  --    Se verifica contra la lista del menú, no contra el catálogo entero:
  --    un producto que el negocio agregue a mano no rompe un re-run.
  -- =========================================================================

  -- Los 24, cada uno exactamente una vez y activo.
  select count(*) into v_n
  from _ts_productos p
  where (select count(*) from public.menu_items mi
         where mi.business_id = v_business
           and lower(btrim(mi.name)) = lower(p.name)
           and mi.is_active) <> 1;
  if v_n > 0 or (select count(*) from _ts_ids) <> 24 then
    raise exception '% productos del menú no quedaron (o quedaron repetidos). Revertido.', v_n;
  end if;

  -- Precio del menú, con el ITBIS dentro, y con categoría.
  select count(*) into v_n
  from _ts_ids i
  join public.menu_items mi on mi.id = i.id
  join _ts_productos p on p.name = i.name
  where mi.price <> p.price
     or mi.tax_mode <> 'inclusive'
     or mi.category_id is null;
  if v_n > 0 then
    raise exception '% productos con precio, modo de impuesto o categoría incorrectos. Revertido.', v_n;
  end if;

  -- Exactamente el ITBIS: sin él factura 0.00; con otro, cobra de más.
  select count(*) into v_n
  from _ts_ids i
  where not exists (select 1 from public.menu_item_taxes x
                    where x.item_id = i.id and x.tax_id = v_tax_id)
     or exists (select 1 from public.menu_item_taxes x
                where x.item_id = i.id and x.tax_id <> v_tax_id);
  if v_n > 0 then
    raise exception '% productos sin ITBIS o con otro impuesto. Revertido.', v_n;
  end if;

  -- Una sola área, la de cocina, y el legacy de acuerdo con la N:M.
  select count(*) into v_n
  from _ts_ids i
  join public.menu_items mi on mi.id = i.id
  where mi.print_area_code is distinct from v_area_code
     or (select count(*) from public.menu_item_print_areas x
         where x.menu_item_id = i.id) <> 1
     or not exists (select 1 from public.menu_item_print_areas x
                    where x.menu_item_id = i.id and x.print_area_id = v_area_id);
  if v_n > 0 then
    raise exception '% productos sin área de comanda o con legacy y N:M en desacuerdo. Revertido.', v_n;
  end if;

  -- Todos en el menú de la caja.
  select count(*) into v_n
  from _ts_ids i
  where not exists (select 1 from public.menu_item_links l
                    where l.menu_id = v_menu_id and l.item_id = i.id);
  if v_n > 0 then
    raise exception '% productos fuera del menú: no saldrían en la caja. Revertido.', v_n;
  end if;

  -- Cada grupo con sus opciones activas.
  select count(*) into v_n
  from _ts_opciones o
  join public.modifier_groups x
    on x.business_id = v_business and lower(btrim(x.name)) = lower(o.grupo)
   and x.is_active and x.min_select = 1 and x.max_select = 1
  join public.modifiers m
    on m.group_id = x.id and lower(btrim(m.name)) = lower(o.name) and m.is_active;
  if v_n <> (select count(*) from _ts_opciones) then
    raise exception 'Se esperaban % opciones de modificador y hay %. Revertido.',
      (select count(*) from _ts_opciones), v_n;
  end if;

  -- Cada combo con sus grupos.
  select count(*) into v_n
  from _ts_enlaces e
  join _ts_ids i on i.name = e.producto
  join public.modifier_groups x
    on x.business_id = v_business and lower(btrim(x.name)) = lower(e.grupo)
  join public.menu_item_groups y
    on y.menu_item_id = i.id and y.group_id = x.id;
  if v_n <> (select count(*) from _ts_enlaces) then
    raise exception 'Se esperaban % enlaces combo→grupo y hay %. Revertido.',
      (select count(*) from _ts_enlaces), v_n;
  end if;

  raise notice 'OK — 24 productos con ITBIS, área % y menú. Commit.', v_area_code;
end $$;

commit;

-- ============================================================================
-- REPORTE — todas las filas deben decir ✓
-- ============================================================================

with menu(name, price) as (
  values
    ('Tía Sara 1', 475.00), ('Tía Sara 2', 645.00), ('Tía Sara Simple', 350.00),
    ('Tía Sara Feliz', 575.00), ('Tía Sara Súper Familiar', 1500.00),
    ('Pechu Tía 6 Piezas', 425.00), ('Pechu Tía 8 Piezas', 495.00),
    ('Pica Pollo 2 Piezas', 350.00), ('Pica Pollo 3 Piezas', 425.00),
    ('Pica Pollo 4 Piezas', 525.00), ('Pica Pollo 5 Piezas', 650.00),
    ('Alitas 5 Piezas', 445.00), ('Alitas 6 Piezas', 495.00), ('Alitas 8 Piezas', 700.00),
    ('Alitas con Salsa Barbacoa', 550.00), ('Alitas Honey Mustard', 575.00),
    ('Tía Americana Buffalo', 575.00), ('Tía Pops', 300.00),
    ('Papas Fritas', 150.00), ('Tostones', 150.00), ('Palitos de Yuca', 150.00),
    ('Salsa La Sobrina', 50.00), ('Salsa Especial Tía Sara', 50.00),
    ('Salsa Wasakaka', 50.00)
),
items as (
  select mi.*, m.price as precio_menu
  from public.menu_items mi
  join menu m on lower(btrim(mi.name)) = lower(m.name)
  where mi.business_id = '6edecb1d-e940-45ff-83b5-044ca08319fb'::uuid
    and mi.is_active
),
itbis as (
  select t.* from public.taxes t
  where t.business_id = '6edecb1d-e940-45ff-83b5-044ca08319fb'::uuid
    and t.name ilike '%itbis%' and t.rate = 18 and coalesce(t.is_active, true)
  limit 1
),
areas as (
  select distinct mipa.print_area_id as id
  from public.menu_item_print_areas mipa
  join items i on i.id = mipa.menu_item_id
),
r(orden, concepto, encontrado, esperado, ok) as (
  select 1, 'Productos del menú (activos)',
         (select count(*) from items)::text, '24',
         (select count(*) from items) = 24
  union all
  select 2, 'Con precio distinto al menú',
         (select count(*) from items where price <> precio_menu)::text, '0',
         (select count(*) from items where price <> precio_menu) = 0
  union all
  select 3, 'Con ITBIS incluido (inclusive)',
         (select count(*) from items where tax_mode = 'inclusive')::text, '24',
         (select count(*) from items where tax_mode = 'inclusive') = 24
  union all
  select 4, 'Vinculados al ITBIS 18%',
         (select count(*) from items i where exists (
            select 1 from public.menu_item_taxes x join itbis t on t.id = x.tax_id
            where x.item_id = i.id))::text, '24',
         (select count(*) from items i where exists (
            select 1 from public.menu_item_taxes x join itbis t on t.id = x.tax_id
            where x.item_id = i.id)) = 24
  union all
  select 5, 'Con otro impuesto (Ley u otro)',
         (select count(*) from items i where exists (
            select 1 from public.menu_item_taxes x
            where x.item_id = i.id and x.tax_id not in (select id from itbis)))::text, '0',
         (select count(*) from items i where exists (
            select 1 from public.menu_item_taxes x
            where x.item_id = i.id and x.tax_id not in (select id from itbis))) = 0
  union all
  select 6, 'Con área de comanda: ' || coalesce((
            select string_agg(a.name || ' (' || a.code || ')', ', ')
            from public.print_areas a where a.id in (select id from areas)), '—'),
         (select count(*) from items i where exists (
            select 1 from public.menu_item_print_areas x where x.menu_item_id = i.id))::text, '24',
         (select count(*) from items i where exists (
            select 1 from public.menu_item_print_areas x where x.menu_item_id = i.id)) = 24
            and (select count(*) from areas) = 1
  union all
  select 7, 'Legacy print_area_code igual a la N:M',
         (select count(*) from items i
            join public.menu_item_print_areas x on x.menu_item_id = i.id
            join public.print_areas a on a.id = x.print_area_id
          where a.code = i.print_area_code)::text, '24',
         (select count(*) from items i
            join public.menu_item_print_areas x on x.menu_item_id = i.id
            join public.print_areas a on a.id = x.print_area_id
          where a.code = i.print_area_code) = 24
  union all
  select 8, 'Enlazados al menú de la caja',
         (select count(*) from items i where exists (
            select 1 from public.menu_item_links l where l.item_id = i.id))::text, '24',
         (select count(*) from items i where exists (
            select 1 from public.menu_item_links l where l.item_id = i.id)) = 24
  union all
  select 9, 'Combos que piden acompañamiento',
         (select count(*) from items i where exists (
            select 1 from public.menu_item_groups y
            join public.modifier_groups g on g.id = y.group_id
            where y.menu_item_id = i.id and g.name = 'Acompañamiento 1'))::text, '5',
         (select count(*) from items i where exists (
            select 1 from public.menu_item_groups y
            join public.modifier_groups g on g.id = y.group_id
            where y.menu_item_id = i.id and g.name = 'Acompañamiento 1')) = 5
  union all
  select 10, 'Impresoras en el área de comanda',
         (select count(*) from public.print_area_printers p
          where p.area_id in (select id from areas))::text, '1 o más',
         (select count(*) from public.print_area_printers p
          where p.area_id in (select id from areas)) > 0
  union all
  select 11, 'ITBIS se cobra en venta rápida',
         coalesce((select case when apply_on_quick then 'sí' else 'NO' end from itbis), '—'), 'sí',
         coalesce((select apply_on_quick from itbis), false)
  union all
  select 12, 'ITBIS se cobra en mesa / zona',
         coalesce((select case when apply_on_zone then 'sí' else 'NO' end from itbis), '—'), 'sí',
         coalesce((select apply_on_zone from itbis), false)
  union all
  select 13, 'ITBIS se cobra para llevar',
         coalesce((select case when apply_on_takeout then 'sí' else 'NO' end from itbis), '—'), 'sí',
         coalesce((select apply_on_takeout from itbis), false)
  union all
  select 14, 'ITBIS se cobra en delivery',
         coalesce((select case when apply_on_delivery then 'sí' else 'NO' end from itbis), '—'), 'sí',
         coalesce((select apply_on_delivery from itbis), false)
)
select concepto, encontrado, esperado,
       case when ok then '✓' else '✗ REVISAR' end as estado
from r
order by orden;
