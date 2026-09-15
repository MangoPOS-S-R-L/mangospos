-- ============================================================================
-- 007 BAR & SNACK, SRL — CARGA COMPLETA DEL CATÁLOGO
-- Business 3c5c3b8e-28e6-45f0-8dc7-85e3efe8d30c
--
-- Fuente: "PRODUCTOS 007.pdf", listado de artículos del sistema anterior
-- (14/09/2026 18:29, __N_TOTAL__ artículos).
--
-- ⚠ ARCHIVO GENERADO por build_import_3c5c3b8e.py desde _tpl_import.sql.
--   No lo edites a mano: cambia el .py (o la plantilla) y regenera.
-- ============================================================================
--
-- QUÉ CARGA
--   __N_TOTAL__ productos en __N_CATEGORIAS__ categorías: __N_ACTIVOS__ activos y __N_INACTIVOS__ inactivos.
--   __N_BARCODE__ con código de barras. Todos llevan el código del listado en `sku`,
--   que la pistola también lee.
--   __N_INVENTARIABLES__ inventariables. __N_STOCK__ con existencia inicial: __UNIDADES__ unidades,
--   RD$__VALOR__ a costo.
--
-- CÓMO CORRERLO
--   Corre antes 00_diagnostico.sql. Después pega este archivo entero en el SQL
--   Editor de Supabase y dale Run. La tabla del final es el reporte: todas las
--   filas deben decir ✓.
--
-- TODO O NADA
--   Va en UNA transacción. Primero comprueba todo (negocio, ITBIS, Ley, menú,
--   bodega, área, códigos repetidos) y, antes del commit, verifica los
--   __N_TOTAL__ uno por uno. Si algo no cuadra, lanza excepción y REVIERTE ENTERO.
--
-- SE PUEDE RE-CORRER
--   Empareja por CÓDIGO del listado (sku o código de barras), no por nombre:
--   el listado trae 8 nombres repetidos con códigos distintos.
--   El producto que ya existe se actualiza en precio, costo, categoría, ITBIS,
--   código de barras y área. Conserva el nombre y no se reactiva si lo apagaste
--   en la app. El que falta se inserta.
--   La existencia inicial entra UNA sola vez por insumo: correrlo de nuevo no
--   la vuelve a sumar.
--
-- DECISIONES DEL DUEÑO (15/09/2026)
--   * ITBIS 18% INCLUIDO en el precio (tax_mode = 'inclusive'), sin Ley 10%.
--     Trident Menta a $30 = base 25.42 + ITBIS 4.58. menu_item_taxes es la
--     ÚNICA fuente del impuesto: sin la fila, la factura sale con ITBIS 0.00.
--   * Inventario 1:1 con link directo (vendes 1, descuenta 1), sin recetas.
--     La existencia positiva del listado entra como movimiento 'purchase' con
--     reference_type 'initial_stock' en la bodega de la que descuenta la venta.
--     Los 39 negativos entran en 0: hay que contarlos.
--     allow_negative_sale = true: 608 productos arrancan en 0 y el conteo del
--     listado no es confiable. Que el sistema no los esconda al venderlos.
--   * 6 renglones que no son mercancía entran INACTIVOS y sin inventario:
--     RENTA DE LOCAL, BOTELLAS VACIAS, EMBUDO USO INTERNO, REFRIGERIO,JUGOS,
--     AMPICILLIN y SANTA CXAROLINA MERLOT RESERVA (precio 0).
--
-- ÁREA DE COMANDA — cómo la escoge el script
--   * Cocina apagada (business_settings.kitchen_enabled = false, el preset de
--     tienda): NINGUNA. La venta pasa directo a "listo" sin comanda.
--   * Cocina encendida: el área `bar`/`barra` si existe; si no, la única área
--     activa; si no hay ninguna o hay varias, ABORTA y explica.
--   Se escriben los DOS mecanismos (menu_item_print_areas y el legacy
--   print_area_code) para que no queden en desacuerdo.
--
-- MENÚ
--   La caja filtra por menú (menu_item_links). Sin menú se crea "Menú
--   Principal"; con uno se reusa; con más de uno, ABORTA.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 0) El listado, en tablas temporales que mueren con la transacción.
-- ---------------------------------------------------------------------------

create temp table _p007 (
  codigo        text primary key,     -- "Articulo" del listado
  name          text not null,
  categoria     text not null,
  price         numeric(12,2) not null,
  cost          numeric,              -- null si el listado dice 0.0000
  qty           numeric not null,     -- existencia inicial (negativos → 0)
  qty_listado   numeric not null,     -- lo que dice el listado, tal cual
  barcode       text,                 -- null si el código no es GTIN
  is_bev        boolean not null,
  activo        boolean not null,
  inventariable boolean not null,
  posicion      int not null
) on commit drop;

__DATA__

create temp table _p007_categorias (
  name     text primary key,
  posicion int  not null
) on commit drop;

insert into _p007_categorias (name, posicion) values
__CATEGORIAS__;

do $$
declare
  v_business     uuid := '3c5c3b8e-28e6-45f0-8dc7-85e3efe8d30c';
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
  v_movs         int;
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
      'por orden que este negocio no cobra. Apágalo primero.';
  end if;

  -- 1e) Ningún código del listado apunta a VARIOS productos o insumos: no
  --     sabría cuál actualizar.
  select string_agg(format('%s (%s productos)', p.codigo, x.n), ', ')
    into v_list
  from _p007 p
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
      'Códigos del listado que ya tienen VARIOS productos, no sé cuál '
      'actualizar: %', v_list;
  end if;

  select string_agg(format('%s (%s insumos)', p.codigo, x.n), ', ')
    into v_list
  from _p007 p
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
      'Códigos del listado que ya tienen VARIOS insumos, no sé cuál usar: %',
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
  --     (mismo ORDER BY). Si la existencia entra en otra, la venta descuenta
  --     de una bodega vacía.
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

  -- 1h) Área de comanda (ver encabezado).
  if v_kitchen then
    select count(*), string_agg(format('%s (%s)', name, code), ', ')
      into v_n, v_list
    from public.print_areas
    where business_id = v_business
      and is_active
      and code not in ('cashier', 'fiscal', 'cash_close');

    select id, code into v_area_id, v_area_code
    from public.print_areas
    where business_id = v_business
      and is_active
      and code in ('bar', 'barra')
    order by case code when 'bar' then 0 else 1 end
    limit 1;

    if v_area_id is null then
      if v_n = 1 then
        select id, code into v_area_id, v_area_code
        from public.print_areas
        where business_id = v_business
          and is_active
          and code not in ('cashier', 'fiscal', 'cash_close');
      elsif v_n = 0 then
        raise exception
          'Cocina está ENCENDIDA (kitchen_enabled) y no hay ninguna área de '
          'comanda: cada venta fallaría al mandar a cocina. Si es una tienda, '
          'apaga Cocina en Ajustes y vuelve a correr (los productos pasan '
          'directo, sin comanda). Si sí quieren comanda, crea el área "Barra" '
          'en Ajustes → Impresoras.';
      else
        raise exception
          'Cocina está encendida y hay % áreas de comanda activas (%), '
          'ninguna "bar"/"barra". Dime a cuál van los productos.', v_n, v_list;
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
  -- 3) CATEGORÍAS — crea las que falten; las que ya existen se respetan.
  -- =========================================================================

  insert into public.categories (id, business_id, name, position, is_active)
  select gen_random_uuid(), v_business, c.name, c.posicion, true
  from _p007_categorias c
  where not exists (
    select 1 from public.categories x
    where x.business_id = v_business
      and lower(btrim(x.name)) = lower(c.name)
  );

  -- =========================================================================
  -- 4) PRODUCTOS — por código. Actualiza los que existen, inserta los demás.
  -- =========================================================================

  create temp table _p007_ids (
    codigo text primary key,
    id     uuid not null,
    nuevo  boolean not null
  ) on commit drop;

  insert into _p007_ids (codigo, id, nuevo)
  select p.codigo, mi.id, false
  from _p007 p
  join public.menu_items mi
    on mi.business_id = v_business
   and (mi.sku = p.codigo or mi.barcode = p.codigo
        or (p.barcode is not null and mi.barcode = p.barcode));

  -- Un mismo producto calzando con DOS códigos del listado: no sé cuál es.
  select string_agg(format('%s ← %s', mi.name, z.codigos), '; ')
    into v_list
  from (
    select id, string_agg(codigo, ', ') as codigos
    from _p007_ids group by id having count(*) > 1
  ) z
  join public.menu_items mi on mi.id = z.id;

  if v_list is not null then
    raise exception
      'Productos que calzan con varios códigos del listado a la vez: %', v_list;
  end if;

  update public.menu_items mi
  set category_id         = cat.id,
      price               = p.price,
      cost                = p.cost,
      tax_mode            = 'inclusive',
      sku                 = p.codigo,
      barcode             = coalesce(p.barcode, mi.barcode),
      is_beverage         = p.is_bev,
      is_active           = case when p.activo then mi.is_active else false end,
      position            = p.posicion,
      print_area_code     = v_area_code,
      allow_negative_sale = true,
      updated_at          = now()
  from _p007_ids i
  join _p007 p on p.codigo = i.codigo
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
  select gen_random_uuid(), v_business, cat.id, p.name, p.price, p.cost,
         'inclusive', p.codigo, p.barcode, p.activo, p.is_bev, p.posicion,
         v_area_code, true
  from _p007 p
  cross join lateral (
    select c.id from public.categories c
    where c.business_id = v_business
      and lower(btrim(c.name)) = lower(p.categoria)
    order by c.created_at
    limit 1
  ) cat
  where not exists (select 1 from _p007_ids i where i.codigo = p.codigo);
  get diagnostics v_nuevos = row_count;

  insert into _p007_ids (codigo, id, nuevo)
  select p.codigo, mi.id, true
  from _p007 p
  join public.menu_items mi
    on mi.business_id = v_business
   and mi.sku = p.codigo
  where not exists (select 1 from _p007_ids i where i.codigo = p.codigo);

  -- =========================================================================
  -- 5) IMPUESTOS — exactamente el ITBIS. Otro impuesto vinculado (una Ley de
  --    antes) se quita: este negocio no la cobra.
  -- =========================================================================

  delete from public.menu_item_taxes mit
  using _p007_ids i
  where mit.item_id = i.id
    and mit.tax_id <> v_tax_id;

  insert into public.menu_item_taxes (item_id, tax_id)
  select i.id, v_tax_id
  from _p007_ids i
  where not exists (
    select 1 from public.menu_item_taxes x
    where x.item_id = i.id and x.tax_id = v_tax_id
  );

  -- =========================================================================
  -- 6) ÁREA DE COMANDA (N:M). El legacy ya quedó escrito en el paso 4.
  --    Sin área (cocina apagada) se borran las asignaciones que hubiera; con
  --    área, se borran las de otras áreas para no imprimir por DOS lados.
  -- =========================================================================

  delete from public.menu_item_print_areas x
  using _p007_ids i
  where x.menu_item_id = i.id
    and (v_area_id is null or x.print_area_id <> v_area_id);

  if v_area_id is not null then
    insert into public.menu_item_print_areas (menu_item_id, print_area_id)
    select i.id, v_area_id
    from _p007_ids i
    where not exists (
      select 1 from public.menu_item_print_areas x
      where x.menu_item_id = i.id and x.print_area_id = v_area_id
    );
  end if;

  -- =========================================================================
  -- 7) ENLACE AL MENÚ — sin esto el producto no aparece en la caja.
  -- =========================================================================

  insert into public.menu_item_links (menu_id, item_id, position)
  select v_menu_id, i.id, p.posicion
  from _p007_ids i
  join _p007 p on p.codigo = i.codigo
  where not exists (
    select 1 from public.menu_item_links l
    where l.menu_id = v_menu_id and l.item_id = i.id
  );

  -- =========================================================================
  -- 8) INVENTARIO — un insumo por producto, emparejado por CÓDIGO.
  --    Por nombre no: hay 8 nombres repetidos y cruzarían los descuentos
  --    (vender un MUSCLE MILK descontaría el otro).
  --    DML directo y no fn_menu_item_set_inventory_tracked: esa función exige
  --    auth.uid() con rol, y desde el SQL Editor es null (INSUFFICIENT_ROLE).
  -- =========================================================================

  create temp table _p007_insumos (
    codigo  text primary key,
    item_id uuid
  ) on commit drop;

  -- 8a) El insumo que el producto ya tenga enlazado, o uno que calce por código.
  insert into _p007_insumos (codigo, item_id)
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
  from _p007 p
  join _p007_ids i on i.codigo = p.codigo
  where p.inventariable;

  -- 8b) Los que faltan se crean, con el mismo nombre que el producto.
  insert into public.inventory_items (
    business_id, sku, barcode, name, unit, cost, is_active
  )
  select v_business, p.codigo, p.barcode, p.name, 'unidad',
         coalesce(p.cost, 0), true
  from _p007 p
  join _p007_insumos s on s.codigo = p.codigo
  where s.item_id is null;
  get diagnostics v_insumos = row_count;

  update _p007_insumos s
  set item_id = ii.id
  from public.inventory_items ii
  where s.item_id is null
    and ii.business_id = v_business
    and ii.sku = s.codigo;

  -- 8c) Link directo + tracking.
  update public.menu_items mi
  set inventory_item_id    = s.item_id,
      is_inventory_tracked = true
  from _p007_ids i
  join _p007_insumos s on s.codigo = i.codigo
  where mi.id = i.id
    and (mi.inventory_item_id is distinct from s.item_id
         or not coalesce(mi.is_inventory_tracked, false));

  -- 8d) Existencia inicial, UNA sola vez por insumo. trg_inventory_stock_sync
  --     suma inventory_stock y trg_inventory_movement_recost deja el costo del
  --     insumo en el costo del listado.
  insert into public.inventory_movements (
    business_id, warehouse_id, item_id, movement_type, quantity,
    cost_per_unit, reference_type, notes
  )
  select v_business, v_wh_id, s.item_id, 'purchase'::public.movement_type,
         p.qty, p.cost, 'initial_stock',
         'Existencia inicial del listado del sistema anterior (14/09/2026) — '
           || p.name
  from _p007 p
  join _p007_insumos s on s.codigo = p.codigo
  where p.qty > 0
    and not exists (
      select 1 from public.inventory_movements m
      where m.item_id = s.item_id and m.reference_type = 'initial_stock'
    );
  get diagnostics v_movs = row_count;

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
  from _p007 p
  where (select count(*) from public.menu_items mi
         where mi.business_id = v_business and mi.sku = p.codigo) <> 1;
  if v_n > 0
     or (select count(*) from _p007_ids) <> v_total
     or (select count(distinct id) from _p007_ids) <> v_total then
    raise exception '% códigos sin producto o con más de uno. Revertido.', v_n;
  end if;

  -- 9b) Precio, ITBIS incluido, categoría y código de barras del listado.
  select count(*) into v_n
  from _p007_ids i
  join public.menu_items mi on mi.id = i.id
  join _p007 p on p.codigo = i.codigo
  left join public.categories c on c.id = mi.category_id
  where mi.price <> p.price
     or mi.tax_mode <> 'inclusive'
     or c.id is null
     or lower(btrim(c.name)) <> lower(p.categoria)
     or (p.barcode is not null and mi.barcode is distinct from p.barcode);
  if v_n > 0 then
    raise exception '% productos con precio, impuesto, categoría o código de barras incorrectos. Revertido.', v_n;
  end if;

  -- 9c) Los 6 que no son mercancía, apagados.
  select count(*) into v_n
  from _p007_ids i
  join public.menu_items mi on mi.id = i.id
  join _p007 p on p.codigo = i.codigo
  where not p.activo and mi.is_active;
  if v_n > 0 then
    raise exception '% renglones que deben quedar inactivos siguen activos. Revertido.', v_n;
  end if;

  -- 9d) Exactamente el ITBIS: sin él factura 0.00; con otro, cobra de más.
  select count(*) into v_n
  from _p007_ids i
  where not exists (select 1 from public.menu_item_taxes x
                    where x.item_id = i.id and x.tax_id = v_tax_id)
     or exists (select 1 from public.menu_item_taxes x
                where x.item_id = i.id and x.tax_id <> v_tax_id);
  if v_n > 0 then
    raise exception '% productos sin ITBIS o con otro impuesto. Revertido.', v_n;
  end if;

  -- 9e) Área: legacy y N:M de acuerdo.
  select count(*) into v_n
  from _p007_ids i
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
    raise exception '% productos con el área de comanda en desacuerdo. Revertido.', v_n;
  end if;

  -- 9f) Todos en el menú de la caja.
  select count(*) into v_n
  from _p007_ids i
  where not exists (select 1 from public.menu_item_links l
                    where l.menu_id = v_menu_id and l.item_id = i.id);
  if v_n > 0 then
    raise exception '% productos fuera del menú: no saldrían en la caja. Revertido.', v_n;
  end if;

  -- 9g) Inventariables enlazados a un insumo del negocio.
  select count(*) into v_n
  from _p007 p
  join _p007_ids i on i.codigo = p.codigo
  join public.menu_items mi on mi.id = i.id
  left join public.inventory_items ii
    on ii.id = mi.inventory_item_id and ii.business_id = v_business
  where p.inventariable
    and (not coalesce(mi.is_inventory_tracked, false) or ii.id is null);
  if v_n > 0 then
    raise exception '% productos inventariables sin insumo: se venderían sin descontar. Revertido.', v_n;
  end if;

  -- 9h) Ningún insumo compartido por dos productos del listado.
  select count(*) into v_n
  from (select item_id from _p007_insumos
        group by item_id having count(*) > 1) z;
  if v_n > 0 then
    raise exception '% insumos compartidos por varios productos: descontarían cruzado. Revertido.', v_n;
  end if;

  -- 9i) Existencia inicial registrada para cada uno que la trae.
  select count(*) into v_n
  from _p007 p
  join _p007_insumos s on s.codigo = p.codigo
  where p.qty > 0
    and not exists (select 1 from public.inventory_movements m
                    where m.item_id = s.item_id
                      and m.reference_type = 'initial_stock');
  if v_n > 0 then
    raise exception '% productos sin su existencia inicial. Revertido.', v_n;
  end if;

  select count(*) into v_n
  from _p007 p
  join _p007_insumos s on s.codigo = p.codigo
  where p.qty > 0
    and not exists (select 1 from public.inventory_movements m
                    where m.item_id = s.item_id
                      and m.reference_type = 'initial_stock'
                      and m.quantity = p.qty);
  if v_n > 0 then
    raise notice '% insumos ya tenían una existencia inicial DISTINTA a la del listado: no se tocó (ajústala con un conteo).', v_n;
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

  raise notice 'OK — % productos (% nuevos, % actualizados) · % insumos nuevos · % existencias iniciales en "%" · área: % · Commit.',
    v_total, v_nuevos, v_actualizados, v_insumos, v_movs, v_wh_name,
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
  where mi.business_id = '3c5c3b8e-28e6-45f0-8dc7-85e3efe8d30c'::uuid
),
itbis as (
  select t.* from public.taxes t
  where t.business_id = '3c5c3b8e-28e6-45f0-8dc7-85e3efe8d30c'::uuid
    and t.name ilike '%itbis%' and t.rate = 18 and coalesce(t.is_active, true)
  limit 1
),
bs as (
  select * from public.business_settings
  where business_id = '3c5c3b8e-28e6-45f0-8dc7-85e3efe8d30c'::uuid
),
areas as (
  select distinct mipa.print_area_id as id
  from public.menu_item_print_areas mipa
  join items i on i.id = mipa.menu_item_id
),
iniciales as (
  select m.*
  from public.inventory_movements m
  join items i on i.inventory_item_id = m.item_id
  where m.reference_type = 'initial_stock'
),
r(orden, concepto, encontrado, esperado, ok) as (
  select 1, 'Productos del listado',
         (select count(*) from items)::text, '__N_TOTAL__',
         (select count(*) from items) = __N_TOTAL__
  union all
  select 2, 'Activos / inactivos',
         (select count(*) filter (where is_active) || ' / ' ||
                 count(*) filter (where not is_active) from items),
         '__N_ACTIVOS__ / __N_INACTIVOS__',
         (select count(*) filter (where not is_active) from items) = __N_INACTIVOS__
  union all
  select 3, 'Con ITBIS incluido (inclusive)',
         (select count(*) from items where tax_mode = 'inclusive')::text, '__N_TOTAL__',
         (select count(*) from items where tax_mode = 'inclusive') = __N_TOTAL__
  union all
  select 4, 'Vinculados SOLO al ITBIS 18%',
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
  select 5, 'Enlazados al menú de la caja',
         (select count(*) from items i where exists (
            select 1 from public.menu_item_links l where l.item_id = i.id))::text,
         '__N_TOTAL__',
         (select count(*) from items i where exists (
            select 1 from public.menu_item_links l where l.item_id = i.id)) = __N_TOTAL__
  union all
  select 6, 'Área de comanda: ' || coalesce((
            select string_agg(a.name || ' (' || a.code || ')', ', ')
            from public.print_areas a where a.id in (select id from areas)),
            'ninguna'),
         case when (select coalesce(kitchen_enabled, true) from bs)
              then 'cocina encendida'
              else 'cocina apagada' end,
         'cocina apagada y sin área, o una sola área',
         case when (select coalesce(kitchen_enabled, true) from bs)
              then (select count(*) from areas) = 1
                   and (select count(*) from items i where exists (
                          select 1 from public.menu_item_print_areas x
                          where x.menu_item_id = i.id)) = __N_TOTAL__
              else (select count(*) from areas) = 0
                   and (select count(*) from items
                        where print_area_code is not null) = 0
         end
  union all
  select 7, 'Inventariables con su insumo',
         (select count(*) from items i
           where i.is_inventory_tracked and i.inventory_item_id is not null)::text,
         '__N_INVENTARIABLES__',
         (select count(*) from items i
           where i.is_inventory_tracked and i.inventory_item_id is not null) = __N_INVENTARIABLES__
  union all
  select 8, 'Con existencia inicial',
         (select count(distinct item_id) from iniciales)::text, '__N_STOCK__',
         (select count(distinct item_id) from iniciales) = __N_STOCK__
  union all
  select 9, 'Unidades de existencia inicial',
         coalesce((select sum(quantity) from iniciales), 0)::text, '__UNIDADES__',
         coalesce((select sum(quantity) from iniciales), 0) = __UNIDADES__
  union all
  select 10, 'Valor de la existencia a costo (RD$)',
         to_char(coalesce((select sum(quantity * coalesce(cost_per_unit, 0))
                           from iniciales), 0), 'FM999,999,990.00'),
         '__VALOR__',
         round(coalesce((select sum(quantity * coalesce(cost_per_unit, 0))
                         from iniciales), 0), 2) = __VALOR_NUM__
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
  select 13, 'Códigos de barras repetidos (activos, todo el negocio)',
         (select count(*) from (
            select barcode from public.menu_items
            where business_id = '3c5c3b8e-28e6-45f0-8dc7-85e3efe8d30c'::uuid
              and is_active and nullif(btrim(barcode), '') is not null
            group by barcode having count(*) > 1) z)::text,
         '0',
         (select count(*) from (
            select barcode from public.menu_items
            where business_id = '3c5c3b8e-28e6-45f0-8dc7-85e3efe8d30c'::uuid
              and is_active and nullif(btrim(barcode), '') is not null
            group by barcode having count(*) > 1) z) = 0
  union all
  select 14, 'ITBIS se cobra en venta rápida',
         coalesce((select case when apply_on_quick then 'sí' else 'NO' end from itbis), '—'),
         'sí',
         coalesce((select apply_on_quick from itbis), false)
  union all
  select 15, 'Impresoras en el área de comanda',
         case when (select count(*) from areas) = 0 then 'no aplica'
              else (select count(*) from public.print_area_printers p
                    where p.area_id in (select id from areas))::text end,
         'no aplica, o 1 o más',
         (select count(*) from areas) = 0
         or (select count(*) from public.print_area_printers p
             where p.area_id in (select id from areas)) > 0
)
select concepto, encontrado, esperado,
       case when ok then '✓' else '✗ REVISAR' end as estado
from r
order by orden;
