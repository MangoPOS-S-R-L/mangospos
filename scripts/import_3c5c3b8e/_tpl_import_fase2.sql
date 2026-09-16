-- ============================================================================
-- 007 BAR & SNACK, SRL — CARGA DEL CATÁLOGO, FASE 2
-- Business 3c5c3b8e-28e6-45f0-8dc7-85e3efe8d30c
--
-- Fuente: ARTICULO.csv, el maestro de artículos del sistema anterior
-- (15/09/2026, 3,831 artículos). La fase 1 cargó los __N_FASE1__ de
-- "PRODUCTOS 007.pdf", que era solo el tramo de códigos 7622201776664–9002490291709.
--
-- ⚠ ARCHIVO GENERADO por build_fase2_3c5c3b8e.py desde _tpl_import_fase2.sql.
--   No lo edites a mano: cambia el .py (o la plantilla) y regenera.
-- ============================================================================
--
-- QUÉ CARGA
--   __N_TOTAL__ productos que faltaban: los que vendieron en los últimos 12 meses o
--   tienen existencia. Quedan fuera los dormidos y los de uso interno.
--   __N_CATEGORIAS__ categorías; se crean las que falten (__CAT_NUEVAS__).
--   __N_BARCODE__ con código de barras. Todos llevan el código del maestro en `sku`.
--   Todos inventariables. __N_STOCK__ con existencia inicial: __UNIDADES__ unidades,
--   RD$__VALOR__ a costo.
--   Además renumera la POSICIÓN (orden alfabético dentro de la categoría) de los
--   __N_FASE1__ productos de la fase 1, para que los nuevos queden intercalados en
--   orden. A esos productos no les toca nada más.
--
-- CÓMO CORRERLO
--   Corre antes 00_diagnostico_fase2.sql. Después pega este archivo entero en el
--   SQL Editor de Supabase y dale Run. La tabla del final es el reporte: todas
--   las filas deben decir ✓.
--
-- TODO O NADA
--   Va en UNA transacción. Comprueba todo antes de escribir y verifica los
--   __N_TOTAL__ uno por uno antes del commit. Si algo no cuadra, REVIERTE ENTERO.
--
-- SE PUEDE RE-CORRER
--   Empareja por CÓDIGO (sku o código de barras), no por nombre. Si alguien ya
--   creó a mano uno de estos productos (con ese código), se actualiza: precio,
--   costo, categoría, ITBIS, código de barras y área. Conserva el nombre y no se
--   reactiva si lo apagaron. Su existencia NO se toca si el insumo ya tiene
--   movimientos (ventas, compras, conteos): sale en un aviso.
--   Aborta si un código de esta fase apunta a un producto de la FASE 1.
--
-- DECISIONES DEL DUEÑO (15 y 16/09/2026)
--   * ITBIS 18% INCLUIDO en el precio (tax_mode = 'inclusive') para TODOS, sin Ley.
--     También aguas y yogures, aunque el sistema anterior los tenía al 0% o 16%.
--   * Inventario 1:1 con link directo, también en lo elaborado y en consignación.
--     Existencia = ar_exitem del maestro; los negativos entran en 0.
--     allow_negative_sale = true: nada se esconde en caja por falta de existencia.
--   * Precio = ar_predet. Costo = ar_ultcos (último costo; en null si es 0).
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 0) Los datos. _p007f2 y _p007f2_pos1 sobreviven al commit (temporales de la
--    sesión) porque el reporte del final las usa; al final se borran.
-- ---------------------------------------------------------------------------

drop table if exists _p007f2;
drop table if exists _p007f2_pos1;

create temp table _p007f2 (
  codigo        text primary key,     -- ar_codigo del maestro, tal cual
  name          text not null,
  categoria     text not null,
  price         numeric(12,2) not null,
  cost          numeric,              -- null si el maestro dice 0
  qty           numeric not null,     -- existencia inicial (negativos → 0)
  qty_listado   numeric not null,     -- ar_exitem tal cual
  barcode       text,                 -- null si el código no es GTIN
  is_bev        boolean not null,
  posicion      int not null
);

__DATA__

-- Posición nueva de los productos de la fase 1 (orden alfabético con los nuevos).
create temp table _p007f2_pos1 (
  codigo    text primary key,
  categoria text not null,
  posicion  int  not null
);

__POS1__

create temp table _p007f2_categorias (
  name     text primary key,
  posicion int  not null
) on commit drop;

insert into _p007f2_categorias (name, posicion) values
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
  v_pos1         int;
begin
  -- =========================================================================
  -- 1) GUARDAS — se comprueba todo ANTES de escribir una sola fila.
  -- =========================================================================

  if not exists (select 1 from public.businesses where id = v_business) then
    raise exception 'El negocio % no existe.', v_business;
  end if;

  -- 1a) La fase 1 tiene que estar cargada: esta fase la completa.
  select count(*) into v_n
  from _p007f2_pos1 q
  where exists (select 1 from public.menu_items mi
                where mi.business_id = v_business and mi.sku = q.codigo);
  if v_n = 0 then
    raise exception
      'No encuentro ningún producto de la fase 1. Corre primero IMPORT_COMPLETO.sql.';
  elsif v_n < __N_FASE1__ then
    raise notice 'De los __N_FASE1__ productos de la fase 1 encontré %: los que falten no se renumeran.', v_n;
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

  -- 1e) Ningún código apunta a VARIOS productos o insumos.
  select string_agg(format('%s (%s productos)', p.codigo, x.n), ', ')
    into v_list
  from _p007f2 p
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
      'Códigos que ya tienen VARIOS productos, no sé cuál actualizar: %', v_list;
  end if;

  select string_agg(format('%s (%s insumos)', p.codigo, x.n), ', ')
    into v_list
  from _p007f2 p
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
      'Códigos que ya tienen VARIOS insumos, no sé cuál usar: %', v_list;
  end if;

  -- 1f) Ningún código de esta fase apunta a un producto de la FASE 1: lo
  --     pisaría con los datos de otro artículo.
  select string_agg(format('%s → %s (%s)', p.codigo, mi.name, mi.sku), '; ')
    into v_list
  from _p007f2 p
  join public.menu_items mi
    on mi.business_id = v_business
   and (mi.sku = p.codigo or mi.barcode = p.codigo
        or (p.barcode is not null and mi.barcode = p.barcode))
  join _p007f2_pos1 q on q.codigo = mi.sku;

  if v_list is not null then
    raise exception
      'Códigos de la fase 2 que apuntan a productos de la fase 1: %. Revísalos '
      'antes de cargar.', v_list;
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

  -- 1h) Bodega: la MISMA que escoge consume_inventory_from_order al vender.
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

  -- 1i) Área de comanda: la misma regla que la fase 1.
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
          'apaga Cocina en Ajustes y vuelve a correr.';
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
  from _p007f2_categorias c
  where exists (select 1 from _p007f2 p where p.categoria = c.name)
    and not exists (
      select 1 from public.categories x
      where x.business_id = v_business
        and lower(btrim(x.name)) = lower(c.name)
    );

  -- =========================================================================
  -- 4) PRODUCTOS — por código. Actualiza los que existen, inserta los demás.
  -- =========================================================================

  create temp table _p007f2_ids (
    codigo text primary key,
    id     uuid not null,
    nuevo  boolean not null
  ) on commit drop;

  insert into _p007f2_ids (codigo, id, nuevo)
  select p.codigo, mi.id, false
  from _p007f2 p
  join public.menu_items mi
    on mi.business_id = v_business
   and (mi.sku = p.codigo or mi.barcode = p.codigo
        or (p.barcode is not null and mi.barcode = p.barcode));

  select string_agg(format('%s ← %s', mi.name, z.codigos), '; ')
    into v_list
  from (
    select id, string_agg(codigo, ', ') as codigos
    from _p007f2_ids group by id having count(*) > 1
  ) z
  join public.menu_items mi on mi.id = z.id;

  if v_list is not null then
    raise exception
      'Productos que calzan con varios códigos del maestro a la vez: %', v_list;
  end if;

  -- Productos que ya existían con estos códigos: en una primera corrida son los
  -- que alguien creó a mano. Se avisa cuáles (en una re-corrida salen todos).
  select count(*), string_agg(mi.name, ', ' order by mi.name)
    into v_n, v_list
  from _p007f2_ids i
  join public.menu_items mi on mi.id = i.id;
  if v_n > 0 and v_n < v_total then
    raise notice '% productos ya existían con su código y se actualizan: %', v_n, v_list;
  end if;

  update public.menu_items mi
  set category_id         = cat.id,
      price               = p.price,
      cost                = p.cost,
      tax_mode            = 'inclusive',
      sku                 = p.codigo,
      barcode             = coalesce(p.barcode, mi.barcode),
      is_beverage         = p.is_bev,
      position            = p.posicion,
      print_area_code     = v_area_code,
      allow_negative_sale = true,
      updated_at          = now()
  from _p007f2_ids i
  join _p007f2 p on p.codigo = i.codigo
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
         'inclusive', p.codigo, p.barcode, true, p.is_bev, p.posicion,
         v_area_code, true
  from _p007f2 p
  cross join lateral (
    select c.id from public.categories c
    where c.business_id = v_business
      and lower(btrim(c.name)) = lower(p.categoria)
    order by c.created_at
    limit 1
  ) cat
  where not exists (select 1 from _p007f2_ids i where i.codigo = p.codigo);
  get diagnostics v_nuevos = row_count;

  insert into _p007f2_ids (codigo, id, nuevo)
  select p.codigo, mi.id, true
  from _p007f2 p
  join public.menu_items mi
    on mi.business_id = v_business
   and mi.sku = p.codigo
  where not exists (select 1 from _p007f2_ids i where i.codigo = p.codigo);

  -- =========================================================================
  -- 5) IMPUESTOS — exactamente el ITBIS.
  -- =========================================================================

  delete from public.menu_item_taxes mit
  using _p007f2_ids i
  where mit.item_id = i.id
    and mit.tax_id <> v_tax_id;

  insert into public.menu_item_taxes (item_id, tax_id)
  select i.id, v_tax_id
  from _p007f2_ids i
  where not exists (
    select 1 from public.menu_item_taxes x
    where x.item_id = i.id and x.tax_id = v_tax_id
  );

  -- =========================================================================
  -- 6) ÁREA DE COMANDA (N:M), igual que la fase 1.
  -- =========================================================================

  delete from public.menu_item_print_areas x
  using _p007f2_ids i
  where x.menu_item_id = i.id
    and (v_area_id is null or x.print_area_id <> v_area_id);

  if v_area_id is not null then
    insert into public.menu_item_print_areas (menu_item_id, print_area_id)
    select i.id, v_area_id
    from _p007f2_ids i
    where not exists (
      select 1 from public.menu_item_print_areas x
      where x.menu_item_id = i.id and x.print_area_id = v_area_id
    );
  end if;

  -- =========================================================================
  -- 7) ENLACE AL MENÚ Y POSICIONES
  -- =========================================================================

  insert into public.menu_item_links (menu_id, item_id, position)
  select v_menu_id, i.id, p.posicion
  from _p007f2_ids i
  join _p007f2 p on p.codigo = i.codigo
  where not exists (
    select 1 from public.menu_item_links l
    where l.menu_id = v_menu_id and l.item_id = i.id
  );

  update public.menu_item_links l
  set position = p.posicion
  from _p007f2_ids i
  join _p007f2 p on p.codigo = i.codigo
  where l.menu_id = v_menu_id
    and l.item_id = i.id
    and l.position is distinct from p.posicion;

  -- 7b) Fase 1: solo la posición, y solo si el producto sigue en la categoría
  --     con que se cargó (si lo movieron de categoría, no se toca).
  create temp table _p007f2_ids1 on commit drop as
  select mi.id, q.posicion
  from _p007f2_pos1 q
  join public.menu_items mi
    on mi.business_id = v_business
   and mi.sku = q.codigo
  join public.categories c
    on c.id = mi.category_id
   and lower(btrim(c.name)) = lower(q.categoria);

  update public.menu_items mi
  set position   = x.posicion,
      updated_at = now()
  from _p007f2_ids1 x
  where mi.id = x.id
    and mi.position is distinct from x.posicion;
  get diagnostics v_pos1 = row_count;

  update public.menu_item_links l
  set position = x.posicion
  from _p007f2_ids1 x
  where l.menu_id = v_menu_id
    and l.item_id = x.id
    and l.position is distinct from x.posicion;

  -- =========================================================================
  -- 8) INVENTARIO — un insumo por producto, emparejado por CÓDIGO.
  --    DML directo: fn_menu_item_set_inventory_tracked exige auth.uid().
  -- =========================================================================

  create temp table _p007f2_insumos (
    codigo     text primary key,
    item_id    uuid,
    tenia_movs boolean not null default false
  ) on commit drop;

  insert into _p007f2_insumos (codigo, item_id)
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
  from _p007f2 p
  join _p007f2_ids i on i.codigo = p.codigo;

  insert into public.inventory_items (
    business_id, sku, barcode, name, unit, cost, is_active
  )
  select v_business, p.codigo, p.barcode, p.name, 'unidad',
         coalesce(p.cost, 0), true
  from _p007f2 p
  join _p007f2_insumos s on s.codigo = p.codigo
  where s.item_id is null;
  get diagnostics v_insumos = row_count;

  update _p007f2_insumos s
  set item_id = ii.id
  from public.inventory_items ii
  where s.item_id is null
    and ii.business_id = v_business
    and ii.sku = s.codigo;

  -- Un insumo con CUALQUIER movimiento ya tiene historia (su existencia inicial
  -- de una corrida anterior, o ventas y compras si lo crearon a mano): no se le
  -- suma la del maestro.
  update _p007f2_insumos s
  set tenia_movs = exists (select 1 from public.inventory_movements m
                           where m.item_id = s.item_id);

  update public.menu_items mi
  set inventory_item_id    = s.item_id,
      is_inventory_tracked = true
  from _p007f2_ids i
  join _p007f2_insumos s on s.codigo = i.codigo
  where mi.id = i.id
    and (mi.inventory_item_id is distinct from s.item_id
         or not coalesce(mi.is_inventory_tracked, false));

  insert into public.inventory_movements (
    business_id, warehouse_id, item_id, movement_type, quantity,
    cost_per_unit, reference_type, notes
  )
  select v_business, v_wh_id, s.item_id, 'purchase'::public.movement_type,
         p.qty, p.cost, 'initial_stock',
         'Existencia inicial del maestro del sistema anterior (15/09/2026) — '
           || p.name
  from _p007f2 p
  join _p007f2_insumos s on s.codigo = p.codigo
  where p.qty > 0
    and not s.tenia_movs;
  get diagnostics v_movs = row_count;

  select count(*), string_agg(p.name || ' (' || p.qty || ')', ', ' order by p.name)
    into v_n, v_list
  from _p007f2 p
  join _p007f2_insumos s on s.codigo = p.codigo
  where p.qty > 0
    and s.tenia_movs
    and not exists (select 1 from public.inventory_movements m
                    where m.item_id = s.item_id
                      and m.reference_type = 'initial_stock');
  if v_n > 0 then
    raise notice '% insumos ya tenían movimientos y NO se les cargó la existencia del maestro (cuéntalos): %', v_n, v_list;
  end if;

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
  from _p007f2 p
  where (select count(*) from public.menu_items mi
         where mi.business_id = v_business and mi.sku = p.codigo) <> 1;
  if v_n > 0
     or (select count(*) from _p007f2_ids) <> v_total
     or (select count(distinct id) from _p007f2_ids) <> v_total then
    raise exception '% códigos sin producto o con más de uno. Revertido.', v_n;
  end if;

  -- 9b) Precio, ITBIS incluido, categoría, código de barras y posición.
  select count(*) into v_n
  from _p007f2_ids i
  join public.menu_items mi on mi.id = i.id
  join _p007f2 p on p.codigo = i.codigo
  left join public.categories c on c.id = mi.category_id
  where mi.price <> p.price
     or mi.tax_mode <> 'inclusive'
     or c.id is null
     or lower(btrim(c.name)) <> lower(p.categoria)
     or (p.barcode is not null and mi.barcode is distinct from p.barcode)
     or mi.position is distinct from p.posicion;
  if v_n > 0 then
    raise exception '% productos con precio, impuesto, categoría, código de barras o posición incorrectos. Revertido.', v_n;
  end if;

  -- 9c) Exactamente el ITBIS.
  select count(*) into v_n
  from _p007f2_ids i
  where not exists (select 1 from public.menu_item_taxes x
                    where x.item_id = i.id and x.tax_id = v_tax_id)
     or exists (select 1 from public.menu_item_taxes x
                where x.item_id = i.id and x.tax_id <> v_tax_id);
  if v_n > 0 then
    raise exception '% productos sin ITBIS o con otro impuesto. Revertido.', v_n;
  end if;

  -- 9d) Área: legacy y N:M de acuerdo.
  select count(*) into v_n
  from _p007f2_ids i
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

  -- 9e) Todos en el menú de la caja, con su posición.
  select count(*) into v_n
  from _p007f2_ids i
  join _p007f2 p on p.codigo = i.codigo
  where not exists (select 1 from public.menu_item_links l
                    where l.menu_id = v_menu_id and l.item_id = i.id
                      and l.position = p.posicion);
  if v_n > 0 then
    raise exception '% productos fuera del menú o con otra posición. Revertido.', v_n;
  end if;

  -- 9f) Todos enlazados a un insumo del negocio.
  select count(*) into v_n
  from _p007f2_ids i
  join public.menu_items mi on mi.id = i.id
  left join public.inventory_items ii
    on ii.id = mi.inventory_item_id and ii.business_id = v_business
  where not coalesce(mi.is_inventory_tracked, false) or ii.id is null;
  if v_n > 0 then
    raise exception '% productos sin insumo: se venderían sin descontar. Revertido.', v_n;
  end if;

  -- 9g) Ningún insumo compartido.
  select count(*) into v_n
  from (select item_id from _p007f2_insumos
        group by item_id having count(*) > 1) z;
  if v_n > 0
     or exists (select 1 from _p007f2_insumos s
                join public.menu_items mi on mi.inventory_item_id = s.item_id
                where mi.business_id = v_business
                  and mi.id not in (select id from _p007f2_ids)) then
    raise exception 'Hay insumos compartidos con otros productos: descontarían cruzado. Revertido.';
  end if;

  -- 9h) Existencia: la trae, o el insumo ya tenía historia (aviso de arriba).
  select count(*) into v_n
  from _p007f2 p
  join _p007f2_insumos s on s.codigo = p.codigo
  where p.qty > 0
    and not s.tenia_movs
    and not exists (select 1 from public.inventory_movements m
                    where m.item_id = s.item_id
                      and m.reference_type = 'initial_stock'
                      and m.quantity = p.qty);
  if v_n > 0 then
    raise exception '% productos sin su existencia inicial. Revertido.', v_n;
  end if;

  -- 9i) El motor de inventario encendido.
  if (select inventory_mode from public.business_settings
      where business_id = v_business) not in ('basic', 'advanced') then
    raise exception 'inventory_mode no quedó en basic/advanced. Revertido.';
  end if;

  -- 9j) Ningún código de barras repetido en productos activos del negocio.
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

  raise notice 'OK — % productos (% nuevos, % actualizados) · % insumos nuevos · % existencias iniciales en "%" · % posiciones de la fase 1 renumeradas · área: % · Commit.',
    v_total, v_nuevos, v_actualizados, v_insumos, v_movs, v_wh_name, v_pos1,
    coalesce(v_area_code, 'ninguna (cocina apagada)');
end $$;

commit;

-- ============================================================================
-- REPORTE — todas las filas deben decir ✓
-- ============================================================================

with items as (
  select mi.*, p.qty as p_qty, p.cost as p_cost, p.posicion as p_pos
  from public.menu_items mi
  join _p007f2 p on p.codigo = mi.sku
  where mi.business_id = '3c5c3b8e-28e6-45f0-8dc7-85e3efe8d30c'::uuid
),
fase1 as (
  select mi.*, q.posicion as q_pos
  from public.menu_items mi
  join _p007f2_pos1 q on q.codigo = mi.sku
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
stock as (
  -- Por producto con existencia en el maestro: su movimiento inicial, o si el
  -- insumo ya traía historia de antes (entonces no se le cargó).
  select i.id, i.p_qty, i.p_cost,
         (select sum(m.quantity) from public.inventory_movements m
           where m.item_id = i.inventory_item_id
             and m.reference_type = 'initial_stock') as inicial,
         (select sum(m.quantity * coalesce(m.cost_per_unit, 0))
            from public.inventory_movements m
           where m.item_id = i.inventory_item_id
             and m.reference_type = 'initial_stock') as valor
  from items i
  where i.p_qty > 0
),
r(orden, concepto, encontrado, esperado, ok) as (
  select 1, 'Productos de la fase 2',
         (select count(*) from items)::text, '__N_TOTAL__',
         (select count(*) from items) = __N_TOTAL__
  union all
  select 2, 'Activos',
         (select count(*) filter (where is_active) from items)::text, '__N_TOTAL__',
         (select count(*) filter (where is_active) from items) = __N_TOTAL__
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
  select 5, 'Enlazados al menú de la caja, en su posición',
         (select count(*) from items i where exists (
            select 1 from public.menu_item_links l
            where l.item_id = i.id and l.position = i.p_pos))::text,
         '__N_TOTAL__',
         (select count(*) from items i where exists (
            select 1 from public.menu_item_links l
            where l.item_id = i.id and l.position = i.p_pos)) = __N_TOTAL__
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
  select 7, 'Con su insumo (inventario 1:1)',
         (select count(*) from items i
           where i.is_inventory_tracked and i.inventory_item_id is not null)::text,
         '__N_TOTAL__',
         (select count(*) from items i
           where i.is_inventory_tracked and i.inventory_item_id is not null) = __N_TOTAL__
  union all
  select 8, 'Con existencia inicial (+ ya tenían historia, sin tocar)',
         (select count(*) filter (where inicial is not null) || ' + ' ||
                 count(*) filter (where inicial is null) from stock),
         '__N_STOCK__',
         (select count(*) from stock) = __N_STOCK__
         and (select count(*) from stock s
               where s.inicial is null
                 and not exists (select 1 from items i
                                 join public.inventory_movements m
                                   on m.item_id = i.inventory_item_id
                                 where i.id = s.id)) = 0
  union all
  select 9, 'Unidades de existencia inicial',
         coalesce((select sum(inicial) from stock), 0)::text,
         coalesce((select sum(p_qty) from stock where inicial is not null), 0)::text,
         coalesce((select sum(inicial) from stock), 0)
           = coalesce((select sum(p_qty) from stock where inicial is not null), 0)
  union all
  select 10, 'Valor de la existencia a costo (RD$)',
         to_char(coalesce((select sum(valor) from stock), 0), 'FM999,999,990.00'),
         to_char(coalesce((select sum(p_qty * coalesce(p_cost, 0)) from stock
                           where inicial is not null), 0), 'FM999,999,990.00'),
         round(coalesce((select sum(valor) from stock), 0), 2)
           = round(coalesce((select sum(p_qty * coalesce(p_cost, 0)) from stock
                             where inicial is not null), 0), 2)
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
  select 15, 'Fase 1 en el menú de la caja (de __N_FASE1__ cargados)',
         (select count(*) from fase1 f where exists (
             select 1 from public.menu_item_links l where l.item_id = f.id))::text,
         (select count(*) from fase1)::text || ' que siguen',
         (select count(*) from fase1 f where not exists (
             select 1 from public.menu_item_links l where l.item_id = f.id)) = 0
  union all
  select 16, 'Fase 1 renumerada (en su categoría original)',
         (select count(*) from fase1 f
           join public.categories c on c.id = f.category_id
           join _p007f2_pos1 q on q.codigo = f.sku
                              and lower(btrim(c.name)) = lower(q.categoria)
          where f.position = f.q_pos)::text,
         (select count(*) from fase1 f
           join public.categories c on c.id = f.category_id
           join _p007f2_pos1 q on q.codigo = f.sku
                              and lower(btrim(c.name)) = lower(q.categoria))::text,
         (select count(*) from fase1 f
           join public.categories c on c.id = f.category_id
           join _p007f2_pos1 q on q.codigo = f.sku
                              and lower(btrim(c.name)) = lower(q.categoria)
          where f.position is distinct from f.q_pos) = 0
)
select concepto, encontrado, esperado,
       case when ok then '✓' else '✗ REVISAR' end as estado
from r
order by orden;

drop table if exists _p007f2;
drop table if exists _p007f2_pos1;
