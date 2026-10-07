-- ============================================================================
-- CAFETERIA MARICELA — CARGA DEL CATÁLOGO
-- Business 1971ae49-935c-464a-9bfc-131d76a63be3
--
-- Fuente: "Reporte General de Inventarios" del sistema anterior
-- (ReportInventarios_Todos.pdf, 06/10/2026 2:31 p. m.), 111 productos.
-- Este archivo lo arma build_import_1971ae49.py. No lo edites a mano.
-- ============================================================================
--
-- QUÉ CARGA
--   111 productos en 17 categorías: 73 de comida (van a la COCINA) y 38
--   bebidas (van al BAR). El código del sistema viejo queda como SKU y el
--   costo en menu_items.cost. Sin insumos ni existencias.
--
-- PRECIOS (ITBIS 18% INCLUIDO, sin Ley 10%)
--   tax_mode = 'inclusive': lo que dice la lista es lo que paga el cliente.
--   * 22 precios del PDF eran el NETO de un precio redondo (254.24 × 1.18 =
--     300.00): el sistema viejo les sumaba el ITBIS por fuera. Se cargan al
--     precio final (Aperol 300, Corona 225, Presidente 180...).
--   * QUESILLO 169.92 → 200 y DULCE DE PIÑA CON LECHE 127.81 → 150.
--   * CERDO ASADO + CASABE va en 533.33 como en el PDF: falta que el dueño
--     confirme el precio.
--
-- NOMBRES
--   9 errores de tipeo se corrigen (BLODY MARRY → BLOODY MARY, MUSCOW MULE →
--   MOSCOW MULE, RUN PUNCH → RUM PUNCH, CASAAMIGOS → CASAMIGOS...).
--
-- CÓMO CORRERLO
--   Corre antes 00_diagnostico.sql. Después pega este entero en el SQL
--   Editor de Supabase y dale Run. La tabla que sale al final es el reporte:
--   todas las filas deben decir ✓.
--
-- TODO O NADA
--   Va en UNA transacción. Primero comprueba todo (negocio, ITBIS, menú,
--   áreas, choques con el catálogo actual) y después, antes del commit,
--   verifica los 111 uno por uno. Si algo no cuadra lanza excepción y
--   REVIERTE ENTERO.
--
-- SE PUEDE RE-CORRER
--   Empareja por SKU (el código del PDF) o por nombre, sin mayúsculas ni
--   tildes. El que ya existe se ACTUALIZA (precio, costo, categoría,
--   impuestos, área) y el que falta se INSERTA. Para corregir un precio:
--   cámbialo en catalogo.py, corre build_import_1971ae49.py y vuelve a
--   correr este archivo.
--
-- IMPUESTOS
--   menu_item_taxes es la ÚNICA fuente del impuesto por producto: sin fila ahí
--   la factura sale con ITBIS 0.00. Cada producto queda con el ITBIS 18% y
--   nada más (si tenía la Ley u otro impuesto vinculado, se le quita).
--
-- ÁREAS DE COMANDA (cómo las escoge)
--   * cocina apagada en Ajustes (kitchen_enabled = false): ninguna;
--   * COCINA: un área activa con code cocina / kitchen / kitchen_hot / comida
--     (o que se llame así); si no, reactiva una apagada, o CREA "Cocina"
--     (code `cocina`) SIN impresora;
--   * BAR: un área activa con code bar / barra (o que se llame así); si no,
--     reactiva una apagada, o CREA "Bar" (code `bar`) SIN impresora;
--   * nunca usa las áreas de sistema (cashier, fiscal, cash_close).
--   Un área creada aquí sale ✗ en el reporte hasta que le vincules la
--   impresora en la app.
--   Escribe LOS DOS mecanismos: menu_item_print_areas (N:M) y el legacy
--   menu_items.print_area_code, que fn_add_item_from_menu copia al
--   order_item. Sin el legacy, un bache de red manda la comanda a otro lado.
--
-- MENÚ
--   La caja filtra los productos por menú (menu_item_links). Se reusa el menú
--   activo que hay; si no hay ninguno se crea "Menú Principal"; si hay más de
--   uno, ABORTA.
-- ============================================================================

begin;

-- Nombre normalizado: sin mayúsculas, sin tildes, sin espacios repetidos.
create or replace function pg_temp.norm(t text) returns text
language sql immutable as $f$
  select translate(lower(regexp_replace(btrim(t), '\s+', ' ', 'g')),
                   'áéíóúüñÁÉÍÓÚÜÑ', 'aeiouunaeiouun')
$f$;

-- ---------------------------------------------------------------------------
-- 0) La lista. Tablas temporales de la sesión: el reporte de abajo las usa.
-- ---------------------------------------------------------------------------

drop table if exists _mc_categorias;
create temp table _mc_categorias (
  name     text not null,
  posicion int  not null,
  area     text not null check (area in ('cocina', 'bar'))
);

insert into _mc_categorias (name, posicion, area) values
--@@CATEGORIAS@@
;

drop table if exists _mc_productos;
create temp table _mc_productos (
  code        text not null,
  name        text not null,
  nombre_pdf  text not null,
  categoria   text not null,
  price       numeric(12,2) not null,
  cost        numeric not null,
  posicion    int not null
);

insert into _mc_productos (code, name, nombre_pdf, categoria, price, cost, posicion) values
--@@PRODUCTOS@@
;

do $$
declare
  v_business  uuid := '1971ae49-935c-464a-9bfc-131d76a63be3';
  v_esperados int;
  v_itbis_id  uuid;
  v_kitchen   boolean;
  v_cocina_id   uuid;
  v_cocina_code text;
  v_bar_id      uuid;
  v_bar_code    text;
  v_menu_id   uuid;
  v_menus     int;
  v_n         int;
  v_list      text;
begin
  select count(*) into v_esperados from _mc_productos;

  -- =========================================================================
  -- 1) GUARDAS: se comprueba todo ANTES de escribir una sola fila.
  -- =========================================================================

  -- 1a) El negocio existe.
  if not exists (select 1 from public.businesses where id = v_business) then
    raise exception 'El negocio % no existe.', v_business;
  end if;

  -- 1b) La lista no trae un código ni un nombre dos veces, ni una categoría
  --     que no exista.
  select string_agg(n, ', ') into v_list
  from (select pg_temp.norm(name) as n from _mc_productos
        group by 1 having count(*) > 1
        union all
        select code from _mc_productos group by 1 having count(*) > 1) d;
  if v_list is not null then
    raise exception 'La lista trae códigos o nombres repetidos: %', v_list;
  end if;

  if exists (select 1 from _mc_productos p
             where not exists (select 1 from _mc_categorias c where c.name = p.categoria)) then
    raise exception 'Hay productos con una categoría que no está en _mc_categorias.';
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

  -- 1d) Emparejamiento con el catálogo actual: por SKU (código del PDF) o por
  --     nombre (el corregido o el del PDF). Cada renglón de la lista puede
  --     caer en UN producto como mucho, y cada producto en UN renglón.
  drop table if exists _mc_cand;
  create temp table _mc_cand on commit drop as
  select p.code, mi.id as item_id, mi.name as item_name,
         (btrim(coalesce(mi.sku, '')) = p.code) as por_sku,
         (pg_temp.norm(mi.name) in (pg_temp.norm(p.name), pg_temp.norm(p.nombre_pdf))) as por_nombre
  from _mc_productos p
  join public.menu_items mi
    on mi.business_id = v_business
   and (btrim(coalesce(mi.sku, '')) = p.code
        or pg_temp.norm(mi.name) in (pg_temp.norm(p.name), pg_temp.norm(p.nombre_pdf)));

  select string_agg(format('%s → %s', code, nombres), '; ') into v_list
  from (select code, string_agg(item_name, ' / ' order by item_name) as nombres
        from _mc_cand group by code having count(*) > 1) d;
  if v_list is not null then
    raise exception
      'Estos renglones caen en VARIOS productos del catálogo, no sé cuál actualizar: %', v_list;
  end if;

  select string_agg(format('%s ← %s', item_name, codes), '; ') into v_list
  from (select item_name, string_agg(code, ', ' order by code) as codes
        from _mc_cand group by item_id, item_name having count(*) > 1) d;
  if v_list is not null then
    raise exception
      'Estos productos del catálogo caen en VARIOS renglones de la lista: %', v_list;
  end if;

  -- Mismo SKU pero otro nombre: el código del sistema viejo ya se usó para
  -- otra cosa. No se pisa.
  select string_agg(format('%s (sku %s) vs lista "%s"', c.item_name, c.code, p.name), '; ')
    into v_list
  from _mc_cand c
  join _mc_productos p on p.code = c.code
  where c.por_sku and not c.por_nombre;
  if v_list is not null then
    raise exception
      'Estos productos tienen el SKU de la lista pero OTRO nombre, no los piso: %', v_list;
  end if;

  -- 1e) Menú: 0 se crea, 1 se reusa, más de 1 aborta.
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

  -- 1f) Áreas de comanda (ver encabezado).
  select coalesce(bs.kitchen_enabled, true) into v_kitchen
  from public.business_settings bs
  where bs.business_id = v_business;
  v_kitchen := coalesce(v_kitchen, true);

  if v_kitchen then
    -- COCINA
    select a.id, a.code into v_cocina_id, v_cocina_code
    from public.print_areas a
    where a.business_id = v_business
      and a.is_active
      and (a.code in ('cocina', 'kitchen', 'kitchen_hot', 'comida')
           or pg_temp.norm(a.name) in ('cocina', 'kitchen', 'comida'))
    order by (a.code = 'cocina') desc, (a.code = 'kitchen') desc, a.created_at
    limit 1;

    if v_cocina_id is null then
      select a.id, a.code into v_cocina_id, v_cocina_code
      from public.print_areas a
      where a.business_id = v_business
        and (a.code in ('cocina', 'kitchen', 'kitchen_hot', 'comida')
             or pg_temp.norm(a.name) in ('cocina', 'kitchen', 'comida'))
      order by (a.code = 'cocina') desc, a.created_at
      limit 1;

      if v_cocina_id is not null then
        update public.print_areas set is_active = true where id = v_cocina_id;
      elsif exists (select 1 from public.print_areas
                    where business_id = v_business and code = 'cocina') then
        raise exception 'Ya hay un área con code "cocina" que no se reconoce. Revísala.';
      else
        v_cocina_id   := gen_random_uuid();
        v_cocina_code := 'cocina';
        insert into public.print_areas (id, business_id, name, code, is_active)
        values (v_cocina_id, v_business, 'Cocina', v_cocina_code, true);
      end if;
    end if;

    -- BAR
    select a.id, a.code into v_bar_id, v_bar_code
    from public.print_areas a
    where a.business_id = v_business
      and a.is_active
      and (a.code in ('bar', 'barra') or pg_temp.norm(a.name) in ('bar', 'barra'))
    order by (a.code = 'bar') desc, a.created_at
    limit 1;

    if v_bar_id is null then
      select a.id, a.code into v_bar_id, v_bar_code
      from public.print_areas a
      where a.business_id = v_business
        and (a.code in ('bar', 'barra') or pg_temp.norm(a.name) in ('bar', 'barra'))
      order by (a.code = 'bar') desc, a.created_at
      limit 1;

      if v_bar_id is not null then
        update public.print_areas set is_active = true where id = v_bar_id;
      elsif exists (select 1 from public.print_areas
                    where business_id = v_business and code = 'bar') then
        raise exception 'Ya hay un área con code "bar" que no se reconoce. Revísala.';
      else
        v_bar_id   := gen_random_uuid();
        v_bar_code := 'bar';
        insert into public.print_areas (id, business_id, name, code, is_active)
        values (v_bar_id, v_business, 'Bar', v_bar_code, true);
      end if;
    end if;

    if v_cocina_id = v_bar_id then
      raise exception 'La cocina y el bar cayeron en la MISMA área (%). Revísalas.', v_bar_code;
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
  from _mc_categorias c
  where not exists (
    select 1 from public.categories x
    where x.business_id = v_business
      and pg_temp.norm(x.name) = pg_temp.norm(c.name)
  );

  update public.categories x
  set is_active = true
  from _mc_categorias c
  where x.business_id = v_business
    and pg_temp.norm(x.name) = pg_temp.norm(c.name)
    and not x.is_active;

  -- =========================================================================
  -- 4) PRODUCTOS: actualiza los que ya existen, inserta los que faltan.
  --    print_area_code se escribe aquí mismo. El nombre del que ya existe se
  --    respeta, salvo que sea el del PDF con el error de tipeo.
  -- =========================================================================

  drop table if exists _mc_dest;
  create temp table _mc_dest on commit drop as
  select p.code, cat.id as category_id, c.area,
         case c.area when 'cocina' then v_cocina_code else v_bar_code end as area_code,
         case c.area when 'cocina' then v_cocina_id   else v_bar_id   end as area_id
  from _mc_productos p
  join _mc_categorias c on c.name = p.categoria
  cross join lateral (
    select x.id from public.categories x
    where x.business_id = v_business
      and pg_temp.norm(x.name) = pg_temp.norm(p.categoria)
    order by x.is_active desc, x.created_at
    limit 1
  ) cat;

  update public.menu_items mi
  set name            = case when pg_temp.norm(mi.name) = pg_temp.norm(p.nombre_pdf)
                              and pg_temp.norm(p.nombre_pdf) <> pg_temp.norm(p.name)
                             then p.name else mi.name end,
      sku             = p.code,
      price           = p.price,
      cost            = p.cost,
      category_id     = d.category_id,
      tax_mode        = 'inclusive',
      is_active       = true,
      is_beverage     = (d.area = 'bar'),
      position        = p.posicion,
      print_area_code = d.area_code,
      updated_at      = now()
  from _mc_cand c
  join _mc_productos p on p.code = c.code
  join _mc_dest d on d.code = c.code
  where mi.id = c.item_id;

  insert into public.menu_items (
    id, business_id, category_id, name, sku, price, cost,
    tax_mode, is_active, is_beverage, position, print_area_code
  )
  select gen_random_uuid(), v_business, d.category_id, p.name, p.code, p.price, p.cost,
         'inclusive', true, (d.area = 'bar'), p.posicion, d.area_code
  from _mc_productos p
  join _mc_dest d on d.code = p.code
  where not exists (select 1 from _mc_cand c where c.code = p.code);

  drop table if exists _mc_ids;
  create temp table _mc_ids on commit drop as
  select mi.id, p.code
  from public.menu_items mi
  join _mc_productos p on p.code = btrim(mi.sku)
  where mi.business_id = v_business;

  -- =========================================================================
  -- 5) IMPUESTOS: solo el ITBIS 18%.
  -- =========================================================================

  delete from public.menu_item_taxes mit
  using _mc_ids i
  where mit.item_id = i.id
    and mit.tax_id <> v_itbis_id;

  insert into public.menu_item_taxes (item_id, tax_id)
  select i.id, v_itbis_id
  from _mc_ids i
  where not exists (
    select 1 from public.menu_item_taxes x
    where x.item_id = i.id and x.tax_id = v_itbis_id
  );

  -- =========================================================================
  -- 6) ÁREA DE COMANDA (N:M). El legacy ya quedó escrito en el paso 4.
  --    Se borran asignaciones a otras áreas: si no, el producto saldría por
  --    DOS impresoras. Con cocina apagada no queda ninguna.
  -- =========================================================================

  delete from public.menu_item_print_areas x
  using _mc_ids i
  join _mc_dest d on d.code = i.code
  where x.menu_item_id = i.id
    and x.print_area_id is distinct from d.area_id;

  insert into public.menu_item_print_areas (menu_item_id, print_area_id)
  select i.id, d.area_id
  from _mc_ids i
  join _mc_dest d on d.code = i.code
  where d.area_id is not null
    and not exists (
      select 1 from public.menu_item_print_areas x
      where x.menu_item_id = i.id and x.print_area_id = d.area_id
    );

  -- =========================================================================
  -- 7) ENLACE AL MENÚ: sin esto el producto no aparece en la caja.
  -- =========================================================================

  insert into public.menu_item_links (menu_id, item_id, position)
  select v_menu_id, i.id, p.posicion
  from _mc_ids i
  join _mc_productos p on p.code = i.code
  where not exists (
    select 1 from public.menu_item_links l
    where l.menu_id = v_menu_id and l.item_id = i.id
  );

  -- =========================================================================
  -- 8) VERIFICACIÓN DENTRO DE LA TRANSACCIÓN: cualquier fallo revierte TODO.
  -- =========================================================================

  select count(*) into v_n
  from _mc_productos p
  where (select count(*) from _mc_ids i
         join public.menu_items mi on mi.id = i.id
         where i.code = p.code and mi.is_active) <> 1;
  if v_n > 0 or (select count(*) from _mc_ids) <> v_esperados then
    raise exception '% productos de la lista no quedaron (o quedaron repetidos). Revertido.', v_n;
  end if;

  select count(*) into v_n
  from _mc_ids i
  join public.menu_items mi on mi.id = i.id
  join _mc_productos p on p.code = i.code
  join _mc_dest d on d.code = i.code
  where mi.price <> p.price
     or mi.cost is distinct from p.cost
     or mi.tax_mode <> 'inclusive'
     or mi.category_id is distinct from d.category_id
     or mi.is_beverage <> (d.area = 'bar');
  if v_n > 0 then
    raise exception '% productos con precio, costo, impuesto o categoría incorrectos. Revertido.', v_n;
  end if;

  select count(*) into v_n
  from _mc_ids i
  where not exists (select 1 from public.menu_item_taxes x
                    where x.item_id = i.id and x.tax_id = v_itbis_id)
     or exists (select 1 from public.menu_item_taxes x
                where x.item_id = i.id and x.tax_id <> v_itbis_id);
  if v_n > 0 then
    raise exception '% productos con un juego de impuestos distinto a solo ITBIS. Revertido.', v_n;
  end if;

  select count(*) into v_n
  from _mc_ids i
  join public.menu_items mi on mi.id = i.id
  join _mc_dest d on d.code = i.code
  where mi.print_area_code is distinct from d.area_code
     or (select count(*) from public.menu_item_print_areas x
         where x.menu_item_id = i.id) <> case when d.area_id is null then 0 else 1 end
     or (d.area_id is not null
         and not exists (select 1 from public.menu_item_print_areas x
                         where x.menu_item_id = i.id and x.print_area_id = d.area_id));
  if v_n > 0 then
    raise exception '% productos sin área de comanda o con legacy y N:M en desacuerdo. Revertido.', v_n;
  end if;

  select count(*) into v_n
  from _mc_ids i
  where not exists (select 1 from public.menu_item_links l
                    where l.menu_id = v_menu_id and l.item_id = i.id);
  if v_n > 0 then
    raise exception '% productos fuera del menú: no saldrían en la caja. Revertido.', v_n;
  end if;

  raise notice 'OK: % productos (% ya existían), cocina=%, bar=%. Commit.',
    v_esperados, (select count(*) from _mc_cand),
    coalesce(v_cocina_code, 'ninguna (cocina apagada)'),
    coalesce(v_bar_code, 'ninguna (cocina apagada)');
end $$;

commit;

-- ============================================================================
-- REPORTE: todas las filas deben decir ✓
-- ============================================================================

with
biz as (
  select '1971ae49-935c-464a-9bfc-131d76a63be3'::uuid as id
),
esperados as (
  select count(*)::int as n from _mc_productos
),
items as (
  select mi.*, p.price as precio_lista, p.cost as costo_lista, c.area
  from public.menu_items mi
  join biz on mi.business_id = biz.id
  join _mc_productos p on p.code = btrim(mi.sku)
  join _mc_categorias c on c.name = p.categoria
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
                   where x.item_id = i.id), 'SIN IMPUESTO') as juego
  from items i
),
ajustes as (
  select coalesce((s.j->>'kitchen_enabled')::boolean, true) as cocina_encendida,
         coalesce((s.j->>'service_fee_enabled')::boolean, false) as ley_por_orden
  from (select to_jsonb(bs) as j from public.business_settings bs, biz
        where bs.business_id = biz.id
        union all
        select '{}'::jsonb
        where not exists (select 1 from public.business_settings bs, biz
                          where bs.business_id = biz.id)) s
),
ruta as (
  select i.area, a.id as area_id, a.name, a.code
  from items i
  join public.menu_item_print_areas x on x.menu_item_id = i.id
  join public.print_areas a on a.id = x.print_area_id
),
r(orden, concepto, encontrado, esperado, ok) as (
  select 1, 'Productos de la lista (activos)',
         (select count(*) from items)::text, (select n from esperados)::text,
         (select count(*) from items) = (select n from esperados)
  union all
  select 2, 'Con precio o costo distinto a la lista',
         (select count(*) from items
          where price <> precio_lista or cost is distinct from costo_lista)::text, '0',
         (select count(*) from items
          where price <> precio_lista or cost is distinct from costo_lista) = 0
  union all
  select 3, 'Con ITBIS incluido (inclusive)',
         (select count(*) from items where tax_mode = 'inclusive')::text,
         (select n from esperados)::text,
         (select count(*) from items where tax_mode = 'inclusive') = (select n from esperados)
  union all
  select 4, 'Juego de impuestos (solo ITBIS 18%)',
         (select string_agg(format('%s (%s)', juego, n), ' · ')
          from (select juego, count(*) as n from juegos group by juego) g),
         'ITBIS 18% en todos',
         (select count(*) from juegos j
          where exists (select 1 from public.menu_item_taxes x join itbis t on t.id = x.tax_id
                        where x.item_id = j.id)
            and (select count(*) from public.menu_item_taxes x where x.item_id = j.id) = 1)
         = (select n from esperados)
  union all
  select 5, 'Ley 10% por orden (service_fee_enabled)',
         case when (select ley_por_orden from ajustes) then 'ENCENDIDA' else 'apagada' end,
         'apagada',
         not (select ley_por_orden from ajustes)
  union all
  select 6, 'Ejemplo: Aperol Spritz $300',
         (select format('base %s + ITBIS %s = %s',
                        round(i.price / 1.18, 2), i.price - round(i.price / 1.18, 2), i.price)
          from items i where i.sku = '000098'),
         'base 254.24 + ITBIS 45.76 = 300.00',
         (select i.price = 300 from items i where i.sku = '000098')
  union all
  select 7, 'Comida → área: ' || case
            when not (select cocina_encendida from ajustes) then 'ninguna (cocina apagada)'
            else coalesce((select string_agg(distinct name || ' (' || code || ')', ', ')
                           from ruta where area = 'cocina'), '—') end,
         (select count(distinct x.menu_item_id) from public.menu_item_print_areas x
          join items i on i.id = x.menu_item_id where i.area = 'cocina')::text,
         case when (select cocina_encendida from ajustes)
              then (select count(*) from items where area = 'cocina')::text else '0' end,
         case when (select cocina_encendida from ajustes)
              then (select count(distinct x.menu_item_id) from public.menu_item_print_areas x
                    join items i on i.id = x.menu_item_id where i.area = 'cocina')
                   = (select count(*) from items where area = 'cocina')
                   and (select count(distinct area_id) from ruta where area = 'cocina') = 1
              else not exists (select 1 from ruta) end
  union all
  select 8, 'Bebidas → área: ' || case
            when not (select cocina_encendida from ajustes) then 'ninguna (cocina apagada)'
            else coalesce((select string_agg(distinct name || ' (' || code || ')', ', ')
                           from ruta where area = 'bar'), '—') end,
         (select count(distinct x.menu_item_id) from public.menu_item_print_areas x
          join items i on i.id = x.menu_item_id where i.area = 'bar')::text,
         case when (select cocina_encendida from ajustes)
              then (select count(*) from items where area = 'bar')::text else '0' end,
         case when (select cocina_encendida from ajustes)
              then (select count(distinct x.menu_item_id) from public.menu_item_print_areas x
                    join items i on i.id = x.menu_item_id where i.area = 'bar')
                   = (select count(*) from items where area = 'bar')
                   and (select count(distinct area_id) from ruta where area = 'bar') = 1
              else not exists (select 1 from ruta) end
  union all
  select 9, 'Legacy print_area_code igual a la N:M',
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
  select 10, 'Enlazados al menú de la caja',
         (select count(*) from items i where exists (
            select 1 from public.menu_item_links l where l.item_id = i.id))::text,
         (select n from esperados)::text,
         (select count(*) from items i where exists (
            select 1 from public.menu_item_links l where l.item_id = i.id))
         = (select n from esperados)
  union all
  select 11, 'Impresoras en el área de la cocina',
         case when not (select cocina_encendida from ajustes) then 'no aplica'
              else (select count(*) from public.print_area_printers p
                    where p.area_id in (select area_id from ruta where area = 'cocina'))::text end,
         '1 o más',
         not (select cocina_encendida from ajustes)
         or (select count(*) from public.print_area_printers p
             where p.area_id in (select area_id from ruta where area = 'cocina')) > 0
  union all
  select 12, 'Impresoras en el área del bar',
         case when not (select cocina_encendida from ajustes) then 'no aplica'
              else (select count(*) from public.print_area_printers p
                    where p.area_id in (select area_id from ruta where area = 'bar'))::text end,
         '1 o más',
         not (select cocina_encendida from ajustes)
         or (select count(*) from public.print_area_printers p
             where p.area_id in (select area_id from ruta where area = 'bar')) > 0
  union all
  select 13, 'ITBIS en mesa / rápida / llevar / delivery',
         coalesce((select concat_ws(' / ',
                     case when apply_on_zone     then 'sí' else 'NO' end,
                     case when apply_on_quick    then 'sí' else 'NO' end,
                     case when apply_on_takeout  then 'sí' else 'NO' end,
                     case when apply_on_delivery then 'sí' else 'NO' end) from itbis), '—'),
         'sí / sí / sí / sí',
         coalesce((select apply_on_zone and apply_on_quick
                          and apply_on_takeout and apply_on_delivery from itbis), false)
  union all
  select 14, 'Categorías con productos de la lista',
         (select count(distinct category_id) from items)::text,
         (select count(*) from _mc_categorias)::text,
         (select count(distinct category_id) from items) = (select count(*) from _mc_categorias)
)
select concepto, encontrado, esperado,
       case when ok then '✓' else '✗ REVISAR' end as estado
from r
order by orden;
