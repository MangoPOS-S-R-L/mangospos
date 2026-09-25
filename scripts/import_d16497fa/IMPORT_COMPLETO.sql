-- ============================================================================
-- MAX PÍCAME EL POLLO — CARGA DEL MENÚ
-- Business d16497fa-4853-41e3-8566-4d0565511f37
--
-- Fuente: foto del menú impreso (2026-09-24). No hay CSV.
-- ============================================================================
--
-- QUÉ CARGA
--   12 productos en la categoría POLLO (ya existe), al área COCINA (`cocina`):
--   * Pollo Frito: 2, 3, 4, 6, 8, 10, 12 y 16 piezas;
--   * Pechurrina: 3, 4, 6 y 8 piezas.
--   El menú dice "Incluye: tostones o papas", así que los 12 piden al
--   marcarlos un grupo OBLIGATORIO "Acompañamiento" (Tostones / Papas Fritas,
--   de una sola opción y en $0). La elección sale escrita en la comanda.
--   Precios con ITBIS INCLUIDO (tax_mode = 'inclusive'): lo que dice el menú
--   es lo que paga el cliente. Con ITBIS + LEY, 2 piezas a $170 = base
--   132.81 + impuestos 37.19.
--
-- DECISIONES (2026-09-24, con el diagnóstico en mano)
--   * ITBIS + LEY 10% (_mx_cfg.ley = 'si'). La LEY del negocio no se cobra en
--     venta rápida ni en delivery (así está configurada).
--   * "Pechurina" ($200, con ventas) se RENOMBRA a "Pechurrina 3 Piezas": la
--     carga la actualiza en vez de duplicarla y conserva su historial.
--   * "POLLO FRITO" ($350, con ventas) se DESACTIVA: ya no está en el menú.
--   * Agua, CHOFAN y DOBLE RESERVA no se tocan.
--
-- CÓMO CORRERLO
--   Pega este archivo entero en el SQL Editor de Supabase y dale Run. La
--   tabla del final es el reporte y todas sus filas deben decir ✓. Si
--   algo no cuadra, aborta con un mensaje que dice qué falta.
--
-- TODO O NADA
--   Va en UNA transacción: primero lo comprueba todo, y antes del commit
--   verifica los 12 productos uno por uno. Si algo falla, revierte todo.
--
-- SE PUEDE RE-CORRER
--   Busca los productos por nombre, sin mayúsculas ni tildes: el que ya existe
--   se ACTUALIZA y el que falta se INSERTA. Para corregir un precio, cámbialo
--   en la lista y vuelve a correrlo.
--
-- IMPUESTOS
--   menu_item_taxes es la ÚNICA fuente del impuesto por producto: sin una fila
--   ahí, la factura sale con ITBIS 0.00. Siempre se vincula el ITBIS 18%.
--   La Ley 10% depende de _mx_cfg.ley:
--     'auto' → si el negocio no tiene Ley, no se vincula. Si la tiene, ABORTA
--              y pregunta (cambia a 'si' o 'no');
--     'si'   → ITBIS + Ley, sacada de adentro del precio (el precio no sube);
--     'no'   → solo ITBIS.
--
-- ÁREA DE COMANDA
--   * Cocina apagada en Ajustes: no usa ninguna.
--   * Si hay un área de cocina (code cocina/kitchen/kitchen_hot o que se
--     llame "Cocina"), usa esa.
--   * Si no, y hay UNA sola área activa, usa esa.
--   * Si no hay ninguna, crea "Cocina" (`cocina`) sin impresora; después
--     le vinculas la impresora en la app.
--   * Si hay varias y ninguna es de cocina, ABORTA y las lista.
--   Las de sistema (cashier, fiscal, cash_close) no cuentan.
--   Escribe la N:M (menu_item_print_areas) y también el legacy print_area_code.
-- ============================================================================

begin;

-- ▶ DECISIÓN: la Ley 10% ('auto', 'si' o 'no'). Ver arriba.
drop table if exists _mx_cfg;
create temp table _mx_cfg as select 'si'::text as ley;

create or replace function pg_temp.norm(t text) returns text
language sql immutable as $f$
  select translate(lower(regexp_replace(btrim(t), '\s+', ' ', 'g')),
                   'áéíóúüñÁÉÍÓÚÜÑ', 'aeiouunaeiouun')
$f$;

drop table if exists _mx_categorias;
create temp table _mx_categorias (name text not null, posicion int not null);
insert into _mx_categorias (name, posicion) values
  ('POLLO', 10);

drop table if exists _mx_productos;
create temp table _mx_productos (
  categoria text not null,
  name      text not null,
  price     numeric(12,2) not null,
  posicion  int not null
);
insert into _mx_productos (categoria, name, price, posicion) values
  ('POLLO',       'Pollo Frito 2 Piezas',    170.00,  1),
  ('POLLO',       'Pollo Frito 3 Piezas',    260.00,  2),
  ('POLLO',       'Pollo Frito 4 Piezas',    360.00,  3),
  ('POLLO',       'Pollo Frito 6 Piezas',    540.00,  4),
  ('POLLO',       'Pollo Frito 8 Piezas',    720.00,  5),
  ('POLLO',       'Pollo Frito 10 Piezas',   850.00,  6),
  ('POLLO',       'Pollo Frito 12 Piezas',  1020.00,  7),
  ('POLLO',       'Pollo Frito 16 Piezas',  1360.00,  8),
  ('POLLO',       'Pechurrina 3 Piezas',     200.00,  9),
  ('POLLO',       'Pechurrina 4 Piezas',     250.00, 10),
  ('POLLO',       'Pechurrina 6 Piezas',     300.00, 11),
  ('POLLO',       'Pechurrina 8 Piezas',     400.00, 12);

-- Grupo obligatorio de 1 opción, en $0, para los 12 productos.
drop table if exists _mx_opciones;
create temp table _mx_opciones (name text not null, orden int not null);
insert into _mx_opciones (name, orden) values
  ('Tostones',     10),
  ('Papas Fritas', 20);

do $$
declare
  v_business  uuid := 'd16497fa-4853-41e3-8566-4d0565511f37';
  v_grupo     text := 'Acompañamiento';
  v_esperados int;
  v_cfg_ley   text;
  v_itbis_id  uuid;
  v_ley_id    uuid;
  v_con_ley   boolean;
  v_kitchen   boolean;
  v_area_id   uuid;
  v_area_code text;
  v_menu_id   uuid;
  v_group_id  uuid;
  v_n         int;
  v_list      text;
begin
  select count(*) into v_esperados from _mx_productos;
  select lower(btrim(ley)) into v_cfg_ley from _mx_cfg;
  if v_cfg_ley not in ('auto', 'si', 'no') then
    raise exception 'La decisión de la Ley debe ser auto, si o no (dice "%").', v_cfg_ley;
  end if;

  -- =========================================================================
  -- 1) GUARDAS
  -- =========================================================================

  if not exists (select 1 from public.businesses where id = v_business) then
    raise exception 'El negocio % no existe.', v_business;
  end if;

  -- ITBIS 18%: uno solo, activo, sin is_service_fee.
  select count(*) into v_n
  from public.taxes t
  where t.business_id = v_business and t.name ilike '%itbis%'
    and t.rate = 18 and coalesce(t.is_active, true);
  if v_n <> 1 then
    select string_agg(format('%s %s%% (%s)', t.name, t.rate,
             case when coalesce(t.is_active, true) then 'activo' else 'INACTIVO' end), ', ')
      into v_list
    from public.taxes t where t.business_id = v_business;
    raise exception
      'Debe haber UN ITBIS 18%% activo y hay % (impuestos del negocio: %). '
      'Créalo en Ajustes → Impuestos y vuelve a correr.', v_n, coalesce(v_list, 'ninguno');
  end if;

  select t.id into v_itbis_id
  from public.taxes t
  where t.business_id = v_business and t.name ilike '%itbis%'
    and t.rate = 18 and coalesce(t.is_active, true);

  if exists (select 1 from public.taxes where id = v_itbis_id and coalesce(is_service_fee, false)) then
    raise exception 'El ITBIS tiene is_service_fee = true: la factura lo cobraría DOS veces.';
  end if;

  -- Ley 10%.
  select count(*), string_agg(t.name, ', ') into v_n, v_list
  from public.taxes t
  where t.business_id = v_business and t.rate = 10
    and t.name not ilike '%itbis%' and coalesce(t.is_active, true);
  if v_n > 1 then
    raise exception 'Hay % impuestos activos del 10%% (%). Deja uno solo.', v_n, v_list;
  end if;
  select t.id into v_ley_id
  from public.taxes t
  where t.business_id = v_business and t.rate = 10
    and t.name not ilike '%itbis%' and coalesce(t.is_active, true);

  if v_cfg_ley = 'no' then
    v_con_ley := false;
  elsif v_cfg_ley = 'si' then
    if v_ley_id is null then
      raise exception 'Pediste la Ley 10%% pero el negocio no tiene un impuesto activo del 10%%.';
    end if;
    v_con_ley := true;
  elsif v_ley_id is null then
    v_con_ley := false;
  else
    raise exception
      'El negocio tiene la Ley "%" configurada. ¿El pollo la lleva? '
      'Cambia ''auto'' por ''si'' o ''no'' en _mx_cfg y vuelve a correr.', v_list;
  end if;

  if v_con_ley and exists (select 1 from public.taxes
                           where id = v_ley_id and coalesce(is_service_fee, false)) then
    raise exception 'La Ley tiene is_service_fee = true: vinculada al producto se factura DOBLE.';
  end if;
  if exists (select 1 from public.business_settings
             where business_id = v_business and coalesce(service_fee_enabled, false)) then
    raise exception
      'service_fee_enabled está en true: el negocio cobra un 10%% por orden. '
      'Dime si es intencional antes de cargar.';
  end if;

  -- Los 2 productos viejos: "Pechurina" pasa a ser "Pechurrina 3 Piezas" y
  -- "POLLO FRITO" (a secas) se desactiva. Ambos tienen ventas: no se borran.
  if exists (select 1 from public.menu_items
             where business_id = v_business and pg_temp.norm(name) = 'pechurina')
     and exists (select 1 from public.menu_items
                 where business_id = v_business and pg_temp.norm(name) = 'pechurrina 3 piezas') then
    raise exception 'Existen "Pechurina" y "Pechurrina 3 Piezas" a la vez: no sé cuál dejar.';
  end if;

  update public.menu_items
  set name = 'Pechurrina 3 Piezas', updated_at = now()
  where business_id = v_business and pg_temp.norm(name) = 'pechurina';

  update public.menu_items
  set is_active = false, updated_at = now()
  where business_id = v_business and pg_temp.norm(name) = 'pollo frito' and is_active;

  -- Nombres repetidos en el catálogo: no sabría cuál actualizar.
  select string_agg(format('%s (%s veces)', p.name, x.n), ', ') into v_list
  from _mx_productos p
  cross join lateral (
    select count(*) as n from public.menu_items mi
    where mi.business_id = v_business and pg_temp.norm(mi.name) = pg_temp.norm(p.name)
  ) x
  where x.n > 1;
  if v_list is not null then
    raise exception 'Productos repetidos en el catálogo actual: %', v_list;
  end if;

  select count(*) into v_n
  from public.modifier_groups
  where business_id = v_business and pg_temp.norm(name) = pg_temp.norm(v_grupo);
  if v_n > 1 then
    raise exception 'Hay % grupos de modificadores "%": no sé cuál usar.', v_n, v_grupo;
  end if;

  -- Menú: 0 se crea, 1 se reusa, más de 1 aborta.
  select count(*), string_agg(name, ', ' order by created_at) into v_n, v_list
  from public.menus
  where business_id = v_business and coalesce(is_active, true);
  if v_n > 1 then
    raise exception 'El negocio tiene % menús activos (%). Dime a cuál van.', v_n, v_list;
  end if;

  -- Área de comanda.
  select coalesce(bs.kitchen_enabled, true) into v_kitchen
  from public.business_settings bs where bs.business_id = v_business;
  v_kitchen := coalesce(v_kitchen, true);

  if v_kitchen then
    select a.id, a.code into v_area_id, v_area_code
    from public.print_areas a
    where a.business_id = v_business and a.is_active
      and (a.code in ('cocina', 'kitchen', 'kitchen_hot')
           or pg_temp.norm(a.name) in ('cocina', 'kitchen'))
    order by (a.code = 'cocina') desc, a.created_at
    limit 1;

    if v_area_id is null then
      select count(*), string_agg(format('%s (%s)', name, code), ', ') into v_n, v_list
      from public.print_areas
      where business_id = v_business and is_active
        and code not in ('cashier', 'fiscal', 'cash_close');

      if v_n = 1 then
        select id, code into v_area_id, v_area_code
        from public.print_areas
        where business_id = v_business and is_active
          and code not in ('cashier', 'fiscal', 'cash_close');
      elsif v_n = 0 then
        select a.id, a.code into v_area_id, v_area_code
        from public.print_areas a
        where a.business_id = v_business
          and (a.code in ('cocina', 'kitchen', 'kitchen_hot')
               or pg_temp.norm(a.name) in ('cocina', 'kitchen'))
        order by (a.code = 'cocina') desc, a.created_at
        limit 1;
        if v_area_id is not null then
          update public.print_areas set is_active = true where id = v_area_id;
        else
          v_area_id   := gen_random_uuid();
          v_area_code := 'cocina';
          insert into public.print_areas (id, business_id, name, code, is_active)
          values (v_area_id, v_business, 'Cocina', v_area_code, true);
        end if;
      else
        raise exception
          'Hay % áreas de comanda activas (%) y ninguna es de cocina. Dime a cuál va el pollo.',
          v_n, v_list;
      end if;
    end if;
  end if;

  -- =========================================================================
  -- 2) MENÚ Y CATEGORÍAS
  -- =========================================================================

  select id into v_menu_id
  from public.menus
  where business_id = v_business and coalesce(is_active, true)
  order by created_at limit 1;
  if v_menu_id is null then
    v_menu_id := gen_random_uuid();
    insert into public.menus (id, business_id, name, is_active)
    values (v_menu_id, v_business, 'Menú Principal', true);
  end if;

  insert into public.categories (id, business_id, name, position, is_active)
  select gen_random_uuid(), v_business, c.name, c.posicion, true
  from _mx_categorias c
  where not exists (select 1 from public.categories x
                    where x.business_id = v_business
                      and pg_temp.norm(x.name) = pg_temp.norm(c.name));

  update public.categories x set is_active = true
  from _mx_categorias c
  where x.business_id = v_business
    and pg_temp.norm(x.name) = pg_temp.norm(c.name) and not x.is_active;

  -- =========================================================================
  -- 3) PRODUCTOS
  -- =========================================================================

  update public.menu_items mi
  set price = p.price, category_id = cat.id, tax_mode = 'inclusive',
      is_active = true, is_beverage = false, position = p.posicion,
      print_area_code = v_area_code, updated_at = now()
  from _mx_productos p
  cross join lateral (
    select c.id from public.categories c
    where c.business_id = v_business and pg_temp.norm(c.name) = pg_temp.norm(p.categoria)
    order by c.is_active desc, c.created_at limit 1
  ) cat
  where mi.business_id = v_business and pg_temp.norm(mi.name) = pg_temp.norm(p.name);

  insert into public.menu_items (
    id, business_id, category_id, name, price,
    tax_mode, is_active, is_beverage, position, print_area_code
  )
  select gen_random_uuid(), v_business, cat.id, p.name, p.price,
         'inclusive', true, false, p.posicion, v_area_code
  from _mx_productos p
  cross join lateral (
    select c.id from public.categories c
    where c.business_id = v_business and pg_temp.norm(c.name) = pg_temp.norm(p.categoria)
    order by c.is_active desc, c.created_at limit 1
  ) cat
  where not exists (select 1 from public.menu_items mi
                    where mi.business_id = v_business
                      and pg_temp.norm(mi.name) = pg_temp.norm(p.name));

  drop table if exists _mx_ids;
  create temp table _mx_ids on commit drop as
  select mi.id, p.name
  from public.menu_items mi
  join _mx_productos p on pg_temp.norm(mi.name) = pg_temp.norm(p.name)
  where mi.business_id = v_business;

  drop table if exists _mx_taxes;
  create temp table _mx_taxes on commit drop as
  select v_itbis_id as tax_id
  union all
  select v_ley_id where v_con_ley;

  -- Impuestos: exactamente el juego decidido.
  delete from public.menu_item_taxes mit using _mx_ids i
  where mit.item_id = i.id and mit.tax_id not in (select tax_id from _mx_taxes);

  insert into public.menu_item_taxes (item_id, tax_id)
  select i.id, t.tax_id from _mx_ids i cross join _mx_taxes t
  where not exists (select 1 from public.menu_item_taxes x
                    where x.item_id = i.id and x.tax_id = t.tax_id);

  -- Área (N:M). Se quitan otras áreas para que no salga por dos impresoras.
  delete from public.menu_item_print_areas x using _mx_ids i
  where x.menu_item_id = i.id and x.print_area_id is distinct from v_area_id;

  if v_area_id is not null then
    insert into public.menu_item_print_areas (menu_item_id, print_area_id)
    select i.id, v_area_id from _mx_ids i
    where not exists (select 1 from public.menu_item_print_areas x
                      where x.menu_item_id = i.id and x.print_area_id = v_area_id);
  end if;

  -- Enlace al menú de la caja.
  insert into public.menu_item_links (menu_id, item_id, position)
  select v_menu_id, i.id, p.posicion
  from _mx_ids i join _mx_productos p on p.name = i.name
  where not exists (select 1 from public.menu_item_links l
                    where l.menu_id = v_menu_id and l.item_id = i.id);

  -- =========================================================================
  -- 4) ACOMPAÑAMIENTO OBLIGATORIO
  --    min = max = 1 y 'single': la POS no deja agregar el pollo sin escoger.
  -- =========================================================================

  select id into v_group_id
  from public.modifier_groups
  where business_id = v_business and pg_temp.norm(name) = pg_temp.norm(v_grupo);

  if v_group_id is null then
    v_group_id := gen_random_uuid();
    insert into public.modifier_groups (
      id, business_id, name, min_select, max_select, is_active,
      display_type, selection_mode, is_required, free_qty, max_qty_per_option, sort_order
    ) values (
      v_group_id, v_business, v_grupo, 1, 1, true,
      'single', 'modifier', true, 0, 1, 10
    );
  else
    update public.modifier_groups
    set min_select = 1, max_select = 1, is_active = true,
        display_type = 'single', is_required = true
    where id = v_group_id;
  end if;

  insert into public.modifiers (id, business_id, group_id, name, price_delta, is_active, sort_order)
  select gen_random_uuid(), v_business, v_group_id, o.name, 0, true, o.orden
  from _mx_opciones o
  where not exists (select 1 from public.modifiers m
                    where m.group_id = v_group_id
                      and pg_temp.norm(m.name) = pg_temp.norm(o.name));

  update public.modifiers m
  set is_active = true, price_delta = 0
  from _mx_opciones o
  where m.group_id = v_group_id
    and pg_temp.norm(m.name) = pg_temp.norm(o.name)
    and (not m.is_active or m.price_delta <> 0);

  insert into public.menu_item_groups (menu_item_id, group_id)
  select i.id, v_group_id from _mx_ids i
  where not exists (select 1 from public.menu_item_groups y
                    where y.menu_item_id = i.id and y.group_id = v_group_id);

  -- =========================================================================
  -- 5) VERIFICACIÓN: cualquier fallo revierte TODO.
  -- =========================================================================

  select count(*) into v_n
  from _mx_productos p
  where (select count(*) from public.menu_items mi
         where mi.business_id = v_business
           and pg_temp.norm(mi.name) = pg_temp.norm(p.name) and mi.is_active) <> 1;
  if v_n > 0 or (select count(*) from _mx_ids) <> v_esperados then
    raise exception '% productos no quedaron (o quedaron repetidos). Revertido.', v_n;
  end if;

  select count(*) into v_n
  from _mx_ids i
  join public.menu_items mi on mi.id = i.id
  join _mx_productos p on p.name = i.name
  left join public.categories c on c.id = mi.category_id
  where mi.price <> p.price or mi.tax_mode <> 'inclusive'
     or c.id is null or pg_temp.norm(c.name) <> pg_temp.norm(p.categoria);
  if v_n > 0 then
    raise exception '% productos con precio, modo de impuesto o categoría incorrectos. Revertido.', v_n;
  end if;

  select count(*) into v_n
  from _mx_ids i
  where exists (select 1 from _mx_taxes t
                where not exists (select 1 from public.menu_item_taxes x
                                  where x.item_id = i.id and x.tax_id = t.tax_id))
     or exists (select 1 from public.menu_item_taxes x
                where x.item_id = i.id and x.tax_id not in (select tax_id from _mx_taxes));
  if v_n > 0 then
    raise exception '% productos con un juego de impuestos distinto al decidido. Revertido.', v_n;
  end if;

  select count(*) into v_n
  from _mx_ids i
  join public.menu_items mi on mi.id = i.id
  where mi.print_area_code is distinct from v_area_code
     or (select count(*) from public.menu_item_print_areas x
         where x.menu_item_id = i.id) <> case when v_area_id is null then 0 else 1 end;
  if v_n > 0 then
    raise exception '% productos con el área de comanda mal. Revertido.', v_n;
  end if;

  select count(*) into v_n
  from _mx_ids i
  where not exists (select 1 from public.menu_item_links l
                    where l.menu_id = v_menu_id and l.item_id = i.id)
     or not exists (select 1 from public.menu_item_groups y
                    where y.menu_item_id = i.id and y.group_id = v_group_id);
  if v_n > 0 then
    raise exception '% productos fuera del menú o sin acompañamiento. Revertido.', v_n;
  end if;

  if (select count(*) from public.modifiers m
      join _mx_opciones o on pg_temp.norm(o.name) = pg_temp.norm(m.name)
      where m.group_id = v_group_id and m.is_active) <> (select count(*) from _mx_opciones) then
    raise exception 'El grupo % no quedó con sus opciones. Revertido.', v_grupo;
  end if;

  raise notice 'OK: % productos, Ley=%, área=%. Commit.',
    v_esperados, v_con_ley, coalesce(v_area_code, 'ninguna (cocina apagada)');
end $$;

commit;

-- ============================================================================
-- REPORTE: todas las filas deben decir ✓
-- ============================================================================

with
biz as (select 'd16497fa-4853-41e3-8566-4d0565511f37'::uuid as id),
esperados as (select count(*)::int as n from _mx_productos),
items as (
  select mi.*, p.price as precio_menu
  from public.menu_items mi
  join biz on mi.business_id = biz.id
  join _mx_productos p on pg_temp.norm(mi.name) = pg_temp.norm(p.name)
  where mi.is_active
),
itbis as (
  select t.* from public.taxes t, biz
  where t.business_id = biz.id and t.name ilike '%itbis%'
    and t.rate = 18 and coalesce(t.is_active, true)
  limit 1
),
juegos as (
  select i.id,
         coalesce((select string_agg(format('%s %s%%', t.name, t.rate), ' + ' order by t.rate desc)
                   from public.menu_item_taxes x join public.taxes t on t.id = x.tax_id
                   where x.item_id = i.id), 'SIN IMPUESTO') as juego,
         coalesce((select sum(t.rate) from public.menu_item_taxes x
                   join public.taxes t on t.id = x.tax_id where x.item_id = i.id), 0) as tasa
  from items i
),
areas as (
  select distinct x.print_area_id as id
  from public.menu_item_print_areas x join items i on i.id = x.menu_item_id
),
cocina as (
  select coalesce((select bs.kitchen_enabled from public.business_settings bs, biz
                   where bs.business_id = biz.id), true) as encendida
),
grupo as (
  select g.* from public.modifier_groups g, biz
  where g.business_id = biz.id and pg_temp.norm(g.name) = 'acompanamiento'
),
r(orden, concepto, encontrado, esperado, ok) as (
  select 1, 'Productos del menú (activos)',
         (select count(*) from items)::text, (select n from esperados)::text,
         (select count(*) from items) = (select n from esperados)
  union all
  select 2, 'Con precio distinto al menú',
         (select count(*) from items where price <> precio_menu)::text, '0',
         (select count(*) from items where price <> precio_menu) = 0
  union all
  select 3, 'Con ITBIS incluido (inclusive)',
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
         'uno solo', (select count(distinct juego) from juegos) = 1
  union all
  select 6, 'Ejemplo: 2 piezas $170',
         (select format('base %s + impuestos %s = 170',
                        round(170 / (1 + tasa / 100), 2), 170 - round(170 / (1 + tasa / 100), 2))
          from juegos j join items i on i.id = j.id
          where pg_temp.norm(i.name) = 'pollo frito 2 piezas'),
         'total 170', true
  union all
  select 7, 'Área de comanda: ' || case
            when not (select encendida from cocina) then 'ninguna (cocina apagada)'
            else coalesce((select string_agg(a.name || ' (' || a.code || ')', ', ')
                           from public.print_areas a where a.id in (select id from areas)), '—') end,
         (select count(*) from items i where exists (
            select 1 from public.menu_item_print_areas x where x.menu_item_id = i.id))::text,
         case when (select encendida from cocina) then (select n from esperados)::text else '0' end,
         case when (select encendida from cocina)
              then (select count(*) from items i where exists (
                      select 1 from public.menu_item_print_areas x where x.menu_item_id = i.id))
                   = (select n from esperados) and (select count(*) from areas) = 1
              else (select count(*) from areas) = 0 end
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
            select 1 from public.menu_item_links l where l.item_id = i.id)) = (select n from esperados)
  union all
  select 10, 'Piden acompañamiento (Tostones / Papas Fritas)',
         (select count(*) from items i where exists (
            select 1 from public.menu_item_groups y join grupo g on g.id = y.group_id
            where y.menu_item_id = i.id))::text
         || ' · opciones: ' || coalesce((select string_agg(m.name, ' / ' order by m.sort_order)
                                         from public.modifiers m join grupo g on g.id = m.group_id
                                         where m.is_active), '—'),
         (select n from esperados)::text || ', obligatorio',
         (select count(*) from items i where exists (
            select 1 from public.menu_item_groups y join grupo g on g.id = y.group_id
            where y.menu_item_id = i.id)) = (select n from esperados)
         and coalesce((select min_select = 1 and max_select = 1 and is_active from grupo), false)
  union all
  select 11, 'Impresoras en el área de la cocina',
         case when not (select encendida from cocina) then 'no aplica'
              else (select count(*) from public.print_area_printers p
                    where p.area_id in (select id from areas))::text end,
         '1 o más',
         not (select encendida from cocina)
         or (select count(*) from public.print_area_printers p
             where p.area_id in (select id from areas)) > 0
  union all
  select 12, 'Pechurina renombrada · POLLO FRITO desactivado',
         format('Pechurina=%s · POLLO FRITO activo=%s',
                (select count(*) from public.menu_items mi, biz
                 where mi.business_id = biz.id and pg_temp.norm(mi.name) = 'pechurina'),
                coalesce((select string_agg(mi.is_active::text, ',') from public.menu_items mi, biz
                          where mi.business_id = biz.id and pg_temp.norm(mi.name) = 'pollo frito'), '—')),
         'Pechurina=0 · POLLO FRITO activo=false',
         not exists (select 1 from public.menu_items mi, biz
                     where mi.business_id = biz.id and pg_temp.norm(mi.name) = 'pechurina')
         and not exists (select 1 from public.menu_items mi, biz
                         where mi.business_id = biz.id and pg_temp.norm(mi.name) = 'pollo frito'
                           and mi.is_active)
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
)
select concepto, encontrado, esperado,
       case when ok then '✓' else '✗ REVISAR' end as estado
from r
order by orden;
