-- ============================================================================
-- ESTANCIA NUEVA SPORT · CAFETERÍA — CARGA DEL CATÁLOGO
-- Business __BID__
--
-- Fuente: "ARTICULOS DE INVENTARIO.csv" del sistema anterior, dividido el
-- 21/09/2026 (build_estancia_nueva.py). Precios: __FUENTE_PRECIOS__.
--
-- ⚠ ARCHIVO GENERADO por build_import_cafeteria.py desde _tpl_import_cafeteria.sql.
--   No lo edites a mano: cambia el .py (o la plantilla) y regenera.
-- ============================================================================
--
-- QUÉ CARGA
--   __N_TOTAL__ productos en __N_CATEGORIAS__ categorías, todos en el menú de la caja,
--   con ITBIS 18% INCLUIDO en el precio. __N_BARCODE__ con código de barras; el código
--   del sistema viejo va siempre en `sku`.
--   __N_CON_PRECIO__ con precio → ACTIVOS. Los demás entran INACTIVOS y en RD$0: no salen
--   en la caja hasta que tengan precio (en un producto en $0 la caja cobraría gratis).
--   __N_INVENTARIABLES__ inventariables 1:1 (vendes 1, descuenta 1) con su insumo, todos con
--   stock en CERO y "Vender aunque esté agotado" (allow_negative_sale).
--   __N_INSUMOS__ insumos de cocina (leche, queso, salsas…): solo insumos, no se venden.
--   Comanda: Comida y Pizzas a COCINA (__N_COCINA__), todo lo demás a BAR (__N_BAR__).
--   La OFERTA 3x2 de Michelob entra inactiva y sin inventario: se configura en Ofertas.
--
-- CÓMO CORRERLO
--   Pega este archivo entero en el SQL Editor de Supabase y dale Run. La tabla
--   del final es el reporte: todas las filas deben decir ✓.
--
-- TODO O NADA
--   Una transacción. Primero comprueba todo (negocio, ITBIS, menú, bodega,
--   áreas, códigos repetidos) y antes del commit verifica producto por
--   producto. Si algo no cuadra, lanza excepción y REVIERTE ENTERO.
--
-- SE PUEDE RE-CORRER (así se cargan los precios cuando lleguen)
--   Empareja por CÓDIGO (sku o código de barras), no por nombre. El que ya
--   existe se actualiza en precio, costo, categoría, ITBIS, código de barras y
--   área; conserva el nombre. Un producto en $0 e inactivo que ahora trae
--   precio SE ACTIVA; uno con precio que apagaste en la app NO se reactiva.
--   El stock NO se toca al re-correr: solo arranca en cero la primera vez.
--   Activos en $0 (ACTIVAR_todos_cafeteria.sql, 01/10/2026) no bloquean:
--   salen como aviso ✗ en la fila 2 del reporte hasta que tengan precio.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 0) La lista, en tablas temporales que mueren con la transacción.
-- ---------------------------------------------------------------------------

create temp table _pen (
  codigo        text primary key,     -- código del sistema viejo → sku
  name          text not null,
  categoria     text not null,
  price         numeric(12,2),        -- null = todavía sin precio
  cost          numeric,              -- null si el sistema viejo no lo tenía
  barcode       text,                 -- null si el código no es GTIN
  is_bev        boolean not null,
  vendible      boolean not null,     -- false = la OFERTA: nunca se activa
  inventariable boolean not null,
  area          text not null check (area in ('bar', 'cocina')),
  posicion      int not null
) on commit drop;

__DATA__

create temp table _pen_insumos (
  codigo  text primary key,
  name    text not null,
  cost    numeric,
  barcode text
) on commit drop;

insert into _pen_insumos (codigo, name, cost, barcode) values
__INSUMOS__;

create temp table _pen_categorias (
  name     text primary key,
  posicion int  not null
) on commit drop;

insert into _pen_categorias (name, posicion) values
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
  v_bar_id       uuid;
  v_cocina_id    uuid;
  v_wh_id        uuid;
  v_wh_name      text;
  v_wh_active    boolean;
  v_n            int;
  v_list         text;
  v_nuevos       int;
  v_actualizados int;
  v_insumos      int;
  v_cocina_ins   int;
begin
  -- =========================================================================
  -- 1) GUARDAS — se comprueba todo ANTES de escribir una sola fila.
  -- =========================================================================

  -- 1a) El negocio existe.
  if not exists (select 1 from public.businesses where id = v_business) then
    raise exception 'El negocio % no existe.', v_business;
  end if;

  -- 1b) Un ITBIS 18%% activo, y uno solo.
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
      'Apágalo antes de cargar.';
  end if;

  -- 1d) Ajustes del negocio: la fila existe y no hay propina por orden.
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
      'por orden. Apágalo primero si el negocio no lo cobra.';
  end if;

  -- 1e) Ningún código de la lista apunta a VARIOS productos o insumos: no
  --     sabría cuál actualizar.
  select string_agg(format('%s (%s productos)', p.codigo, x.n), ', ')
    into v_list
  from _pen p
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

  select string_agg(format('%s (%s insumos)', c.codigo, x.n), ', ')
    into v_list
  from (select codigo, barcode from _pen
        union all
        select codigo, barcode from _pen_insumos) c
  cross join lateral (
    select count(*) as n
    from public.inventory_items ii
    where ii.business_id = v_business
      and (ii.sku = c.codigo or ii.barcode = c.codigo
           or (c.barcode is not null and ii.barcode = c.barcode))
  ) x
  where x.n > 1;

  if v_list is not null then
    raise exception
      'Códigos de la lista que ya tienen VARIOS insumos, no sé cuál usar: %',
      v_list;
  end if;

  -- 1f) Menú: 0 se crea, 1 se reusa, más de 1 aborta.
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

  -- 1g) Bodega: la MISMA que escoge consume_inventory_from_order al vender
  --     (mismo ORDER BY). Sin ella la venta no descuenta nada.
  select w.id, w.name, coalesce(w.is_active, true)
    into v_wh_id, v_wh_name, v_wh_active
  from public.warehouses w
  where w.business_id = v_business
  order by w.is_main desc, w.created_at asc nulls first, w.id asc
  limit 1;

  if v_wh_id is null then
    raise exception
      'El negocio no tiene bodega. Créala en Inventario → Bodegas, márcala '
      'como principal y vuelve a correr.';
  end if;

  if not v_wh_active or v_wh_name = '__IN_TRANSIT__' then
    raise exception
      'La bodega de la que descuenta la venta es "%" (desactivada o de '
      'tránsito). Marca la bodega real como principal y vuelve a correr.',
      v_wh_name;
  end if;

  -- 1h) Áreas de comanda. Con cocina encendida hacen falta las DOS: `bar` y
  --     `cocina`. Con cocina apagada la venta pasa directo, sin comanda.
  if v_kitchen then
    select id into v_bar_id from public.print_areas
     where business_id = v_business and is_active and code = 'bar';
    select id into v_cocina_id from public.print_areas
     where business_id = v_business and is_active and code = 'cocina';

    if v_bar_id is null or v_cocina_id is null then
      select string_agg(format('%s (%s)', name, code), ', ')
        into v_list
      from public.print_areas
      where business_id = v_business
        and is_active
        and code not in ('cashier', 'fiscal', 'cash_close');

      raise exception
        'Cocina está encendida y falta el área de comanda %: los productos '
        'van a BAR (bar) y la comida a COCINA (cocina). Áreas que hay: %.',
        case when v_bar_id is null and v_cocina_id is null then '"bar" y "cocina"'
             when v_bar_id is null then '"bar"' else '"cocina"' end,
        coalesce(v_list, 'ninguna');
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
  -- 3) CATEGORÍAS — crea las que falten; las que ya existen se respetan.
  -- =========================================================================

  insert into public.categories (id, business_id, name, position, is_active)
  select gen_random_uuid(), v_business, c.name, c.posicion, true
  from _pen_categorias c
  where not exists (
    select 1 from public.categories x
    where x.business_id = v_business
      and lower(btrim(x.name)) = lower(c.name)
  );

  -- =========================================================================
  -- 4) PRODUCTOS — por código. Actualiza los que existen, inserta los demás.
  -- =========================================================================

  create temp table _pen_ids (
    codigo text primary key,
    id     uuid not null,
    nuevo  boolean not null
  ) on commit drop;

  insert into _pen_ids (codigo, id, nuevo)
  select p.codigo, mi.id, false
  from _pen p
  join public.menu_items mi
    on mi.business_id = v_business
   and (mi.sku = p.codigo or mi.barcode = p.codigo
        or (p.barcode is not null and mi.barcode = p.barcode));

  -- Un mismo producto calzando con DOS códigos de la lista: no sé cuál es.
  select string_agg(format('%s ← %s', mi.name, z.codigos), '; ')
    into v_list
  from (
    select id, string_agg(codigo, ', ') as codigos
    from _pen_ids group by id having count(*) > 1
  ) z
  join public.menu_items mi on mi.id = z.id;

  if v_list is not null then
    raise exception
      'Productos que calzan con varios códigos de la lista a la vez: %', v_list;
  end if;

  -- is_active: la OFERTA siempre apagada; uno que esperaba precio (en $0 e
  -- inactivo) se activa cuando la lista se lo trae; lo demás queda como esté
  -- (no se reactiva lo que apagaron a mano). mi.price/mi.is_active en el CASE
  -- son los valores de ANTES del update.
  update public.menu_items mi
  set category_id         = cat.id,
      price               = coalesce(p.price, mi.price),
      cost                = coalesce(p.cost, mi.cost),
      tax_mode            = 'inclusive',
      sku                 = p.codigo,
      barcode             = coalesce(p.barcode, mi.barcode),
      is_beverage         = p.is_bev,
      is_active           = case
                              when not p.vendible then false
                              when coalesce(p.price, 0) > 0
                                   and mi.price = 0 and not mi.is_active then true
                              else mi.is_active
                            end,
      position            = p.posicion,
      print_area_code     = case when v_kitchen then p.area end,
      allow_negative_sale = true,
      updated_at          = now()
  from _pen_ids i
  join _pen p on p.codigo = i.codigo
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
         p.vendible and coalesce(p.price, 0) > 0, p.is_bev, p.posicion,
         case when v_kitchen then p.area end, true
  from _pen p
  cross join lateral (
    select c.id from public.categories c
    where c.business_id = v_business
      and lower(btrim(c.name)) = lower(p.categoria)
    order by c.created_at
    limit 1
  ) cat
  where not exists (select 1 from _pen_ids i where i.codigo = p.codigo);
  get diagnostics v_nuevos = row_count;

  insert into _pen_ids (codigo, id, nuevo)
  select p.codigo, mi.id, true
  from _pen p
  join public.menu_items mi
    on mi.business_id = v_business
   and mi.sku = p.codigo
  where not exists (select 1 from _pen_ids i where i.codigo = p.codigo);

  -- =========================================================================
  -- 5) IMPUESTOS — exactamente el ITBIS. Sin la fila en menu_item_taxes la
  --    factura sale con ITBIS 0.00; con otro impuesto, cobra de más.
  -- =========================================================================

  delete from public.menu_item_taxes mit
  using _pen_ids i
  where mit.item_id = i.id
    and mit.tax_id <> v_tax_id;

  insert into public.menu_item_taxes (item_id, tax_id)
  select i.id, v_tax_id
  from _pen_ids i
  where not exists (
    select 1 from public.menu_item_taxes x
    where x.item_id = i.id and x.tax_id = v_tax_id
  );

  -- =========================================================================
  -- 6) ÁREA DE COMANDA (N:M). El legacy (print_area_code) ya quedó en el
  --    paso 4. Se borra cualquier otra área para no imprimir por DOS lados.
  -- =========================================================================

  delete from public.menu_item_print_areas x
  using _pen_ids i
  join _pen p on p.codigo = i.codigo
  where x.menu_item_id = i.id
    and (not v_kitchen
         or x.print_area_id <> case p.area when 'cocina' then v_cocina_id
                                           else v_bar_id end);

  if v_kitchen then
    insert into public.menu_item_print_areas (menu_item_id, print_area_id)
    select i.id, case p.area when 'cocina' then v_cocina_id else v_bar_id end
    from _pen_ids i
    join _pen p on p.codigo = i.codigo
    where not exists (
      select 1 from public.menu_item_print_areas x
      where x.menu_item_id = i.id
        and x.print_area_id = case p.area when 'cocina' then v_cocina_id
                                          else v_bar_id end
    );
  end if;

  -- =========================================================================
  -- 7) ENLACE AL MENÚ — sin esto el producto no aparece en la caja.
  -- =========================================================================

  insert into public.menu_item_links (menu_id, item_id, position)
  select v_menu_id, i.id, p.posicion
  from _pen_ids i
  join _pen p on p.codigo = i.codigo
  where not exists (
    select 1 from public.menu_item_links l
    where l.menu_id = v_menu_id and l.item_id = i.id
  );

  -- =========================================================================
  -- 8) INVENTARIO — un insumo por producto, emparejado por CÓDIGO (por
  --    nombre se cruzarían los descuentos). Stock en CERO: no se registra
  --    ninguna existencia inicial.
  --    DML directo y no fn_menu_item_set_inventory_tracked: esa función exige
  --    auth.uid() con rol, y desde el SQL Editor es null (INSUFFICIENT_ROLE).
  -- =========================================================================

  create temp table _pen_insumo_de (
    codigo  text primary key,
    item_id uuid
  ) on commit drop;

  -- 8a) El insumo que el producto ya tenga enlazado, o uno que calce por código.
  insert into _pen_insumo_de (codigo, item_id)
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
  from _pen p
  join _pen_ids i on i.codigo = p.codigo
  where p.inventariable;

  -- 8b) Los que faltan se crean, con el mismo nombre que el producto.
  insert into public.inventory_items (
    business_id, sku, barcode, name, unit, cost, is_active
  )
  select v_business, p.codigo, p.barcode, p.name, 'unidad',
         coalesce(p.cost, 0), true
  from _pen p
  join _pen_insumo_de s on s.codigo = p.codigo
  where s.item_id is null;
  get diagnostics v_insumos = row_count;

  update _pen_insumo_de s
  set item_id = ii.id
  from public.inventory_items ii
  where s.item_id is null
    and ii.business_id = v_business
    and ii.sku = s.codigo;

  -- 8c) Link directo + tracking.
  update public.menu_items mi
  set inventory_item_id    = s.item_id,
      is_inventory_tracked = true
  from _pen_ids i
  join _pen_insumo_de s on s.codigo = i.codigo
  where mi.id = i.id
    and (mi.inventory_item_id is distinct from s.item_id
         or not coalesce(mi.is_inventory_tracked, false));

  -- 8d) Insumos de cocina (no se venden): solo la ficha, en cero.
  insert into public.inventory_items (
    business_id, sku, barcode, name, unit, cost, is_active
  )
  select v_business, s.codigo, s.barcode, s.name, 'unidad',
         coalesce(s.cost, 0), true
  from _pen_insumos s
  where not exists (
    select 1 from public.inventory_items ii
    where ii.business_id = v_business
      and (ii.sku = s.codigo or ii.barcode = s.codigo
           or (s.barcode is not null and ii.barcode = s.barcode))
  );
  get diagnostics v_cocina_ins = row_count;

  -- 8e) Encender el motor: en 'none' la venta no descuenta nada.
  if v_mode = 'none' then
    update public.business_settings
    set inventory_mode = 'basic'
    where business_id = v_business;
  end if;

  -- =========================================================================
  -- 9) VERIFICACIÓN DENTRO DE LA TRANSACCIÓN — cualquier fallo revierte TODO.
  -- =========================================================================

  -- 9a) Cada código con exactamente un producto.
  select count(*) into v_n
  from _pen p
  where (select count(*) from public.menu_items mi
         where mi.business_id = v_business and mi.sku = p.codigo) <> 1;
  if v_n > 0
     or (select count(*) from _pen_ids) <> v_total
     or (select count(distinct id) from _pen_ids) <> v_total then
    raise exception '% códigos sin producto o con más de uno. Revertido.', v_n;
  end if;

  -- 9b) Precio (si la lista lo trae), ITBIS incluido, categoría y código de barras.
  select count(*) into v_n
  from _pen_ids i
  join public.menu_items mi on mi.id = i.id
  join _pen p on p.codigo = i.codigo
  left join public.categories c on c.id = mi.category_id
  where (p.price is not null and mi.price <> p.price)
     or mi.tax_mode <> 'inclusive'
     or c.id is null
     or lower(btrim(c.name)) <> lower(p.categoria)
     or (p.barcode is not null and mi.barcode is distinct from p.barcode);
  if v_n > 0 then
    raise exception '% productos con precio, impuesto, categoría o código de barras incorrectos. Revertido.', v_n;
  end if;

  -- 9c) La oferta apagada. Los activos en $0 NO abortan: el dueño decidió
  --     (01/10/2026) activar todo antes de tener precios, y una carga de
  --     precios parcial no puede quedar bloqueada por eso. Salen como aviso
  --     en la fila 2 del reporte.
  select count(*), string_agg(mi.name, ', ')
    into v_n, v_list
  from _pen_ids i
  join public.menu_items mi on mi.id = i.id
  join _pen p on p.codigo = i.codigo
  where mi.is_active and not p.vendible;
  if v_n > 0 then
    raise exception '% productos que deben estar apagados siguen activos (%). Revertido.', v_n, v_list;
  end if;

  -- 9d) Exactamente el ITBIS.
  select count(*) into v_n
  from _pen_ids i
  where not exists (select 1 from public.menu_item_taxes x
                    where x.item_id = i.id and x.tax_id = v_tax_id)
     or exists (select 1 from public.menu_item_taxes x
                where x.item_id = i.id and x.tax_id <> v_tax_id);
  if v_n > 0 then
    raise exception '% productos sin ITBIS o con otro impuesto. Revertido.', v_n;
  end if;

  -- 9e) Área: legacy y N:M de acuerdo, cada uno en la suya.
  select count(*) into v_n
  from _pen_ids i
  join public.menu_items mi on mi.id = i.id
  join _pen p on p.codigo = i.codigo
  where mi.print_area_code is distinct from case when v_kitchen then p.area end
     or (not v_kitchen and exists (
           select 1 from public.menu_item_print_areas x
           where x.menu_item_id = i.id))
     or (v_kitchen and (
           (select count(*) from public.menu_item_print_areas x
             where x.menu_item_id = i.id) <> 1
           or not exists (
             select 1 from public.menu_item_print_areas x
             where x.menu_item_id = i.id
               and x.print_area_id = case p.area when 'cocina' then v_cocina_id
                                                 else v_bar_id end)));
  if v_n > 0 then
    raise exception '% productos con el área de comanda equivocada. Revertido.', v_n;
  end if;

  -- 9f) Todos en el menú de la caja.
  select count(*) into v_n
  from _pen_ids i
  where not exists (select 1 from public.menu_item_links l
                    where l.menu_id = v_menu_id and l.item_id = i.id);
  if v_n > 0 then
    raise exception '% productos fuera del menú: no saldrían en la caja. Revertido.', v_n;
  end if;

  -- 9g) Inventariables enlazados a un insumo del negocio, y todos vendibles
  --     aunque estén en cero.
  select count(*) into v_n
  from _pen p
  join _pen_ids i on i.codigo = p.codigo
  join public.menu_items mi on mi.id = i.id
  left join public.inventory_items ii
    on ii.id = mi.inventory_item_id and ii.business_id = v_business
  where (p.inventariable
         and (not coalesce(mi.is_inventory_tracked, false) or ii.id is null))
     or not mi.allow_negative_sale;
  if v_n > 0 then
    raise exception '% productos inventariables sin insumo o sin "vender aunque esté agotado". Revertido.', v_n;
  end if;

  -- 9h) Ningún insumo compartido por dos productos de la lista.
  select count(*) into v_n
  from (select item_id from _pen_insumo_de
        group by item_id having count(*) > 1) z;
  if v_n > 0 then
    raise exception '% insumos compartidos por varios productos: descontarían cruzado. Revertido.', v_n;
  end if;

  -- 9i) Los insumos de cocina, uno por código.
  select count(*) into v_n
  from _pen_insumos s
  where (select count(*) from public.inventory_items ii
         where ii.business_id = v_business
           and (ii.sku = s.codigo or ii.barcode = s.codigo)) <> 1;
  if v_n > 0 then
    raise exception '% insumos de cocina sin ficha o repetidos. Revertido.', v_n;
  end if;

  -- 9j) El motor de inventario encendido.
  if (select inventory_mode from public.business_settings
      where business_id = v_business) not in ('basic', 'advanced') then
    raise exception 'inventory_mode no quedó en basic/advanced. Revertido.';
  end if;

  -- 9k) Ningún código de barras repetido en productos activos del negocio:
  --     la pistola traería el producto equivocado.
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
    raise exception 'Códigos de barras repetidos en productos activos (%). Revertido.', v_list;
  end if;

  raise notice 'OK — % productos (% nuevos, % actualizados) · % insumos de productos y % de cocina nuevos · bodega "%" · Commit.',
    v_total, v_nuevos, v_actualizados, v_insumos, v_cocina_ins, v_wh_name;
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
ins_codigos as (
  select unnest(string_to_array('__INS_CODES__', ',')) as codigo
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
area_de as (
  select x.menu_item_id, a.code
  from public.menu_item_print_areas x
  join public.print_areas a on a.id = x.print_area_id
  join items i on i.id = x.menu_item_id
),
r(orden, concepto, encontrado, esperado, ok) as (
  select 1, 'Productos de la lista',
         (select count(*) from items)::text, '__N_TOTAL__',
         (select count(*) from items) = __N_TOTAL__
  union all
  select 2, 'Activos en $0 (la caja los cobra GRATIS: ponles precio)',
         (select count(*) from items where is_active and price <= 0)::text
           || ' de ' || (select count(*) filter (where is_active) from items) || ' activos',
         '0',
         (select count(*) from items where is_active and price <= 0) = 0
  union all
  select 3, 'Con precio',
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
  select 7, 'Comanda a COCINA / BAR',
         (select count(*) filter (where code = 'cocina') || ' / ' ||
                 count(*) filter (where code = 'bar') from area_de),
         case when (select coalesce(kitchen_enabled, true) from bs)
              then '__N_COCINA__ / __N_BAR__' else '0 / 0 (cocina apagada)' end,
         case when (select coalesce(kitchen_enabled, true) from bs)
              then (select count(*) filter (where code = 'cocina') from area_de) = __N_COCINA__
               and (select count(*) filter (where code = 'bar') from area_de) = __N_BAR__
              else (select count(*) from area_de) = 0 end
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
  select 10, 'Insumos de cocina',
         (select count(*) from public.inventory_items ii
           join ins_codigos c on c.codigo = ii.sku
           where ii.business_id = '__BID__'::uuid)::text, '__N_INSUMOS__',
         (select count(*) from public.inventory_items ii
           join ins_codigos c on c.codigo = ii.sku
           where ii.business_id = '__BID__'::uuid) = __N_INSUMOS__
  union all
  select 11, 'Existencia de lo cargado (arranca en 0; baja con ventas)',
         coalesce((select sum(st.quantity)
                     from public.inventory_stock st
                    where st.item_id in (select inventory_item_id from items)
                       or st.item_id in (select ii.id from public.inventory_items ii
                                          join ins_codigos c on c.codigo = ii.sku
                                         where ii.business_id = '__BID__'::uuid)), 0)::text,
         '0 o menos',
         coalesce((select sum(st.quantity)
                     from public.inventory_stock st
                    where st.item_id in (select inventory_item_id from items)
                       or st.item_id in (select ii.id from public.inventory_items ii
                                          join ins_codigos c on c.codigo = ii.sku
                                         where ii.business_id = '__BID__'::uuid)), 0) <= 0
  union all
  select 12, 'Modo de inventario',
         (select inventory_mode from bs), 'basic o advanced',
         (select inventory_mode from bs) in ('basic', 'advanced')
  union all
  select 13, 'Con código de barras',
         (select count(*) from items where nullif(btrim(barcode), '') is not null)::text,
         '__N_BARCODE__ o más',
         (select count(*) from items where nullif(btrim(barcode), '') is not null) >= __N_BARCODE__
  union all
  select 14, 'Códigos de barras repetidos (activos, todo el negocio)',
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
  select 15, 'ITBIS se cobra en venta rápida',
         coalesce((select case when apply_on_quick then 'sí' else 'NO' end from itbis), '—'),
         'sí',
         coalesce((select apply_on_quick from itbis), false)
  union all
  select 16, 'Impresoras en BAR / COCINA',
         case when not (select coalesce(kitchen_enabled, true) from bs) then 'no aplica'
              else (select count(*) from public.print_area_printers p
                      join public.print_areas a on a.id = p.area_id
                     where a.business_id = '__BID__'::uuid and a.code = 'bar')
                   || ' / ' ||
                   (select count(*) from public.print_area_printers p
                      join public.print_areas a on a.id = p.area_id
                     where a.business_id = '__BID__'::uuid and a.code = 'cocina') end,
         '1 o más en cada una',
         not (select coalesce(kitchen_enabled, true) from bs)
         or ((select count(*) from public.print_area_printers p
                join public.print_areas a on a.id = p.area_id
               where a.business_id = '__BID__'::uuid and a.code = 'bar') > 0
             and (select count(*) from public.print_area_printers p
                    join public.print_areas a on a.id = p.area_id
                   where a.business_id = '__BID__'::uuid and a.code = 'cocina') > 0)
)
select concepto, encontrado, esperado,
       case when ok then '✓' else '✗ REVISAR' end as estado
from r
order by orden;
