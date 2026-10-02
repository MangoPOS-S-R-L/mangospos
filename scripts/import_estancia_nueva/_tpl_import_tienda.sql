-- ============================================================================
-- ESTANCIA NUEVA SPORT · TIENDA — CARGA DEL CATÁLOGO (artículos deportivos)
-- Business __BID__
--
-- Fuente: "ARTICULOS DE INVENTARIO.csv" del sistema anterior, dividido el
-- 21/09/2026 (build_estancia_nueva.py). Precios: __FUENTE_PRECIOS__.
--
-- ⚠ ARCHIVO GENERADO por build_import_tienda.py desde _tpl_import_tienda.sql.
--   No lo edites a mano: cambia el .py (o la plantilla) y regenera.
-- ============================================================================
--
-- QUÉ CARGA
--   __N_TOTAL__ artículos en __N_CATEGORIAS__ categorías (Pádel, Fútbol, Ropa y accesorios,
--   Servicios del club), todos en el menú de la caja, con ITBIS 18% INCLUIDO.
--   __N_BARCODE__ con código de barras; el código del sistema viejo va siempre en `sku`.
--   __N_CON_PRECIO__ con precio → ACTIVOS. Los demás entran INACTIVOS en RD$0 hasta que
--   tengan precio (en $0 la caja los cobraría gratis).
--   __N_INVENTARIABLES__ inventariables 1:1 con su insumo, stock en CERO y "Vender aunque
--   esté agotado". Los servicios del club (clases, alquiler, liga…) NO llevan
--   inventario.
--
-- COMANDA
--   * Cocina apagada (lo normal en una tienda): ninguna; la venta pasa directo.
--   * Cocina encendida: el área `tienda` si existe; si no, la única área
--     activa; si no hay ninguna o hay varias, ABORTA y explica.
--
-- CÓMO CORRERLO
--   Pega este archivo entero en el SQL Editor de Supabase y dale Run. La tabla
--   del final es el reporte: todas las filas deben decir ✓.
--
-- TODO O NADA / SE PUEDE RE-CORRER
--   Una transacción con verificación antes del commit. Empareja por CÓDIGO.
--   Re-correrlo actualiza precio, costo, categoría, ITBIS y código de barras;
--   activa los que estaban inactivos en $0 y ahora traen precio; no reactiva
--   lo que apagaron a mano; no toca el stock.
-- ============================================================================

begin;

create temp table _tie (
  codigo        text primary key,     -- código del sistema viejo → sku
  name          text not null,
  categoria     text not null,
  price         numeric(12,2),        -- null = sin precio todavía
  cost          numeric,
  barcode       text,
  inventariable boolean not null,
  posicion      int not null
) on commit drop;

__DATA__

create temp table _tie_categorias (
  name     text primary key,
  posicion int  not null
) on commit drop;

insert into _tie_categorias (name, posicion) values
__CATEGORIAS__;

do $$
declare
  v_business     uuid := '__BID__';
  v_total        int  := __N_TOTAL__;
  v_tax_id       uuid;
  v_menu_id      uuid;
  v_menus        int;
  v_kitchen      boolean;
  v_mode         text;
  v_area_id      uuid;
  v_area_code    text;
  v_wh_id        uuid;
  v_wh_name      text;
  v_wh_active    boolean;
  v_n            int;
  v_list         text;
  v_nuevos       int;
  v_actualizados int;
  v_insumos      int;
begin
  -- =========================================================================
  -- 1) GUARDAS — se comprueba todo ANTES de escribir una sola fila.
  -- =========================================================================

  if not exists (select 1 from public.businesses where id = v_business) then
    raise exception 'El negocio % no existe.', v_business;
  end if;

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

  if exists (select 1 from public.taxes
             where id = v_tax_id and coalesce(is_service_fee, false)) then
    raise exception
      'El ITBIS tiene is_service_fee = true: la factura lo cobraría DOS veces. '
      'Apágalo antes de cargar.';
  end if;

  select coalesce(bs.kitchen_enabled, true), coalesce(bs.inventory_mode, 'none')
    into v_kitchen, v_mode
  from public.business_settings bs
  where bs.business_id = v_business;

  if not found then
    raise exception
      'El negocio no tiene fila en business_settings. Entra una vez a Ajustes '
      'en la app y vuelve a correr.';
  end if;

  if exists (select 1 from public.business_settings
             where business_id = v_business
               and coalesce(service_fee_enabled, false)) then
    raise exception
      'business_settings.service_fee_enabled está en true: cobraría un 10%% '
      'por orden. Apágalo primero si la tienda no lo cobra.';
  end if;

  -- Ningún código de la lista apunta a VARIOS productos o insumos.
  select string_agg(format('%s (%s productos)', p.codigo, x.n), ', ')
    into v_list
  from _tie p
  cross join lateral (
    select count(*) as n
    from public.menu_items mi
    where mi.business_id = v_business
      and (mi.sku = p.codigo or mi.barcode = p.codigo
           or (p.barcode is not null and mi.barcode = p.barcode))
  ) x
  where x.n > 1;

  if v_list is not null then
    raise exception
      'Códigos de la lista que ya tienen VARIOS productos, no sé cuál '
      'actualizar: %', v_list;
  end if;

  select string_agg(format('%s (%s insumos)', p.codigo, x.n), ', ')
    into v_list
  from _tie p
  cross join lateral (
    select count(*) as n
    from public.inventory_items ii
    where ii.business_id = v_business
      and (ii.sku = p.codigo or ii.barcode = p.codigo
           or (p.barcode is not null and ii.barcode = p.barcode))
  ) x
  where x.n > 1;

  if v_list is not null then
    raise exception
      'Códigos de la lista que ya tienen VARIOS insumos, no sé cuál usar: %',
      v_list;
  end if;

  -- Menú: 0 se crea, 1 se reusa, más de 1 aborta.
  select count(*) into v_menus
  from public.menus
  where business_id = v_business and coalesce(is_active, true);

  if v_menus > 1 then
    select string_agg(name, ', ' order by created_at) into v_list
    from public.menus
    where business_id = v_business and coalesce(is_active, true);

    raise exception
      'La tienda tiene % menús activos (%). Dime a cuál van los artículos.',
      v_menus, v_list;
  end if;

  -- Bodega: la MISMA que escoge consume_inventory_from_order al vender.
  select w.id, w.name, coalesce(w.is_active, true)
    into v_wh_id, v_wh_name, v_wh_active
  from public.warehouses w
  where w.business_id = v_business
  order by w.is_main desc, w.created_at asc nulls first, w.id asc
  limit 1;

  if v_wh_id is null then
    raise exception
      'La tienda no tiene bodega. Créala en Inventario → Bodegas, márcala '
      'como principal y vuelve a correr.';
  end if;

  if not v_wh_active or v_wh_name = '__IN_TRANSIT__' then
    raise exception
      'La bodega de la que descuenta la venta es "%" (desactivada o de '
      'tránsito). Marca la bodega real como principal y vuelve a correr.',
      v_wh_name;
  end if;

  -- Área de comanda (ver encabezado).
  if v_kitchen then
    select count(*), string_agg(format('%s (%s)', name, code), ', ')
      into v_n, v_list
    from public.print_areas
    where business_id = v_business
      and is_active
      and code not in ('cashier', 'fiscal', 'cash_close');

    select id, code into v_area_id, v_area_code
    from public.print_areas
    where business_id = v_business and is_active and code = 'tienda';

    if v_area_id is null then
      if v_n = 1 then
        select id, code into v_area_id, v_area_code
        from public.print_areas
        where business_id = v_business
          and is_active
          and code not in ('cashier', 'fiscal', 'cash_close');
      elsif v_n = 0 then
        raise exception
          'Cocina está ENCENDIDA en la tienda y no hay ninguna área de comanda: '
          'cada venta fallaría al mandar a cocina. En una tienda lo normal es '
          'APAGAR Cocina (Ajustes): la venta pasa directo, sin comanda. Apágala '
          'y vuelve a correr.';
      else
        raise exception
          'Cocina está encendida y hay % áreas de comanda (%), ninguna "tienda". '
          'Apaga Cocina en Ajustes (lo normal en una tienda) o dime a cuál van.',
          v_n, v_list;
      end if;
    end if;
  end if;

  -- =========================================================================
  -- 2) MENÚ  3) CATEGORÍAS
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

  insert into public.categories (id, business_id, name, position, is_active)
  select gen_random_uuid(), v_business, c.name, c.posicion, true
  from _tie_categorias c
  where not exists (
    select 1 from public.categories x
    where x.business_id = v_business
      and lower(btrim(x.name)) = lower(c.name)
  );

  -- =========================================================================
  -- 4) ARTÍCULOS — por código. Actualiza los que existen, inserta los demás.
  -- =========================================================================

  create temp table _tie_ids (
    codigo text primary key,
    id     uuid not null,
    nuevo  boolean not null
  ) on commit drop;

  insert into _tie_ids (codigo, id, nuevo)
  select p.codigo, mi.id, false
  from _tie p
  join public.menu_items mi
    on mi.business_id = v_business
   and (mi.sku = p.codigo or mi.barcode = p.codigo
        or (p.barcode is not null and mi.barcode = p.barcode));

  select string_agg(format('%s ← %s', mi.name, z.codigos), '; ')
    into v_list
  from (
    select id, string_agg(codigo, ', ') as codigos
    from _tie_ids group by id having count(*) > 1
  ) z
  join public.menu_items mi on mi.id = z.id;

  if v_list is not null then
    raise exception
      'Productos que calzan con varios códigos de la lista a la vez: %', v_list;
  end if;

  update public.menu_items mi
  set category_id         = cat.id,
      price               = coalesce(p.price, mi.price),
      cost                = coalesce(p.cost, mi.cost),
      tax_mode            = 'inclusive',
      sku                 = p.codigo,
      barcode             = coalesce(p.barcode, mi.barcode),
      is_beverage         = false,
      is_active           = case
                              when coalesce(p.price, 0) > 0
                                   and mi.price = 0 and not mi.is_active then true
                              else mi.is_active
                            end,
      position            = p.posicion,
      print_area_code     = v_area_code,
      allow_negative_sale = true,
      updated_at          = now()
  from _tie_ids i
  join _tie p on p.codigo = i.codigo
  cross join lateral (
    select c.id from public.categories c
    where c.business_id = v_business
      and lower(btrim(c.name)) = lower(p.categoria)
    order by c.created_at
    limit 1
  ) cat
  where mi.id = i.id;
  get diagnostics v_actualizados = row_count;

  insert into public.menu_items (
    id, business_id, category_id, name, price, cost, tax_mode, sku, barcode,
    is_active, is_beverage, position, print_area_code, allow_negative_sale
  )
  select gen_random_uuid(), v_business, cat.id, p.name, coalesce(p.price, 0),
         p.cost, 'inclusive', p.codigo, p.barcode,
         coalesce(p.price, 0) > 0, false, p.posicion, v_area_code, true
  from _tie p
  cross join lateral (
    select c.id from public.categories c
    where c.business_id = v_business
      and lower(btrim(c.name)) = lower(p.categoria)
    order by c.created_at
    limit 1
  ) cat
  where not exists (select 1 from _tie_ids i where i.codigo = p.codigo);
  get diagnostics v_nuevos = row_count;

  insert into _tie_ids (codigo, id, nuevo)
  select p.codigo, mi.id, true
  from _tie p
  join public.menu_items mi
    on mi.business_id = v_business
   and mi.sku = p.codigo
  where not exists (select 1 from _tie_ids i where i.codigo = p.codigo);

  -- =========================================================================
  -- 5) ITBIS  6) ÁREA  7) MENÚ DE LA CAJA
  -- =========================================================================

  delete from public.menu_item_taxes mit
  using _tie_ids i
  where mit.item_id = i.id
    and mit.tax_id <> v_tax_id;

  insert into public.menu_item_taxes (item_id, tax_id)
  select i.id, v_tax_id
  from _tie_ids i
  where not exists (
    select 1 from public.menu_item_taxes x
    where x.item_id = i.id and x.tax_id = v_tax_id
  );

  delete from public.menu_item_print_areas x
  using _tie_ids i
  where x.menu_item_id = i.id
    and (v_area_id is null or x.print_area_id <> v_area_id);

  if v_area_id is not null then
    insert into public.menu_item_print_areas (menu_item_id, print_area_id)
    select i.id, v_area_id
    from _tie_ids i
    where not exists (
      select 1 from public.menu_item_print_areas x
      where x.menu_item_id = i.id and x.print_area_id = v_area_id
    );
  end if;

  insert into public.menu_item_links (menu_id, item_id, position)
  select v_menu_id, i.id, p.posicion
  from _tie_ids i
  join _tie p on p.codigo = i.codigo
  where not exists (
    select 1 from public.menu_item_links l
    where l.menu_id = v_menu_id and l.item_id = i.id
  );

  -- =========================================================================
  -- 8) INVENTARIO — un insumo por artículo, por CÓDIGO; stock en CERO.
  --    Los servicios no llevan. DML directo: el RPC exige auth.uid().
  -- =========================================================================

  create temp table _tie_insumo_de (
    codigo  text primary key,
    item_id uuid
  ) on commit drop;

  insert into _tie_insumo_de (codigo, item_id)
  select p.codigo,
         coalesce(
           (select mi.inventory_item_id
              from public.menu_items mi
             where mi.id = i.id),
           (select ii.id
              from public.inventory_items ii
             where ii.business_id = v_business
               and (ii.sku = p.codigo or ii.barcode = p.codigo
                    or (p.barcode is not null and ii.barcode = p.barcode))
             limit 1)
         )
  from _tie p
  join _tie_ids i on i.codigo = p.codigo
  where p.inventariable;

  insert into public.inventory_items (
    business_id, sku, barcode, name, unit, cost, is_active
  )
  select v_business, p.codigo, p.barcode, p.name, 'unidad',
         coalesce(p.cost, 0), true
  from _tie p
  join _tie_insumo_de s on s.codigo = p.codigo
  where s.item_id is null;
  get diagnostics v_insumos = row_count;

  update _tie_insumo_de s
  set item_id = ii.id
  from public.inventory_items ii
  where s.item_id is null
    and ii.business_id = v_business
    and ii.sku = s.codigo;

  update public.menu_items mi
  set inventory_item_id    = s.item_id,
      is_inventory_tracked = true
  from _tie_ids i
  join _tie_insumo_de s on s.codigo = i.codigo
  where mi.id = i.id
    and (mi.inventory_item_id is distinct from s.item_id
         or not coalesce(mi.is_inventory_tracked, false));

  if v_mode = 'none' then
    update public.business_settings
    set inventory_mode = 'basic'
    where business_id = v_business;
  end if;

  -- =========================================================================
  -- 9) VERIFICACIÓN DENTRO DE LA TRANSACCIÓN — cualquier fallo revierte TODO.
  -- =========================================================================

  select count(*) into v_n
  from _tie p
  where (select count(*) from public.menu_items mi
         where mi.business_id = v_business and mi.sku = p.codigo) <> 1;
  if v_n > 0
     or (select count(*) from _tie_ids) <> v_total
     or (select count(distinct id) from _tie_ids) <> v_total then
    raise exception '% códigos sin producto o con más de uno. Revertido.', v_n;
  end if;

  select count(*) into v_n
  from _tie_ids i
  join public.menu_items mi on mi.id = i.id
  join _tie p on p.codigo = i.codigo
  left join public.categories c on c.id = mi.category_id
  where (p.price is not null and mi.price <> p.price)
     or mi.tax_mode <> 'inclusive'
     or c.id is null
     or lower(btrim(c.name)) <> lower(p.categoria)
     or (p.barcode is not null and mi.barcode is distinct from p.barcode);
  if v_n > 0 then
    raise exception '% artículos con precio, impuesto, categoría o código de barras incorrectos. Revertido.', v_n;
  end if;

  select count(*) into v_n
  from _tie_ids i
  where not exists (select 1 from public.menu_item_taxes x
                    where x.item_id = i.id and x.tax_id = v_tax_id)
     or exists (select 1 from public.menu_item_taxes x
                where x.item_id = i.id and x.tax_id <> v_tax_id);
  if v_n > 0 then
    raise exception '% artículos sin ITBIS o con otro impuesto. Revertido.', v_n;
  end if;

  select count(*) into v_n
  from _tie_ids i
  join public.menu_items mi on mi.id = i.id
  where mi.print_area_code is distinct from v_area_code
     or (v_area_id is null and exists (
           select 1 from public.menu_item_print_areas x
           where x.menu_item_id = i.id))
     or (v_area_id is not null and (
           (select count(*) from public.menu_item_print_areas x
             where x.menu_item_id = i.id) <> 1
           or not exists (select 1 from public.menu_item_print_areas x
                          where x.menu_item_id = i.id
                            and x.print_area_id = v_area_id)));
  if v_n > 0 then
    raise exception '% artículos con el área de comanda en desacuerdo. Revertido.', v_n;
  end if;

  select count(*) into v_n
  from _tie_ids i
  where not exists (select 1 from public.menu_item_links l
                    where l.menu_id = v_menu_id and l.item_id = i.id);
  if v_n > 0 then
    raise exception '% artículos fuera del menú: no saldrían en la caja. Revertido.', v_n;
  end if;

  select count(*) into v_n
  from _tie p
  join _tie_ids i on i.codigo = p.codigo
  join public.menu_items mi on mi.id = i.id
  left join public.inventory_items ii
    on ii.id = mi.inventory_item_id and ii.business_id = v_business
  where (p.inventariable
         and (not coalesce(mi.is_inventory_tracked, false) or ii.id is null))
     or not mi.allow_negative_sale;
  if v_n > 0 then
    raise exception '% artículos inventariables sin insumo o sin "vender aunque esté agotado". Revertido.', v_n;
  end if;

  select count(*) into v_n
  from (select item_id from _tie_insumo_de
        group by item_id having count(*) > 1) z;
  if v_n > 0 then
    raise exception '% insumos compartidos por varios artículos: descontarían cruzado. Revertido.', v_n;
  end if;

  if (select inventory_mode from public.business_settings
      where business_id = v_business) not in ('basic', 'advanced') then
    raise exception 'inventory_mode no quedó en basic/advanced. Revertido.';
  end if;

  select count(*), string_agg(bc, ', ')
    into v_n, v_list
  from (
    select mi.barcode as bc
    from public.menu_items mi
    where mi.business_id = v_business
      and mi.is_active
      and nullif(btrim(mi.barcode), '') is not null
    group by mi.barcode
    having count(*) > 1
  ) z;
  if v_n > 0 then
    raise exception 'Códigos de barras repetidos en artículos activos (%). Revertido.', v_list;
  end if;

  raise notice 'OK — % artículos (% nuevos, % actualizados) · % insumos nuevos · bodega "%" · comanda: % · Commit.',
    v_total, v_nuevos, v_actualizados, v_insumos, v_wh_name,
    coalesce(v_area_code, 'ninguna (cocina apagada)');
end $$;

commit;

-- ============================================================================
-- REPORTE — todas las filas deben decir ✓
-- ============================================================================

with codigos as (
  select unnest(string_to_array(
    '__CODES__', ',')) as codigo
),
items as (
  select mi.*
  from public.menu_items mi
  join codigos c on c.codigo = mi.sku
  where mi.business_id = '__BID__'::uuid
),
itbis as (
  select t.* from public.taxes t
  where t.business_id = '__BID__'::uuid
    and t.name ilike '%itbis%' and t.rate = 18 and coalesce(t.is_active, true)
  limit 1
),
bs as (
  select * from public.business_settings
  where business_id = '__BID__'::uuid
),
r(orden, concepto, encontrado, esperado, ok) as (
  select 1, 'Artículos de la lista',
         (select count(*) from items)::text, '__N_TOTAL__',
         (select count(*) from items) = __N_TOTAL__
  union all
  select 2, 'Activos en $0 (la caja los cobra GRATIS: ponles precio)',
         (select count(*) from items where is_active and price <= 0)::text
           || ' de ' || (select count(*) filter (where is_active) from items) || ' activos',
         '0',
         (select count(*) from items where is_active and price <= 0) = 0
  union all
  select 3, 'Con precio (activos)',
         (select count(*) from items where price > 0)::text, '__N_CON_PRECIO__ o más',
         (select count(*) from items where price > 0) >= __N_CON_PRECIO__
  union all
  select 4, 'Con ITBIS incluido (inclusive)',
         (select count(*) from items where tax_mode = 'inclusive')::text, '__N_TOTAL__',
         (select count(*) from items where tax_mode = 'inclusive') = __N_TOTAL__
  union all
  select 5, 'Vinculados SOLO al ITBIS 18%',
         (select count(*) from items i
           where exists (select 1 from public.menu_item_taxes x
                         join itbis t on t.id = x.tax_id where x.item_id = i.id)
             and not exists (select 1 from public.menu_item_taxes x
                             where x.item_id = i.id
                               and x.tax_id not in (select id from itbis)))::text,
         '__N_TOTAL__',
         (select count(*) from items i
           where exists (select 1 from public.menu_item_taxes x
                         join itbis t on t.id = x.tax_id where x.item_id = i.id)
             and not exists (select 1 from public.menu_item_taxes x
                             where x.item_id = i.id
                               and x.tax_id not in (select id from itbis))) = __N_TOTAL__
  union all
  select 6, 'Enlazados al menú de la caja',
         (select count(*) from items i where exists (
            select 1 from public.menu_item_links l where l.item_id = i.id))::text,
         '__N_TOTAL__',
         (select count(*) from items i where exists (
            select 1 from public.menu_item_links l where l.item_id = i.id)) = __N_TOTAL__
  union all
  select 7, 'Comanda',
         case when (select coalesce(kitchen_enabled, true) from bs)
              then 'cocina encendida → ' || coalesce((select string_agg(distinct print_area_code, ',') from items), '—')
              else 'cocina apagada, sin comanda' end,
         'apagada, o una sola área',
         case when (select coalesce(kitchen_enabled, true) from bs)
              then (select count(distinct print_area_code) from items) = 1
              else (select count(*) from items where print_area_code is not null) = 0 end
  union all
  select 8, 'Inventariables con su insumo',
         (select count(*) from items i
           where i.is_inventory_tracked and i.inventory_item_id is not null)::text,
         '__N_INVENTARIABLES__',
         (select count(*) from items i
           where i.is_inventory_tracked and i.inventory_item_id is not null) = __N_INVENTARIABLES__
  union all
  select 9, '"Vender aunque esté agotado"',
         (select count(*) from items where allow_negative_sale)::text, '__N_TOTAL__',
         (select count(*) from items where allow_negative_sale) = __N_TOTAL__
  union all
  select 10, 'Existencia de lo cargado (arranca en 0; baja con ventas)',
         coalesce((select sum(st.quantity) from public.inventory_stock st
                    where st.item_id in (select inventory_item_id from items)), 0)::text,
         '0 o menos',
         coalesce((select sum(st.quantity) from public.inventory_stock st
                    where st.item_id in (select inventory_item_id from items)), 0) <= 0
  union all
  select 11, 'Modo de inventario',
         (select inventory_mode from bs), 'basic o advanced',
         (select inventory_mode from bs) in ('basic', 'advanced')
  union all
  select 12, 'Con código de barras',
         (select count(*) from items where nullif(btrim(barcode), '') is not null)::text,
         '__N_BARCODE__ o más',
         (select count(*) from items where nullif(btrim(barcode), '') is not null) >= __N_BARCODE__
  union all
  select 13, 'Códigos de barras repetidos (activos, toda la tienda)',
         (select count(*) from (
            select barcode from public.menu_items
            where business_id = '__BID__'::uuid
              and is_active and nullif(btrim(barcode), '') is not null
            group by barcode having count(*) > 1) z)::text,
         '0',
         (select count(*) from (
            select barcode from public.menu_items
            where business_id = '__BID__'::uuid
              and is_active and nullif(btrim(barcode), '') is not null
            group by barcode having count(*) > 1) z) = 0
  union all
  select 14, 'ITBIS se cobra en venta rápida',
         coalesce((select case when apply_on_quick then 'sí' else 'NO' end from itbis), '—'),
         'sí',
         coalesce((select apply_on_quick from itbis), false)
)
select concepto, encontrado, esperado,
       case when ok then '✓' else '✗ REVISAR' end as estado
from r
order by orden;
