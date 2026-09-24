-- ============================================================================
-- AZOTEA 046 BAR & GRILL — CARGA DEL MENÚ DE COMIDA
-- Business e7a63240-6492-4ed5-8057-319ab91a748c
--
-- Fuente: lista de precios que pasó el usuario (2026-09-23). No hay CSV.
-- Este archivo lo arma build.sh a partir de _tpl_import.sql y _productos.sql.
-- ============================================================================
--
-- QUÉ CARGA
--   56 productos de comida en 9 categorías nuevas, en MAYÚSCULAS como las
--   demás del negocio: ENTRADAS, ESPECIALES DE LA CASA Y PASTAS, CARNES,
--   POLLO, MOFONGOS, MARISCOS PESCADOS Y CHIVO, ENSALADAS, SOPAS y
--   GUARNICIONES. Van en las posiciones 10 a 18, o sea DESPUÉS de las
--   bebidas (que están en 0 y 1).
--   Precios con los impuestos INCLUIDOS (tax_mode = 'inclusive'), igual que
--   los cócteles: lo que dice la lista es lo que paga el cliente.
--   Todo va al área de comanda de la COCINA, nunca al BAR.
--
-- QUÉ NO CARGA
--   * Mofongo Azotea: no tiene precio.
--
-- OJO CON LOS NOMBRES
--   * "Brisa tropical" ($295, entradas) se llama igual que el cóctel Brisa
--     Tropical ($375) que ya está en COCTELES. Como la carga empareja por
--     nombre, lo habría pisado. Se carga como "Brisa Tropical (Entrada)".
--   * "Indonsa con parisienne de camarones" va tal cual vino. Si es un error
--     de tipeo, se cambia en la app.
--
-- CÓMO CORRERLO
--   Corre antes 00_diagnostico_comida.sql. Después pega este entero en el SQL
--   Editor de Supabase y dale Run. La tabla que sale al final es el reporte:
--   todas las filas deben decir ✓.
--
-- TODO O NADA
--   Va en UNA transacción. Primero comprueba todo (negocio, ITBIS, Ley, menú,
--   área, nombres repetidos, choques con productos que NO son de este menú) y
--   después, antes del commit, verifica los 56 uno por uno. Si algo no cuadra
--   lanza excepción y REVIERTE ENTERO.
--
-- SE PUEDE RE-CORRER
--   Empareja por nombre, sin mayúsculas ni tildes. El que ya existe se
--   ACTUALIZA (precio, categoría, impuestos, área) y conserva su nombre; el
--   que falta se INSERTA. Para corregir un precio: cámbialo en la lista y
--   vuelve a correrlo. Para agregar el Mofongo Azotea: ponlo en la lista.
--
-- IMPUESTOS
--   menu_item_taxes es la ÚNICA fuente del impuesto por producto: sin fila ahí
--   la factura sale con ITBIS 0.00. ITBIS 18% + LEY 10%, como el resto de la
--   carta. Con 'inclusive' la Ley NO sube el precio: se saca de adentro. Un
--   Churrasco Angus de $1,650 queda en base 1,289.06 + impuestos 360.94.
--
-- ÁREA DE COMANDA (cómo la escoge)
--   * cocina apagada en Ajustes (kitchen_enabled = false): ninguna;
--   * si hay un área activa de cocina (code cocina / kitchen / kitchen_hot /
--     comida, o que se llame así), esa;
--   * si no, reactiva una de cocina apagada, o CREA "Cocina" (code `cocina`)
--     SIN impresora: la fila 10 del reporte sale ✗ hasta que le vincules la
--     impresora en la app;
--   * nunca usa el BAR ni las áreas de sistema (cashier, fiscal, cash_close).
--   Escribe LOS DOS mecanismos: menu_item_print_areas (N:M) y el legacy
--   menu_items.print_area_code, que fn_add_item_from_menu copia al
--   order_item. Sin el legacy, un bache de red manda la comanda a otro lado.
--
-- MENÚ
--   La caja filtra los productos por menú (menu_item_links). Se reusa el menú
--   que hay (MENU PRINCIPAL); si hay más de uno, ABORTA.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- ▶ DECISIÓN: ¿la comida lleva la Ley 10%?
--     'si' → ITBIS + Ley (como los cócteles y las aguas).
--     'no' → solo ITBIS.
-- ---------------------------------------------------------------------------
drop table if exists _cm_cfg;
create temp table _cm_cfg as
select 'si'::text as ley;

-- Nombre normalizado: sin mayúsculas, sin tildes, sin espacios repetidos.
create or replace function pg_temp.norm(t text) returns text
language sql immutable as $f$
  select translate(lower(regexp_replace(btrim(t), '\s+', ' ', 'g')),
                   'áéíóúüñÁÉÍÓÚÜÑ', 'aeiouunaeiouun')
$f$;

-- ---------------------------------------------------------------------------
-- 0) El menú. Tablas temporales de la sesión: el reporte de abajo las usa.
-- ---------------------------------------------------------------------------

drop table if exists _cm_categorias;
create temp table _cm_categorias (
  name     text not null,
  posicion int  not null
);

insert into _cm_categorias (name, posicion) values
  ('ENTRADAS',                        10),
  ('ESPECIALES DE LA CASA Y PASTAS',  11),
  ('CARNES',                          12),
  ('POLLO',                           13),
  ('MOFONGOS',                        14),
  ('MARISCOS, PESCADOS Y CHIVO',      15),
  ('ENSALADAS',                       16),
  ('SOPAS',                           17),
  ('GUARNICIONES',                    18);

drop table if exists _cm_productos;
create temp table _cm_productos (
  categoria text not null,
  name      text not null,
  price     numeric(12,2) not null,
  posicion  int not null
);

insert into _cm_productos (categoria, name, price, posicion) values
  ('ENTRADAS', 'Fuego Callejero',                     285.00,  1),
  -- "Brisa tropical" choca con el cóctel Brisa Tropical ($375) de COCTELES.
  ('ENTRADAS', 'Brisa Tropical (Entrada)',            295.00,  2),
  ('ENTRADAS', 'Cóctel de Camarones',                 390.00,  3),
  ('ENTRADAS', 'Croquetas de Plátano Maduro',         390.00,  4),
  ('ENTRADAS', 'Nachos',                              425.00,  5),
  ('ENTRADAS', 'Deditos de Mozzarella',               295.00,  6),
  ('ENTRADAS', 'Bastoncito de Pescado',               350.00,  7),
  ('ENTRADAS', 'Croquetas de Pollo',                  275.00,  8),

  ('ESPECIALES DE LA CASA Y PASTAS', 'Pasta Tropical',                     595.00,  1),
  ('ESPECIALES DE LA CASA Y PASTAS', 'Pasta al Fuego Azotea',              450.00,  2),
  ('ESPECIALES DE LA CASA Y PASTAS', 'Pechuga a la Casa',                  725.00,  3),
  ('ESPECIALES DE LA CASA Y PASTAS', 'Camarones al Fuego Tropical Azotea', 750.00,  4),
  ('ESPECIALES DE LA CASA Y PASTAS', 'Filete de Cerdo Mignon',             795.00,  5),

  ('CARNES', 'Filete de Res a la Plancha',            1150.00, 1),
  ('CARNES', 'Filete Mar y Tierra',                   1250.00, 2),
  ('CARNES', 'Filete Miñón',                          1150.00, 3),
  ('CARNES', 'Churrasco Angus',                       1650.00, 4),
  ('CARNES', 'Solomillo de Res',                      1050.00, 5),
  ('CARNES', 'Costilla de Res',                        650.00, 6),
  ('CARNES', 'Picaña',                                1250.00, 7),
  ('CARNES', 'T-Bone al Grill',                       2895.00, 8),
  ('CARNES', 'Filete de Chuleta',                      550.00, 9),

  ('POLLO', 'Pechuga a la Crema',                      580.00,  1),
  ('POLLO', 'Pechuga de Pollo',                        450.00,  2),
  ('POLLO', 'Pechuga Cordon Bleu',                     590.00,  3),
  ('POLLO', 'Pechuga Salteada',                        425.00,  4),
  ('POLLO', 'Brocheta de Pollo',                       395.00,  5),
  ('POLLO', 'Pechuga de Pollo al Vino Blanco',         595.00,  6),
  ('POLLO', 'Pechuga al Hongo',                        650.00,  7),
  ('POLLO', 'Alitas',                                  375.00,  8),
  ('POLLO', 'Alitas Búfalo',                           325.00,  9),
  ('POLLO', 'Alita Asiática',                          295.00, 10),

  ('MOFONGOS', 'Mofongo de Camarones',                 550.00,  1),
  ('MOFONGOS', 'Mofongo de Pollo',                     495.00,  2),
  ('MOFONGOS', 'Mofongo Mixto',                        650.00,  3),
  ('MOFONGOS', 'Mofongo de Chicharrón',                595.00,  4),

  ('MARISCOS, PESCADOS Y CHIVO', 'Camarones al Grill',                 695.00, 1),
  ('MARISCOS, PESCADOS Y CHIVO', 'Salmón al Grill',                    950.00, 2),
  ('MARISCOS, PESCADOS Y CHIVO', 'Filete de Mero en Salsa de Chinola', 590.00, 3),
  ('MARISCOS, PESCADOS Y CHIVO', 'Chivo Guisado',                      950.00, 4),
  ('MARISCOS, PESCADOS Y CHIVO', 'Chivo al Vino',                      950.00, 5),
  ('MARISCOS, PESCADOS Y CHIVO', 'Chivo al Horno',                     950.00, 6),

  ('ENSALADAS', 'Ensalada César',                      480.00,  1),
  ('ENSALADAS', 'César Mar y Tierra',                  690.00,  2),
  ('ENSALADAS', 'Rosette a la Casa',                   595.00,  3),
  ('ENSALADAS', 'Indonsa con Parisienne de Camarones', 695.00,  4),

  ('SOPAS', 'Sopa de Pollo',                           350.00,  1),
  ('SOPAS', 'Sopa de Camarones',                       650.00,  2),
  ('SOPAS', 'Sopa de Mero',                            495.00,  3),

  ('GUARNICIONES', 'Puré de Papa',                     125.00,  1),
  ('GUARNICIONES', 'Tostones',                         125.00,  2),
  ('GUARNICIONES', 'Papa Salteada',                    125.00,  3),
  ('GUARNICIONES', 'Arroz Blanco',                     100.00,  4),
  ('GUARNICIONES', 'Vegetales Salteados',               95.00,  5),
  ('GUARNICIONES', 'Vegetales Hervidos',                95.00,  6),
  ('GUARNICIONES', 'Batata Frita',                      95.00,  7)
;

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
  v_n         int;
  v_list      text;
begin
  select count(*) into v_esperados from _cm_productos;
  select lower(btrim(ley)) into v_cfg_ley from _cm_cfg;

  if v_cfg_ley not in ('si', 'no') then
    raise exception 'La decisión de la Ley debe ser si o no (dice "%").', v_cfg_ley;
  end if;

  -- =========================================================================
  -- 1) GUARDAS: se comprueba todo ANTES de escribir una sola fila.
  -- =========================================================================

  -- 1a) El negocio existe.
  if not exists (select 1 from public.businesses where id = v_business) then
    raise exception 'El negocio % no existe.', v_business;
  end if;

  -- 1b) La lista no trae un nombre dos veces, ni una categoría que no exista.
  select string_agg(n, ', ') into v_list
  from (select pg_temp.norm(name) as n from _cm_productos
        group by 1 having count(*) > 1) d;
  if v_list is not null then
    raise exception 'La lista trae nombres repetidos: %', v_list;
  end if;

  if exists (select 1 from _cm_productos p
             where not exists (select 1 from _cm_categorias c where c.name = p.categoria)) then
    raise exception 'Hay productos con una categoría que no está en _cm_categorias.';
  end if;

  -- 1c) Un ITBIS 18% activo, y uno solo, sin is_service_fee.
  select count(*) into v_n
  from public.taxes t
  where t.business_id = v_business
    and t.name ilike '%itbis%'
    and t.rate = 18
    and coalesce(t.is_active, true);

  if v_n <> 1 then
    select string_agg(format('%s %s%% (%s)', t.name, t.rate,
             case when coalesce(t.is_active, true) then 'activo' else 'INACTIVO' end),
           ', ')
      into v_list
    from public.taxes t
    where t.business_id = v_business;

    raise exception
      'Debe haber UN ITBIS 18%% activo y hay % (impuestos del negocio: %).',
      v_n, coalesce(v_list, 'ninguno');
  end if;

  select t.id into v_itbis_id
  from public.taxes t
  where t.business_id = v_business
    and t.name ilike '%itbis%'
    and t.rate = 18
    and coalesce(t.is_active, true);

  if exists (select 1 from public.taxes
             where id = v_itbis_id and coalesce(is_service_fee, false)) then
    raise exception
      'El ITBIS tiene is_service_fee = true: la factura lo cobraría DOS veces.';
  end if;

  -- 1d) La Ley 10%.
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

  v_con_ley := (v_cfg_ley = 'si');

  if v_con_ley then
    if v_ley_id is null then
      raise exception
        'Pediste la Ley 10%% pero el negocio no tiene un impuesto activo del 10%%.';
    end if;
    if exists (select 1 from public.taxes
               where id = v_ley_id and coalesce(is_service_fee, false)) then
      raise exception
        'La Ley tiene is_service_fee = true: vinculada al producto se factura DOBLE.';
    end if;
    if exists (select 1 from public.business_settings
               where business_id = v_business
                 and coalesce(service_fee_enabled, false)) then
      raise exception
        'service_fee_enabled está en true: la Ley saldría por producto Y por orden.';
    end if;
  end if;

  -- 1e) Ningún nombre del menú repetido en el catálogo: no sabría cuál
  --     actualizar.
  select string_agg(format('%s (%s veces)', p.name, x.n), ', ')
    into v_list
  from _cm_productos p
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

  -- 1f) Ningún nombre del menú choca con un producto que es BEBIDA o vive en
  --     una categoría que no es de comida: lo pisaría (el caso de Brisa
  --     Tropical). Uno sin categoría sí se reusa.
  select string_agg(format('%s ($%s, categoría %s)', mi.name, mi.price,
                           coalesce(c.name, '—')), ', ')
    into v_list
  from public.menu_items mi
  join _cm_productos p on pg_temp.norm(p.name) = pg_temp.norm(mi.name)
  left join public.categories c on c.id = mi.category_id
  where mi.business_id = v_business
    and (mi.is_beverage
         or pg_temp.norm(c.name) not in (select pg_temp.norm(name) from _cm_categorias));

  if v_list is not null then
    raise exception
      'Estos productos de la lista ya existen FUERA de las categorías de comida y '
      'los pisaría: %. Cámbiales el nombre en la lista.', v_list;
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

  -- 1h) Área de comanda de la cocina (ver encabezado).
  select coalesce(bs.kitchen_enabled, true) into v_kitchen
  from public.business_settings bs
  where bs.business_id = v_business;
  v_kitchen := coalesce(v_kitchen, true);

  if v_kitchen then
    select a.id, a.code into v_area_id, v_area_code
    from public.print_areas a
    where a.business_id = v_business
      and a.is_active
      and (a.code in ('cocina', 'kitchen', 'kitchen_hot', 'comida')
           or pg_temp.norm(a.name) in ('cocina', 'kitchen', 'comida'))
    order by (a.code = 'cocina') desc, (a.code = 'kitchen') desc, a.created_at
    limit 1;

    if v_area_id is null then
      select a.id, a.code into v_area_id, v_area_code
      from public.print_areas a
      where a.business_id = v_business
        and (a.code in ('cocina', 'kitchen', 'kitchen_hot', 'comida')
             or pg_temp.norm(a.name) in ('cocina', 'kitchen', 'comida'))
      order by (a.code = 'cocina') desc, a.created_at
      limit 1;

      if v_area_id is not null then
        update public.print_areas set is_active = true where id = v_area_id;
      elsif exists (select 1 from public.print_areas
                    where business_id = v_business and code = 'cocina') then
        raise exception 'Ya hay un área con code "cocina" que no se reconoce. Revísala.';
      else
        v_area_id   := gen_random_uuid();
        v_area_code := 'cocina';
        insert into public.print_areas (id, business_id, name, code, is_active)
        values (v_area_id, v_business, 'Cocina', v_area_code, true);
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
  from _cm_categorias c
  where not exists (
    select 1 from public.categories x
    where x.business_id = v_business
      and pg_temp.norm(x.name) = pg_temp.norm(c.name)
  );

  update public.categories x
  set is_active = true
  from _cm_categorias c
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
      is_beverage     = false,
      position        = p.posicion,
      print_area_code = v_area_code,
      updated_at      = now()
  from _cm_productos p
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
         'inclusive', true, false, p.posicion, v_area_code
  from _cm_productos p
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

  drop table if exists _cm_ids;
  create temp table _cm_ids on commit drop as
  select mi.id, p.name
  from public.menu_items mi
  join _cm_productos p on pg_temp.norm(mi.name) = pg_temp.norm(p.name)
  where mi.business_id = v_business;

  drop table if exists _cm_taxes;
  create temp table _cm_taxes on commit drop as
  select v_itbis_id as tax_id
  union all
  select v_ley_id where v_con_ley;

  -- =========================================================================
  -- 5) IMPUESTOS: exactamente el juego decidido arriba.
  -- =========================================================================

  delete from public.menu_item_taxes mit
  using _cm_ids i
  where mit.item_id = i.id
    and mit.tax_id not in (select tax_id from _cm_taxes);

  insert into public.menu_item_taxes (item_id, tax_id)
  select i.id, t.tax_id
  from _cm_ids i
  cross join _cm_taxes t
  where not exists (
    select 1 from public.menu_item_taxes x
    where x.item_id = i.id and x.tax_id = t.tax_id
  );

  -- =========================================================================
  -- 6) ÁREA DE COMANDA (N:M). El legacy ya quedó escrito en el paso 4.
  --    Se borran asignaciones a otras áreas: si no, el plato saldría por DOS
  --    impresoras. Con cocina apagada no queda ninguna.
  -- =========================================================================

  delete from public.menu_item_print_areas x
  using _cm_ids i
  where x.menu_item_id = i.id
    and x.print_area_id is distinct from v_area_id;

  if v_area_id is not null then
    insert into public.menu_item_print_areas (menu_item_id, print_area_id)
    select i.id, v_area_id
    from _cm_ids i
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
  from _cm_ids i
  join _cm_productos p on p.name = i.name
  where not exists (
    select 1 from public.menu_item_links l
    where l.menu_id = v_menu_id and l.item_id = i.id
  );

  -- =========================================================================
  -- 8) VERIFICACIÓN DENTRO DE LA TRANSACCIÓN: cualquier fallo revierte TODO.
  -- =========================================================================

  select count(*) into v_n
  from _cm_productos p
  where (select count(*) from public.menu_items mi
         where mi.business_id = v_business
           and pg_temp.norm(mi.name) = pg_temp.norm(p.name)
           and mi.is_active) <> 1;
  if v_n > 0 or (select count(*) from _cm_ids) <> v_esperados then
    raise exception '% productos del menú no quedaron (o quedaron repetidos). Revertido.', v_n;
  end if;

  select count(*) into v_n
  from _cm_ids i
  join public.menu_items mi on mi.id = i.id
  join _cm_productos p on p.name = i.name
  join public.categories c on c.id = mi.category_id
  where mi.price <> p.price
     or mi.tax_mode <> 'inclusive'
     or pg_temp.norm(c.name) <> pg_temp.norm(p.categoria)
     or mi.is_beverage;
  select v_n + count(*) into v_n
  from _cm_ids i
  join public.menu_items mi on mi.id = i.id
  where mi.category_id is null;
  if v_n > 0 then
    raise exception '% productos con precio, modo de impuesto o categoría incorrectos. Revertido.', v_n;
  end if;

  select count(*) into v_n
  from _cm_ids i
  where exists (select 1 from _cm_taxes t
                where not exists (select 1 from public.menu_item_taxes x
                                  where x.item_id = i.id and x.tax_id = t.tax_id))
     or exists (select 1 from public.menu_item_taxes x
                where x.item_id = i.id
                  and x.tax_id not in (select tax_id from _cm_taxes));
  if v_n > 0 then
    raise exception '% productos con un juego de impuestos distinto al decidido. Revertido.', v_n;
  end if;

  select count(*) into v_n
  from _cm_ids i
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

  select count(*) into v_n
  from _cm_ids i
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
esperados as (
  select count(*)::int as n from _cm_productos
),
items as (
  select mi.*, p.price as precio_lista, p.categoria
  from public.menu_items mi
  join biz on mi.business_id = biz.id
  join _cm_productos p on pg_temp.norm(mi.name) = pg_temp.norm(p.name)
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
bebidas_intactas as (
  -- Los cócteles de ayer siguen en el BAR: la carga no los tocó.
  select count(*) as n
  from public.menu_items mi, biz
  where mi.business_id = biz.id
    and mi.is_active
    and mi.is_beverage
    and mi.print_area_code = 'bar'
),
r(orden, concepto, encontrado, esperado, ok) as (
  select 1, 'Productos de comida (activos)',
         (select count(*) from items)::text, (select n from esperados)::text,
         (select count(*) from items) = (select n from esperados)
  union all
  select 2, 'Con precio distinto a la lista',
         (select count(*) from items where price <> precio_lista)::text, '0',
         (select count(*) from items where price <> precio_lista) = 0
  union all
  select 3, 'Con impuestos incluidos (inclusive)',
         (select count(*) from items where tax_mode = 'inclusive')::text,
         (select n from esperados)::text,
         (select count(*) from items where tax_mode = 'inclusive') = (select n from esperados)
  union all
  select 4, 'Vinculados al ITBIS 18%',
         (select count(*) from items i where exists (
            select 1 from public.menu_item_taxes x join itbis t on t.id = x.tax_id
            where x.item_id = i.id))::text, (select n from esperados)::text,
         (select count(*) from items i where exists (
            select 1 from public.menu_item_taxes x join itbis t on t.id = x.tax_id
            where x.item_id = i.id)) = (select n from esperados)
  union all
  select 5, 'Juego de impuestos (el mismo en todos)',
         (select string_agg(format('%s (%s)', juego, n), ' · ')
          from (select juego, count(*) as n from juegos group by juego) g),
         'uno solo',
         (select count(distinct juego) from juegos) = 1
  union all
  select 6, 'Ejemplo: Churrasco Angus $1,650',
         (select format('base %s + impuestos %s = 1650',
                        round(1650 / (1 + tasa / 100), 2),
                        1650 - round(1650 / (1 + tasa / 100), 2))
          from juegos j join items i on i.id = j.id
          where pg_temp.norm(i.name) = 'churrasco angus'),
         'total 1650',
         true
  union all
  select 7, 'Área de comanda: ' || case
            when not (select encendida from cocina) then 'ninguna (cocina apagada)'
            else coalesce((select string_agg(a.name || ' (' || a.code || ')', ', ')
                           from public.print_areas a where a.id in (select id from areas)), '—')
            end,
         (select count(*) from items i where exists (
            select 1 from public.menu_item_print_areas x where x.menu_item_id = i.id))::text,
         case when (select encendida from cocina) then (select n from esperados)::text else '0' end,
         case when (select encendida from cocina)
              then (select count(*) from items i where exists (
                      select 1 from public.menu_item_print_areas x where x.menu_item_id = i.id))
                   = (select n from esperados)
                   and (select count(*) from areas) = 1
                   and not exists (select 1 from public.print_areas a
                                   where a.id in (select id from areas)
                                     and a.code in ('bar', 'barra'))
              else (select count(*) from areas) = 0
         end
  union all
  select 8, 'Legacy print_area_code igual a la N:M',
         (select count(*) from items i
          where i.print_area_code is not distinct from (
            select a.code from public.menu_item_print_areas x
            join public.print_areas a on a.id = x.print_area_id
            where x.menu_item_id = i.id limit 1))::text, (select n from esperados)::text,
         (select count(*) from items i
          where i.print_area_code is not distinct from (
            select a.code from public.menu_item_print_areas x
            join public.print_areas a on a.id = x.print_area_id
            where x.menu_item_id = i.id limit 1)) = (select n from esperados)
  union all
  select 9, 'Enlazados al menú de la caja',
         (select count(*) from items i where exists (
            select 1 from public.menu_item_links l where l.item_id = i.id))::text,
         (select n from esperados)::text,
         (select count(*) from items i where exists (
            select 1 from public.menu_item_links l where l.item_id = i.id))
         = (select n from esperados)
  union all
  select 10, 'Impresoras en el área de la cocina',
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
  select 12, 'Bebidas que siguen en el BAR (cócteles, aguas)',
         (select n from bebidas_intactas)::text, '21 o más',
         (select n from bebidas_intactas) >= 21
)
select concepto, encontrado, esperado,
       case when ok then '✓' else '✗ REVISAR' end as estado
from r
order by orden;
