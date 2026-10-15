-- =============================================================================
-- 20261013_0002 — Historial de cambios: TODO (caja, cuentas, compras,
--                 inventario, créditos y lo que faltaba de configuración)
-- =============================================================================
--
-- POR QUÉ. Pedido del dueño (2026-10-13), sobre 20261013_0001 ya aplicada:
-- «ahí debe salir todo, hasta lo que se agrega a una caja».
--
-- QUÉ AGREGA (cada acción de una persona = una línea; nada de lo que la venta
-- hace sola):
--   Caja       entradas, retiros y gastos (los que lleva motivo: los hace una
--              persona; las filas 'sale' de cada cobro no), abrir, cerrar,
--              cerrar a la fuerza, recontar y pasar la caja a otro equipo.
--   Cuentas    pasar una cuenta o productos a otra mesa, descuentos y
--              cortesías (solo los que pasan por fn_update_item_discount),
--              cambio de método de pago, cambio de mesero, notas de crédito,
--              anular una nota de venta.
--   Créditos   abonos de clientes, cancelar un crédito, cuentas por pagar
--              (crear, cancelar, pagar), abonos por mesa (recibir, devolver,
--              pasar a otra mesa), ajustes de sellos.
--   Inventario ajustes, salidas y mermas, inventario inicial (los de
--              documentos —compras, transferencias, conteos, producción— salen
--              una vez en su documento, no línea por línea), y los documentos:
--              órdenes de compra, recepciones, entradas directas,
--              transferencias, conteos físicos, requisiciones, producción,
--              activos fijos.
--   Config.    menús↔productos, combos, ingredientes de modificadores, áreas
--              de impresión de productos, impresoras de cada área y de cada
--              equipo, catálogo de proveedores, presentaciones de insumos,
--              cuentas contables, centros de costo, tarjetas de sellos,
--              motivos de eliminación, tarjetas de regalo, llaves de
--              integración, reservaciones, cierre de sesión a distancia.
--
-- ARREGLO. Pasar una cuenta a una mesa OCUPADA (fn_transfer_table_session)
-- deja 'void' la orden de origen: 0001 lo anotaba como «anuló la cuenta». Ya
-- no; se anota como «pasó la cuenta». Las líneas que ya quedaron mal (source =
-- '/rpc/fn_transfer_table_session') se corrigen aquí: no las escribió nadie,
-- las escribió el trigger con el verbo equivocado.
--
-- CÓMO SE SABE DE DÓNDE VIENE. Pasar productos, descuentos y anular en un
-- traslado se distinguen por la pila de llamadas (PG_CONTEXT), igual que
-- 20261010_0027: solo cuenta si lo hizo fn_transfer_table_session o
-- fn_update_item_discount.
--
-- SEGURIDAD. Igual que 0001: cada trigger ataja sus errores (WARNING) y el
-- cambio del usuario sigue. Tablas que no existan en vivo se saltan. Los
-- triggers nuevos en tablas calientes (order_items, payments, table_sessions)
-- llevan WHEN estrecho: solo se evalúan cuando cambia esa columna.
--
-- DESDE AHORA: no copia hacia atrás (los movimientos viejos siguen en sus
-- reportes de caja, compras e inventario).
--
-- REQUIERE 20261013_0001. IDEMPOTENTE.
-- ROLLBACK: 20261013_0002_change_history_operations_ROLLBACK.sql
-- Prueba: supabase/tests/change_history_operations_local_test.sh
-- Aplicar en horario de poca venta (los candados de los triggers).
-- =============================================================================

begin;

set local lock_timeout = '5s';

do $$
begin
  if to_regclass('public.change_history') is null then
    raise exception 'Falta 20261013_0001_change_history.sql';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 1. Ayudantes nuevos
-- ---------------------------------------------------------------------------

-- ¿La llamada viene de esta función? (pila de PG_CONTEXT, como 0027)
create or replace function private.fn_change_history_called_from(p_regex text)
returns boolean
language plpgsql
as $$
declare
  v_ctx text;
begin
  get diagnostics v_ctx = pg_context;
  return v_ctx ~ ('function (public\.)?(' || p_regex || ')\(');
end;
$$;

-- La mesa de una sesión, como la ve el mesero.
create or replace function private.fn_change_history_session_label(p_session uuid)
returns text
language sql
stable
set search_path = public
as $$
  select case
           when dt.id is not null then coalesce(dt.label, dt.code, 'Mesa')
           when ts.origin::text = 'manual' then 'Venta manual'
           when ts.origin::text in ('quick', 'quick_sale') then 'Venta rápida'
           else 'Venta'
         end
  from public.table_sessions ts
  left join public.dining_tables dt on dt.id = ts.table_id
  where ts.id = p_session
$$;

create or replace function private.fn_change_history_order_label(p_order uuid)
returns text
language sql
stable
set search_path = public
as $$
  select private.fn_change_history_session_label(o.session_id)
  from public.orders o
  where o.id = p_order
$$;

create or replace function private.fn_change_history_table_label(p_table uuid)
returns text
language sql
stable
set search_path = public
as $$
  select coalesce(dt.label, dt.code)
  from public.dining_tables dt
  where dt.id = p_table
$$;

-- Caja y negocio de una sesión de caja.
create or replace function private.fn_change_history_cash_scope(
  p_session uuid,
  out business_id uuid,
  out register text,
  out device text
)
language sql
stable
set search_path = public
as $$
  select cr.business_id, cr.name, s.device_name
  from public.cash_register_sessions s
  join public.cash_registers cr on cr.id = s.cash_register_id
  where s.id = p_session
$$;

-- Anota una línea (los triggers de operación).
create or replace function private.fn_change_history_add(
  p_business   uuid,
  p_table      text,
  p_row_id     text,
  p_action     text,
  p_label      text,
  p_context    text,
  p_actor      uuid,
  p_employee   uuid,
  p_changes    jsonb,
  p_changed_at timestamptz default null
)
returns bigint
language plpgsql
set search_path = public
as $$
declare
  v_id bigint;
begin
  if p_business is null or p_row_id is null then
    return null;
  end if;
  if not exists (select 1 from public.businesses b where b.id = p_business) then
    return null;
  end if;
  insert into public.change_history (
    business_id, table_name, row_id, action, label, context,
    actor_user_id, actor_employee_id, actor_name, changed_at, changes, source
  )
  values (
    p_business, p_table, p_row_id, p_action, coalesce(p_label, ''),
    coalesce(p_context, ''), p_actor, p_employee,
    private.fn_change_history_person(p_business, p_actor, p_employee),
    coalesce(p_changed_at, clock_timestamp()),
    jsonb_strip_nulls(coalesce(p_changes, '{}'::jsonb)),
    nullif(current_setting('request.path', true), '')
  )
  returning id into v_id;
  return v_id;
end;
$$;

-- Valor para mostrar (reemplaza a fn_change_history_value: sabe de qué tabla
-- viene, porque `item_id` es un producto en el menú y un insumo en inventario).
create or replace function private.fn_change_history_render(
  p_table  text,
  p_column text,
  p_value  jsonb,
  p_side   text default 'snap'   -- old | new | snap
)
returns jsonb
language plpgsql
stable
set search_path = public
as $$
declare
  v_text text := p_value #>> '{}';
  v_ref  text;
  v_row  jsonb;
  v_name text;
begin
  if p_value is null or jsonb_typeof(p_value) = 'null' then
    return p_value;
  end if;

  if p_column in ('pin', 'pin_hash', 'lan_token')
     or p_column ~ '(password|secret|token|_hash$)' then
    return to_jsonb(case when p_side = 'new' then '•••• (nuevo)' else '••••' end);
  end if;

  if p_column in ('image_url', 'image_path', 'logo_url', 'logo_storage_path') then
    if coalesce(v_text, '') = '' then
      return 'null'::jsonb;
    end if;
    return to_jsonb(case when p_side = 'new' then 'imagen nueva' else 'imagen' end);
  end if;

  if jsonb_typeof(p_value) <> 'string'
     or v_text !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    return p_value;
  end if;

  -- Quién: cualquier *_by y user_id son cuentas.
  if p_column = 'user_id' or p_column like '%\_by' then
    return to_jsonb(private.fn_change_history_person(null, v_text::uuid));
  end if;

  v_ref := case
    when p_column = 'item_id' and p_table in (
           'inventory_item_presentations', 'inventory_movements',
           'stock_transfer_items', 'direct_receipt_items',
           'physical_count_lines', 'purchase_reception_lines')
      then 'inventory_items'
    else case p_column
      when 'category_id'              then 'categories'
      when 'zone_id'                  then 'zones'
      when 'table_id'                 then 'dining_tables'
      when 'tax_id'                   then 'taxes'
      when 'role_id'                  then 'roles'
      when 'group_id'                 then 'modifier_groups'
      when 'menu_id'                  then 'menus'
      when 'menu_item_id'             then 'menu_items'
      when 'item_id'                  then 'menu_items'
      when 'modifier_id'              then 'modifiers'
      when 'combo_group_id'           then 'combo_groups'
      when 'inventory_item_id'        then 'inventory_items'
      when 'finished_item_id'         then 'inventory_items'
      when 'target_item_id'           then 'inventory_items'
      when 'warehouse_id'             then 'warehouses'
      when 'from_warehouse_id'        then 'warehouses'
      when 'to_warehouse_id'          then 'warehouses'
      when 'source_warehouse_id'      then 'warehouses'
      when 'destination_warehouse_id' then 'warehouses'
      when 'supplier_id'              then 'suppliers'
      when 'preferred_supplier_id'    then 'suppliers'
      when 'customer_id'              then 'customers'
      when 'promotion_id'             then 'promotions'
      when 'program_id'               then 'loyalty_stamp_programs'
      when 'print_area_id'            then 'print_areas'
      when 'area_id'                  then 'print_areas'
      when 'printer_id'               then 'printers'
      when 'receipt_printer_id'       then 'printers'
      when 'fallback_printer_id'      then 'printers'
      when 'permission_id'            then 'permissions'
      when 'payment_method_id'        then 'payment_methods'
      when 'cash_register_id'         then 'cash_registers'
      when 'reason_id'                then 'cash_transaction_reasons'
      when 'purchase_order_id'        then 'purchase_orders'
      when 'employee_id'              then 'employees'
      when 'keeper_employee_id'       then 'employees'
      when 'assigned_employee_id'     then 'employees'
      when 'accounting_account_id'    then 'accounting_accounts'
      when 'from_business_id'         then 'businesses'
      when 'to_business_id'           then 'businesses'
    end
  end;
  if v_ref is null or to_regclass('public.' || v_ref) is null then
    return p_value;
  end if;

  -- Sin bloque de excepción propio: si algo falla, lo ataja el trigger.
  execute format('select to_jsonb(t) from public.%I t where t.id = $1', v_ref)
    into v_row
    using v_text::uuid;
  v_name := coalesce(
    nullif(trim(concat_ws(' ', v_row ->> 'first_name', v_row ->> 'last_name')), ''),
    nullif(v_row ->> 'name', ''),
    nullif(v_row ->> 'label', ''),
    nullif(v_row ->> 'business_name', ''),
    nullif(v_row ->> 'order_number', ''),
    nullif(v_row ->> 'code', ''));
  return coalesce(to_jsonb(v_name), p_value);
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. Ayudantes de 0001 que cambian
-- ---------------------------------------------------------------------------

create or replace function private.fn_change_history_keep(
  p_table  text,
  p_column text,
  p_source text
)
returns boolean
language sql
immutable
as $$
  select case
    when p_column in ('id', 'business_id', 'created_at', 'updated_at',
                      'created_by', 'updated_by', 'version',
                      'sort_order', 'sort_index', 'display_order',
                      'idempotency_key', 'client_request_id', 'time_range')
      then false
    -- Orden en la lista; en employees es el puesto y sí cuenta.
    when p_column = 'position' and p_table <> 'employees'
      then false
    when p_column like 'last\_%' or p_column like '%heartbeat%'
      then false
    -- Lista blanca: el resto se mueve solo (estado de la mesa, posición en el
    -- plano, suscripción y cobros del negocio).
    when p_table = 'dining_tables'
      then p_column in ('zone_id', 'code', 'label', 'shape', 'capacity',
                        'is_active')
    when p_table = 'businesses'
      then p_column in ('business_name', 'branch_name', 'business_type',
                        'country', 'address', 'phone', 'email', 'fiscal_name',
                        'fiscal_rnc', 'logo_url', 'slogan',
                        'ticket_footer_message', 'prefer_electronic_billing')
    when p_table = 'menu_items'
      then p_column <> 'auto_disabled'
    when p_table = 'printers'
      then p_column not in ('online', 'status')
    -- El número actual sube con cada factura (una función): solo cuenta si
    -- alguien lo escribió directo en la tabla (Ajustes › NCF).
    when p_table = 'ncf_sequences'
      then p_column <> 'device_id'
       and (p_column <> 'current_number'
            or (p_source is not null and p_source not like '%/rpc/%'))
    when p_table = 'business_settings'
      then p_column not in ('sales_note_count', 'agent_url', 'lan_token')
    when p_table = 'coupons'
      then p_column <> 'times_used'
    when p_table = 'user_businesses'
      then p_column <> 'permissions'
    when p_table = 'purchase_orders'
      then p_column not in ('subtotal', 'tax')
    when p_table = 'reservations'
      then p_column <> 'session_id'
    when p_table = 'inventory_item_presentations'
      then p_column <> 'base_qty'
    else true
  end
$$;

create or replace function private.fn_change_history_snapshot(
  p_table  text,
  p_row    jsonb,
  p_source text
)
returns jsonb
language sql
stable
as $$
  select coalesce(jsonb_object_agg(
           e.key, private.fn_change_history_render(p_table, e.key, e.value)),
           '{}'::jsonb)
  from jsonb_each(p_row) e
  where private.fn_change_history_keep(p_table, e.key, p_source)
    and jsonb_typeof(e.value) <> 'null'
$$;

-- Negocio, id y etiquetas de una fila (0001 + las tablas nuevas).
create or replace function private.fn_change_history_scope(
  p_table text,
  p_row   jsonb,
  out business_id uuid,
  out row_id      text,
  out label       text,
  out context     text
)
language plpgsql
stable
set search_path = public
as $$
declare
  v_parent jsonb;
begin
  row_id := p_row ->> 'id';

  case p_table
    when 'businesses' then
      business_id := (p_row ->> 'id')::uuid;
      label := concat_ws(' · ', nullif(p_row ->> 'business_name', ''),
                                nullif(p_row ->> 'branch_name', ''));

    when 'dining_tables' then
      select z.business_id, z.name
        into business_id, context
      from public.zones z
      where z.id = (p_row ->> 'zone_id')::uuid;
      label := coalesce(nullif(p_row ->> 'label', ''), p_row ->> 'code');

    when 'employees' then
      business_id := (p_row ->> 'business_id')::uuid;
      label := trim(concat_ws(' ', p_row ->> 'first_name', p_row ->> 'last_name'));

    when 'user_businesses' then
      business_id := (p_row ->> 'business_id')::uuid;
      label := private.fn_change_history_person(business_id, (p_row ->> 'user_id')::uuid);
      context := p_row ->> 'role';

    when 'menu_item_taxes' then
      select m.business_id, m.name
        into business_id, label
      from public.menu_items m
      where m.id = (p_row ->> 'item_id')::uuid;
      select t.name into context
      from public.taxes t
      where t.id = (p_row ->> 'tax_id')::uuid;
      row_id := concat(p_row ->> 'item_id', ':', p_row ->> 'tax_id');

    when 'menu_item_groups' then
      select m.business_id, m.name
        into business_id, label
      from public.menu_items m
      where m.id = (p_row ->> 'menu_item_id')::uuid;
      select g.name into context
      from public.modifier_groups g
      where g.id = (p_row ->> 'group_id')::uuid;
      row_id := concat(p_row ->> 'menu_item_id', ':', p_row ->> 'group_id');

    when 'menu_item_links' then
      select mn.business_id, mn.name
        into business_id, context
      from public.menus mn
      where mn.id = (p_row ->> 'menu_id')::uuid;
      select m.name into label
      from public.menu_items m
      where m.id = (p_row ->> 'item_id')::uuid;
      row_id := concat(p_row ->> 'menu_id', ':', p_row ->> 'item_id');

    when 'menu_item_print_areas' then
      select m.business_id, m.name
        into business_id, label
      from public.menu_items m
      where m.id = (p_row ->> 'menu_item_id')::uuid;
      select pa.name into context
      from public.print_areas pa
      where pa.id = (p_row ->> 'print_area_id')::uuid;
      row_id := concat(p_row ->> 'menu_item_id', ':', p_row ->> 'print_area_id');

    when 'combo_group_items' then
      select g.business_id, g.name
        into business_id, context
      from public.combo_groups g
      where g.id = (p_row ->> 'combo_group_id')::uuid;
      select m.name into label
      from public.menu_items m
      where m.id = (p_row ->> 'menu_item_id')::uuid;

    when 'modifier_ingredients' then
      select md.business_id, md.name
        into business_id, label
      from public.modifiers md
      where md.id = (p_row ->> 'modifier_id')::uuid;
      select i.name into context
      from public.inventory_items i
      where i.id = (p_row ->> 'inventory_item_id')::uuid;

    when 'print_area_printers' then
      business_id := (p_row ->> 'business_id')::uuid;
      select pa.name into label
      from public.print_areas pa
      where pa.id = (p_row ->> 'area_id')::uuid;
      select p.name into context
      from public.printers p
      where p.id = (p_row ->> 'printer_id')::uuid;

    when 'device_printer_bindings' then
      select p.business_id, p.name
        into business_id, label
      from public.printers p
      where p.id = (p_row ->> 'printer_id')::uuid;
      context := p_row ->> 'device_id';
      row_id := concat(p_row ->> 'device_id', ':', p_row ->> 'printer_id');

    when 'supplier_items' then
      business_id := (p_row ->> 'business_id')::uuid;
      select s.name into label
      from public.suppliers s
      where s.id = (p_row ->> 'supplier_id')::uuid;
      select i.name into context
      from public.inventory_items i
      where i.id = (p_row ->> 'inventory_item_id')::uuid;

    when 'inventory_item_presentations' then
      business_id := (p_row ->> 'business_id')::uuid;
      select i.name into label
      from public.inventory_items i
      where i.id = (p_row ->> 'item_id')::uuid;
      context := p_row ->> 'unit';

    when 'employee_roles' then
      select e.business_id, trim(concat_ws(' ', e.first_name, e.last_name))
        into business_id, label
      from public.employees e
      where e.id = (p_row ->> 'employee_id')::uuid;
      select r.name into context
      from public.roles r
      where r.id = (p_row ->> 'role_id')::uuid;
      row_id := concat(p_row ->> 'employee_id', ':', p_row ->> 'role_id');

    when 'role_permissions' then
      select r.business_id, r.name
        into business_id, label
      from public.roles r
      where r.id = (p_row ->> 'role_id')::uuid;
      select coalesce(nullif(p.name, ''), p.code) into context
      from public.permissions p
      where p.id = (p_row ->> 'permission_id')::uuid;
      row_id := concat(p_row ->> 'role_id', ':', p_row ->> 'permission_id');

    when 'user_permission_overrides' then
      business_id := (p_row ->> 'business_id')::uuid;
      label := private.fn_change_history_person(business_id, (p_row ->> 'user_id')::uuid);
      select coalesce(nullif(p.name, ''), p.code) into context
      from public.permissions p
      where p.id = (p_row ->> 'permission_id')::uuid;
      row_id := concat(p_row ->> 'user_id', ':', p_row ->> 'permission_id');

    when 'recipes' then
      if p_row ->> 'menu_item_id' is not null then
        select m.business_id, m.name
          into business_id, label
        from public.menu_items m
        where m.id = (p_row ->> 'menu_item_id')::uuid;
      end if;
      if business_id is null and p_row ->> 'inventory_item_id' is not null then
        select i.business_id, i.name
          into business_id, label
        from public.inventory_items i
        where i.id = (p_row ->> 'inventory_item_id')::uuid;
      end if;

    when 'recipe_ingredients' then
      select to_jsonb(r) into v_parent
      from public.recipes r
      where r.id = (p_row ->> 'recipe_id')::uuid;
      if v_parent is not null then
        select s.business_id, s.label
          into business_id, label
        from private.fn_change_history_scope('recipes', v_parent) s;
      end if;
      select i.name into context
      from public.inventory_items i
      where i.id = (p_row ->> 'inventory_item_id')::uuid;

    when 'bank_accounts' then
      business_id := (p_row ->> 'business_id')::uuid;
      label := concat_ws(' · ', nullif(p_row ->> 'bank_name', ''),
                                nullif(p_row ->> 'alias', ''));

    when 'reservations' then
      business_id := (p_row ->> 'business_id')::uuid;
      label := p_row ->> 'customer_name';
      context := private.fn_change_history_table_label((p_row ->> 'table_id')::uuid);

    when 'purchase_orders', 'purchase_receptions', 'direct_receipts' then
      business_id := (p_row ->> 'business_id')::uuid;
      label := coalesce(p_row ->> 'order_number', p_row ->> 'reception_number',
                        p_row ->> 'receipt_number');
      select s.name into context
      from public.suppliers s
      where s.id = (p_row ->> 'supplier_id')::uuid;

    when 'stock_transfers', 'requisitions' then
      business_id := (p_row ->> 'business_id')::uuid;
      label := coalesce(p_row ->> 'transfer_number', p_row ->> 'code');
      select concat_ws(' → ', wf.name, wt.name) into context
      from (select 1) x
      left join public.warehouses wf on wf.id = (p_row ->> 'from_warehouse_id')::uuid
      left join public.warehouses wt on wt.id = (p_row ->> 'to_warehouse_id')::uuid;

    when 'physical_count_sessions' then
      business_id := (p_row ->> 'business_id')::uuid;
      label := p_row ->> 'code';
      select w.name into context
      from public.warehouses w
      where w.id = (p_row ->> 'warehouse_id')::uuid;

    when 'production_orders' then
      business_id := (p_row ->> 'business_id')::uuid;
      label := p_row ->> 'code';
      select i.name into context
      from public.inventory_items i
      where i.id = (p_row ->> 'finished_item_id')::uuid;

    when 'accounting_accounts' then
      business_id := (p_row ->> 'business_id')::uuid;
      label := p_row ->> 'name';
      context := p_row ->> 'code';

    when 'external_api_keys' then
      business_id := (p_row ->> 'business_id')::uuid;
      label := p_row ->> 'channel';
      context := p_row ->> 'key_prefix';

    else
      business_id := (p_row ->> 'business_id')::uuid;
      label := coalesce(
        nullif(p_row ->> 'name', ''),
        nullif(p_row ->> 'label', ''),
        nullif(p_row ->> 'code', ''),
        nullif(p_row ->> 'prefix', ''),
        nullif(p_row ->> 'business_legal_name', ''),
        '');
  end case;

  label := coalesce(label, '');
  context := coalesce(context, '');
end;
$$;

-- El trigger general: igual que 0001, con el valor por tabla y las semillas
-- de contabilidad (fn_accounting_seed_chart) también fuera.
create or replace function public.fn_change_history_record()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old     jsonb := case when tg_op <> 'INSERT' then to_jsonb(old) end;
  v_new     jsonb := case when tg_op <> 'DELETE' then to_jsonb(new) end;
  v_source  text  := nullif(current_setting('request.path', true), '');
  v_actor   uuid  := auth.uid();
  v_scope   record;
  v_action  text;
  v_changes jsonb := '{}'::jsonb;
  v_prev    record;
  v_merged  jsonb;
  k         text;
begin
  -- Lo que cae en cascada ya lo dice el cambio que lo provocó.
  if pg_trigger_depth() > 1 then
    return null;
  end if;
  -- Valores por defecto que siembra el sistema: no son cambios de nadie.
  if v_source ~ '/rpc/fn_[a-z_]*seed' then
    return null;
  end if;

  begin
    select * into v_scope
    from private.fn_change_history_scope(tg_table_name, coalesce(v_new, v_old));
    if v_scope.business_id is null or v_scope.row_id is null then
      return null;
    end if;
    -- Se está borrando el negocio completo: no hay a quién contárselo.
    if not exists (select 1 from public.businesses b where b.id = v_scope.business_id) then
      return null;
    end if;

    if tg_op = 'UPDATE' then
      v_action := 'update';
      for k in select jsonb_object_keys(v_old || v_new) loop
        continue when not private.fn_change_history_keep(tg_table_name, k, v_source);
        if (v_old -> k) is distinct from (v_new -> k) then
          v_changes := v_changes || jsonb_build_object(k, jsonb_build_array(
            coalesce(private.fn_change_history_render(tg_table_name, k, v_old -> k, 'old'), 'null'::jsonb),
            coalesce(private.fn_change_history_render(tg_table_name, k, v_new -> k, 'new'), 'null'::jsonb)));
        end if;
      end loop;
      -- El auto-86 (stock en cero) apaga y prende el producto solo.
      if tg_table_name = 'menu_items'
         and (v_old -> 'auto_disabled') is distinct from (v_new -> 'auto_disabled') then
        v_changes := v_changes - 'is_active';
      end if;
      if v_changes = '{}'::jsonb then
        return null;
      end if;
    else
      v_action := case tg_op when 'INSERT' then 'create' else 'delete' end;
      v_changes := private.fn_change_history_snapshot(
        tg_table_name, coalesce(v_new, v_old), v_source);
    end if;

    -- Un mismo guardado puede tocar la fila varias veces: se anota el neto.
    select h.id, h.action, h.changes
      into v_prev
    from public.change_history h
    where h.business_id = v_scope.business_id
      and h.row_id = v_scope.row_id
      and h.table_name = tg_table_name
      and h.txid = txid_current()
      and h.ref_id is null
    order by h.id desc
    limit 1;

    if v_prev.id is not null then
      v_merged := private.fn_change_history_merge(
        v_prev.action, v_prev.changes, v_action, v_changes);
      if v_merged is null then
        delete from public.change_history h where h.id = v_prev.id;
        return null;
      elsif v_merged ? 'action' then
        update public.change_history h
           set action  = v_merged ->> 'action',
               changes = v_merged -> 'changes',
               label   = coalesce(nullif(v_scope.label, ''), h.label),
               context = coalesce(nullif(v_scope.context, ''), h.context)
         where h.id = v_prev.id;
        return null;
      end if;
    end if;

    insert into public.change_history (
      business_id, table_name, row_id, action, label, context,
      actor_user_id, actor_name, changes, source
    )
    values (
      v_scope.business_id, tg_table_name, v_scope.row_id, v_action,
      v_scope.label, v_scope.context, v_actor,
      private.fn_change_history_person(v_scope.business_id, v_actor),
      v_changes, v_source
    );
  exception when others then
    raise warning 'fn_change_history_record(%): % (%)', tg_table_name, sqlerrm, sqlstate;
  end;
  return null;
end;
$$;

-- Anular la cuenta: igual que 0001, salvo cuando la anula un traslado a una
-- mesa ocupada (eso es «pasó la cuenta», lo anota el trigger de order_items).
create or replace function public.fn_change_history_on_order_void()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_business uuid;
  v_table    text;
  v_paid     numeric;
  v_items    integer;
  v_ncf      text;
  v_actor    uuid := auth.uid();
begin
  begin
    if private.fn_change_history_called_from('fn_transfer_table_session') then
      return null;
    end if;

    select ts.business_id,
           case
             when dt.id is not null then coalesce(dt.label, dt.code, 'Mesa')
             when ts.origin::text = 'manual' then 'Venta manual'
             when ts.origin::text in ('quick', 'quick_sale') then 'Venta rápida'
             else 'Venta'
           end
      into v_business, v_table
    from public.table_sessions ts
    left join public.dining_tables dt on dt.id = ts.table_id
    where ts.id = new.session_id;
    v_business := coalesce((to_jsonb(new) ->> 'business_id')::uuid, v_business);
    if v_business is null then
      return null;
    end if;

    if exists (
      select 1 from public.change_history h
      where h.business_id = v_business
        and h.table_name = 'orders'
        and h.row_id = new.id::text
        and h.action = 'void'
    ) then
      return null;
    end if;

    -- La anulación pasa la orden a 'void' ANTES de cancelar los pagos y los
    -- ítems: aquí todavía se ven como estaban.
    select coalesce(sum(p.amount), 0)
      into v_paid
    from public.payments p
    where p.order_id = new.id
      and p.status = 'completed';

    select count(*)
      into v_items
    from public.order_items i
    where i.order_id = new.id
      and coalesce(i.status::text, 'draft') <> 'void'
      and (coalesce(i.status::text, 'draft') <> 'draft'
           or to_jsonb(i) ->> 'kitchen_sent_at' is not null);

    -- Mesa vacía o solo borradores: no salió nada ni se cobró nada.
    if v_paid = 0 and v_items = 0 then
      return null;
    end if;

    select string_agg(distinct coalesce(to_jsonb(fd) ->> 'ncf',
                                        to_jsonb(fd) ->> 'ncf_number'), ', ')
      into v_ncf
    from public.payments p
    join public.fiscal_documents fd on fd.id = p.fiscal_document_id
    where p.order_id = new.id
      and p.status = 'completed';

    insert into public.change_history (
      business_id, table_name, row_id, action, label, context,
      actor_user_id, actor_name, changes, source
    )
    values (
      v_business, 'orders', new.id::text, 'void', coalesce(v_table, 'Venta'),
      coalesce(v_ncf, ''), v_actor,
      private.fn_change_history_person(v_business, v_actor),
      jsonb_strip_nulls(jsonb_build_object(
        'total', new.total,
        'paid_total', nullif(v_paid, 0),
        'items_count', v_items,
        'ncf', v_ncf)),
      nullif(current_setting('request.path', true), '')
    );
  exception when others then
    raise warning 'fn_change_history_on_order_void: % (%)', sqlerrm, sqlstate;
  end;
  return null;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Caja
-- ---------------------------------------------------------------------------

-- Entradas, retiros y gastos que hace una persona (llevan motivo). Las filas
-- 'sale' de cada cobro y las que crean abonos o pagos a proveedores (sin
-- motivo) no: esas acciones se anotan en su propia tabla.
create or replace function public.fn_change_history_on_cash_tx()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row    jsonb := to_jsonb(coalesce(new, old));
  v_scope  record;
  v_reason text;
  v_action text := case tg_op when 'INSERT' then 'create'
                              when 'DELETE' then 'delete' else 'update' end;
  v_changes jsonb;
begin
  begin
    select * into v_scope
    from private.fn_change_history_cash_scope((v_row ->> 'session_id')::uuid);

    select coalesce(r.label, r.code) into v_reason
    from public.cash_transaction_reasons r
    where r.id = (v_row ->> 'reason_id')::uuid
       or (r.business_id = v_scope.business_id and r.code = v_row ->> 'reason_code')
    order by (r.id = (v_row ->> 'reason_id')::uuid) desc nulls last
    limit 1;

    v_changes := jsonb_build_object(
      'event', 'cash_' || (v_row ->> 'type'),
      'amount', v_row -> 'amount',
      'reason', coalesce(v_reason, v_row ->> 'reason_code'),
      'description', nullif(v_row ->> 'description', ''),
      'approved_by', case when v_row ->> 'approved_by' is not null
                          then private.fn_change_history_person(
                                 v_scope.business_id, (v_row ->> 'approved_by')::uuid)
                     end);
    if tg_op = 'UPDATE' then
      v_changes := v_changes || jsonb_build_object(
        'amount', jsonb_build_array(old.amount, new.amount));
    end if;

    perform private.fn_change_history_add(
      v_scope.business_id, 'cash_transactions', v_row ->> 'id', v_action,
      v_scope.register, v_reason,
      -- Crear: quien lo registró. Editar o borrar: quien lo hace ahora.
      case when tg_op = 'INSERT'
           then coalesce((v_row ->> 'created_by')::uuid, auth.uid())
           else auth.uid() end,
      null, v_changes,
      case when tg_op = 'INSERT' then (v_row ->> 'created_at')::timestamptz end);
  exception when others then
    raise warning 'fn_change_history_on_cash_tx: % (%)', sqlerrm, sqlstate;
  end;
  return null;
end;
$$;

-- Abrir y cerrar la caja.
create or replace function public.fn_change_history_on_cash_session()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_scope  record;
  v_notes  text;
  v_forced boolean;
begin
  begin
    select * into v_scope from private.fn_change_history_cash_scope(new.id);

    if tg_op = 'INSERT' then
      perform private.fn_change_history_add(
        v_scope.business_id, 'cash_register_sessions', new.id::text, 'create',
        v_scope.register, new.device_name, coalesce(new.user_id, auth.uid()), null,
        jsonb_build_object('event', 'cash_open', 'start_amount', new.start_amount),
        new.opened_at);
      return null;
    end if;

    -- Las notas traen ids («Cerrado por <uuid> (rol: …)»): se dejan las palabras.
    v_notes := coalesce(new.notes, '');
    v_forced := v_notes ~ 'FORCE_CLOSED';
    v_notes := regexp_replace(v_notes, '\s*\|?\s*Cerrado por [0-9a-fA-F-]{36} \(rol: [^)]*\)', '', 'g');
    v_notes := regexp_replace(v_notes, '\[FORCE_CLOSED by [0-9a-fA-F-]{36} on [0-9-]+ [0-9:]+:\s*', '[Cierre forzado: ', 'g');
    v_notes := nullif(btrim(v_notes, ' |'), '');

    perform private.fn_change_history_add(
      v_scope.business_id, 'cash_register_sessions', new.id::text, 'update',
      v_scope.register, new.device_name, auth.uid(), null,
      jsonb_build_object(
        'event', case
                   when new.status = 'closed' and v_forced then 'cash_force_close'
                   when new.status = 'closed' then 'cash_close'
                   else 'cash_status'
                 end,
        'status', jsonb_build_array(old.status, new.status),
        'start_amount', new.start_amount,
        'end_amount', new.end_amount,
        'difference', new.difference,
        'notes', v_notes));
  exception when others then
    raise warning 'fn_change_history_on_cash_session: % (%)', sqlerrm, sqlstate;
  end;
  return null;
end;
$$;

-- Reconteo y pasar la caja a otro equipo (las anota la app en audit_logs).
create or replace function public.fn_change_history_on_audit_log()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_scope  record;
  v_reason jsonb;
begin
  begin
    select * into v_scope from private.fn_change_history_cash_scope(new.ref_id);
    if new.action = 'cash_recount' then
      begin
        v_reason := new.reason::jsonb;
      exception when others then
        v_reason := null;
      end;
      if jsonb_typeof(v_reason) is distinct from 'object' then
        v_reason := jsonb_build_object('notes', new.reason);
      end if;
      perform private.fn_change_history_add(
        coalesce(v_scope.business_id, new.business_id), 'cash_register_sessions',
        coalesce(new.ref_id::text, new.id::text), 'update', v_scope.register,
        v_scope.device, coalesce(new.user_id, auth.uid()), null,
        jsonb_build_object('event', 'cash_recount') || coalesce(
          (select jsonb_object_agg(k, v) from jsonb_each(v_reason) e(k, v)
           where k in ('cash', 'card', 'transfer', 'notes')), '{}'::jsonb),
        new.created_at);
    else
      perform private.fn_change_history_add(
        coalesce(v_scope.business_id, new.business_id), 'cash_register_sessions',
        coalesce(new.ref_id::text, new.id::text), 'update', v_scope.register,
        v_scope.device, coalesce(new.user_id, auth.uid()), null,
        jsonb_build_object('event', 'cash_move', 'detail', new.reason),
        new.created_at);
    end if;
  exception when others then
    raise warning 'fn_change_history_on_audit_log: % (%)', sqlerrm, sqlstate;
  end;
  return null;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Cuentas
-- ---------------------------------------------------------------------------

-- Pasar la cuenta entera a una mesa libre: la sesión cambia de mesa.
create or replace function public.fn_change_history_on_session_move()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  begin
    if not private.fn_change_history_called_from('fn_transfer_table_session') then
      return null;
    end if;
    perform private.fn_change_history_add(
      new.business_id, 'table_sessions', new.id::text, 'update',
      private.fn_change_history_table_label(old.table_id),
      private.fn_change_history_table_label(new.table_id),
      auth.uid(), null, jsonb_build_object('event', 'table_transfer'));
  exception when others then
    raise warning 'fn_change_history_on_session_move: % (%)', sqlerrm, sqlstate;
  end;
  return null;
end;
$$;

-- Pasar productos a otra mesa (o la cuenta a una mesa ocupada): una línea por
-- traslado con la lista de productos.
create or replace function public.fn_change_history_on_items_move()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_business uuid;
  v_from     text;
  v_to       text;
  v_name     text;
  v_qty      numeric;
  v_prev     record;
begin
  begin
    if not private.fn_change_history_called_from('fn_transfer_table_session') then
      return null;
    end if;
    select ts.business_id into v_business
    from public.orders o
    join public.table_sessions ts on ts.id = o.session_id
    where o.id = new.order_id;
    v_business := coalesce((to_jsonb(new) ->> 'business_id')::uuid, v_business);
    v_from := private.fn_change_history_order_label(old.order_id);
    v_to := private.fn_change_history_order_label(new.order_id);
    v_name := coalesce(nullif(to_jsonb(new) ->> 'product_name', ''),
                       (select m.name from public.menu_items m
                        where m.id = (to_jsonb(new) ->> 'product_id')::uuid),
                       'Producto');
    v_qty := coalesce((to_jsonb(new) ->> 'qty')::numeric,
                      (to_jsonb(new) ->> 'quantity')::numeric, 1);

    select h.id, h.changes into v_prev
    from public.change_history h
    where h.business_id = v_business
      and h.table_name = 'table_sessions'
      and h.txid = txid_current()
      and h.changes ->> 'event' = 'items_transfer'
      and h.label = coalesce(v_from, '')
      and h.context = coalesce(v_to, '')
    order by h.id desc
    limit 1;

    if v_prev.id is null then
      perform private.fn_change_history_add(
        v_business, 'table_sessions', old.order_id::text, 'update', v_from, v_to,
        auth.uid(), null,
        jsonb_build_object('event', 'items_transfer', 'items_count', 1,
                           'products', jsonb_build_array(
                             concat(trim_scale(v_qty)::text, ' × ', v_name))));
    else
      update public.change_history h
         set changes = h.changes
               || jsonb_build_object(
                    'items_count', coalesce((h.changes ->> 'items_count')::int, 0) + 1,
                    'products', coalesce(h.changes -> 'products', '[]'::jsonb)
                                || to_jsonb(concat(trim_scale(v_qty)::text, ' × ', v_name)))
       where h.id = v_prev.id;
    end if;
  exception when others then
    raise warning 'fn_change_history_on_items_move: % (%)', sqlerrm, sqlstate;
  end;
  return null;
end;
$$;

-- Descuentos y cortesías: solo los que pide alguien (fn_update_item_discount,
-- vía fn_apply_order_edit). Repartir un descuento en la cuenta toca varias
-- líneas: se juntan en una sola por cuenta y persona (2 minutos).
create or replace function public.fn_change_history_on_discount()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_business uuid;
  v_actor    uuid := auth.uid();
  v_name     text;
  v_items    jsonb;
  v_prev     record;
  v_before   numeric := 0;
  v_after    numeric := 0;
  v_courtesy text;
  v_line     jsonb;
begin
  begin
    if not private.fn_change_history_called_from('fn_update_item_discount[a-z_]*') then
      return null;
    end if;
    select ts.business_id into v_business
    from public.orders o
    join public.table_sessions ts on ts.id = o.session_id
    where o.id = new.order_id;
    v_business := coalesce((to_jsonb(new) ->> 'business_id')::uuid, v_business);
    v_name := coalesce(nullif(to_jsonb(new) ->> 'product_name', ''),
                       (select m.name from public.menu_items m
                        where m.id = (to_jsonb(new) ->> 'product_id')::uuid),
                       'Producto');
    v_courtesy := substring(coalesce(new.notes, '') from '\[CORTESIA:([^\]]*)\]');

    select h.id, h.changes into v_prev
    from public.change_history h
    where h.business_id = v_business
      and h.table_name = 'orders'
      and h.row_id = new.order_id::text
      and h.changes ->> 'event' = 'discount'
      and h.actor_user_id is not distinct from v_actor
      and h.changed_at > clock_timestamp() - interval '2 minutes'
    order by h.id desc
    limit 1;

    v_items := coalesce(v_prev.changes -> 'lines', '{}'::jsonb);
    v_line := v_items -> new.id::text;
    v_items := v_items || jsonb_build_object(new.id::text, jsonb_build_object(
      'name', v_name,
      'before', coalesce(v_line -> 'before', to_jsonb(coalesce(old.discounts, 0))),
      'after', to_jsonb(coalesce(new.discounts, 0))));
    select coalesce(sum((l.value ->> 'before')::numeric), 0),
           coalesce(sum((l.value ->> 'after')::numeric), 0)
      into v_before, v_after
    from jsonb_each(v_items) l;

    if v_prev.id is null then
      perform private.fn_change_history_add(
        v_business, 'orders', new.order_id::text, 'update',
        private.fn_change_history_order_label(new.order_id), '', v_actor, null,
        jsonb_build_object('event', 'discount', 'lines', v_items,
                           'discount', jsonb_build_array(v_before, v_after),
                           'courtesy', v_courtesy));
    else
      update public.change_history h
         set changes = jsonb_strip_nulls(h.changes || jsonb_build_object(
               'lines', v_items,
               'discount', jsonb_build_array(v_before, v_after),
               'courtesy', coalesce(v_courtesy, h.changes ->> 'courtesy')))
       where h.id = v_prev.id;
    end if;
  exception when others then
    raise warning 'fn_change_history_on_discount: % (%)', sqlerrm, sqlstate;
  end;
  return null;
end;
$$;

-- Cambiar el método de un pago ya hecho.
create or replace function public.fn_change_history_on_payment_method()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  begin
    perform private.fn_change_history_add(
      new.business_id, 'payments', new.id::text, 'update',
      coalesce(private.fn_change_history_order_label(new.order_id), 'Venta'), '',
      auth.uid(), null,
      jsonb_build_object(
        'event', 'payment_method',
        'payment_method', jsonb_build_array(
          (select pm.name from public.payment_methods pm where pm.id = old.payment_method_id),
          (select pm.name from public.payment_methods pm where pm.id = new.payment_method_id)),
        'amount', new.amount));
  exception when others then
    raise warning 'fn_change_history_on_payment_method: % (%)', sqlerrm, sqlstate;
  end;
  return null;
end;
$$;

-- Cambio de mesero (fn_reassign_table_waiter ya lo registra; se copia).
create or replace function public.fn_change_history_on_waiter_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  begin
    perform private.fn_change_history_add(
      new.business_id, 'table_sessions', new.session_id::text, 'update',
      private.fn_change_history_table_label(new.table_id), '',
      coalesce(new.changed_by, auth.uid()), null,
      jsonb_build_object(
        'event', 'waiter_change',
        'waiter', jsonb_build_array(
          private.fn_change_history_person(new.business_id, null, new.from_employee_id),
          private.fn_change_history_person(new.business_id, null, new.to_employee_id)),
        'reason', nullif(new.reason, '')),
      new.created_at);
  exception when others then
    raise warning 'fn_change_history_on_waiter_change: % (%)', sqlerrm, sqlstate;
  end;
  return null;
end;
$$;

-- Nota de crédito (una factura nueva que apunta a otra).
create or replace function public.fn_change_history_on_credit_note()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row jsonb := to_jsonb(new);
begin
  begin
    perform private.fn_change_history_add(
      (v_row ->> 'business_id')::uuid, 'fiscal_documents', new.id::text, 'create',
      coalesce(v_row ->> 'ncf_number', v_row ->> 'ncf'),
      (select coalesce(to_jsonb(fd) ->> 'ncf_number', to_jsonb(fd) ->> 'ncf')
       from public.fiscal_documents fd where fd.id = new.related_document_id),
      coalesce((v_row ->> 'issued_by')::uuid, auth.uid()), null,
      jsonb_build_object('event', 'credit_note', 'total', v_row -> 'total',
                         'reason', v_row ->> 'modification_reason',
                         'customer', v_row ->> 'customer_name'));
  exception when others then
    raise warning 'fn_change_history_on_credit_note: % (%)', sqlerrm, sqlstate;
  end;
  return null;
end;
$$;

-- Anular una nota de venta (no fiscal).
create or replace function public.fn_change_history_on_sales_note_void()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  begin
    perform private.fn_change_history_add(
      new.business_id, 'sales_notes', new.id::text, 'void', new.note_number,
      new.customer_name, coalesce(new.cancelled_by, auth.uid()), null,
      jsonb_build_object('total', new.total,
                         'reason', nullif(new.cancellation_reason, '')));
  exception when others then
    raise warning 'fn_change_history_on_sales_note_void: % (%)', sqlerrm, sqlstate;
  end;
  return null;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Créditos, abonos por mesa y sellos
-- ---------------------------------------------------------------------------

create or replace function public.fn_change_history_on_credit_payment()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row      jsonb := to_jsonb(new);
  v_business uuid;
  v_customer text;
begin
  begin
    select cc.business_id, c.name
      into v_business, v_customer
    from public.customer_credits cc
    left join public.customers c on c.id = cc.customer_id
    where cc.id = new.credit_id;
    perform private.fn_change_history_add(
      coalesce((v_row ->> 'business_id')::uuid, v_business), 'credit_payments',
      new.id::text, 'create', coalesce(v_row ->> 'code', ''), v_customer,
      coalesce(new.received_by, auth.uid()), null,
      jsonb_build_object(
        'event', 'abono', 'amount', new.amount,
        'payment_method', (select pm.name from public.payment_methods pm
                           where pm.id = new.payment_method_id),
        'reference', nullif(new.reference, '')),
      new.created_at);
  exception when others then
    raise warning 'fn_change_history_on_credit_payment: % (%)', sqlerrm, sqlstate;
  end;
  return null;
end;
$$;

-- Cancelar un crédito de cliente a mano (el que cancela el sistema al anular
-- el pago es parte de esa anulación: pg_trigger_depth > 1).
create or replace function public.fn_change_history_on_credit_cancel()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  begin
    if pg_trigger_depth() > 1 then
      return null;
    end if;
    perform private.fn_change_history_add(
      new.business_id, 'customer_credits', new.id::text, 'void',
      (select c.name from public.customers c where c.id = new.customer_id), '',
      coalesce((to_jsonb(new) ->> 'cancelled_by')::uuid, auth.uid()), null,
      jsonb_build_object('event', 'credit_cancel', 'balance', new.balance,
                         'original_amount', new.original_amount,
                         'notes', nullif(new.notes, '')));
  exception when others then
    raise warning 'fn_change_history_on_credit_cancel: % (%)', sqlerrm, sqlstate;
  end;
  return null;
end;
$$;

-- Cuentas por pagar: crear y cancelar.
create or replace function public.fn_change_history_on_payable()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_supplier text;
begin
  begin
    if pg_trigger_depth() > 1 then
      return null;
    end if;
    select s.name into v_supplier from public.suppliers s where s.id = new.supplier_id;
    perform private.fn_change_history_add(
      new.business_id, 'supplier_credits', new.id::text,
      case when tg_op = 'INSERT' then 'create' else 'void' end,
      v_supplier, coalesce(new.invoice_number, ''),
      coalesce(case when tg_op = 'INSERT' then new.created_by end, auth.uid()), null,
      jsonb_build_object(
        'event', case when tg_op = 'INSERT' then 'payable_create' else 'payable_cancel' end,
        'original_amount', new.original_amount,
        'balance', case when tg_op = 'UPDATE' then new.balance end,
        'due_date', new.due_date,
        'ncf', to_jsonb(new) ->> 'ncf',
        'notes', nullif(new.notes, '')));
  exception when others then
    raise warning 'fn_change_history_on_payable: % (%)', sqlerrm, sqlstate;
  end;
  return null;
end;
$$;

create or replace function public.fn_change_history_on_supplier_payment()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_business uuid;
  v_supplier text;
  v_invoice  text;
begin
  begin
    select sc.business_id, s.name, sc.invoice_number
      into v_business, v_supplier, v_invoice
    from public.supplier_credits sc
    left join public.suppliers s on s.id = sc.supplier_id
    where sc.id = new.supplier_credit_id;
    perform private.fn_change_history_add(
      v_business, 'supplier_credit_payments', new.id::text, 'create',
      v_supplier, coalesce(v_invoice, ''), coalesce(new.paid_by, auth.uid()), null,
      jsonb_build_object(
        'event', 'supplier_payment', 'amount', new.amount,
        'payment_method', coalesce(
          (select pm.name from public.payment_methods pm
           where pm.business_id = v_business and pm.code = new.payment_method_code
           limit 1), new.payment_method_code),
        'reference', nullif(new.reference, '')),
      new.created_at);
  exception when others then
    raise warning 'fn_change_history_on_supplier_payment: % (%)', sqlerrm, sqlstate;
  end;
  return null;
end;
$$;

-- Abonos por mesa: recibir, devolver, pasar a otra mesa.
create or replace function public.fn_change_history_on_table_deposit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  begin
    perform private.fn_change_history_add(
      new.business_id, 'table_deposit_movements', new.id::text, 'create',
      private.fn_change_history_table_label(new.table_id),
      private.fn_change_history_table_label(new.related_table_id),
      coalesce(new.created_by, auth.uid()), null,
      jsonb_build_object(
        'event', 'deposit_' || new.type,
        'amount', abs(new.amount),
        'balance_after', new.balance_after,
        'payment_method', (select pm.name from public.payment_methods pm
                           where pm.id = new.payment_method_id),
        'reference', nullif(new.reference, ''),
        'notes', nullif(new.note, '')),
      new.created_at);
  exception when others then
    raise warning 'fn_change_history_on_table_deposit: % (%)', sqlerrm, sqlstate;
  end;
  return null;
end;
$$;

create or replace function public.fn_change_history_on_stamps()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  begin
    perform private.fn_change_history_add(
      new.business_id, 'loyalty_stamp_adjustments', new.id::text, 'create',
      (select c.name from public.customers c where c.id = new.customer_id),
      (select p.name from public.loyalty_stamp_programs p where p.id = new.program_id),
      coalesce(new.created_by, auth.uid()), null,
      jsonb_build_object('event', 'stamps_adjust', 'stamps', new.stamps,
                         'reason', new.reason),
      new.created_at);
  exception when others then
    raise warning 'fn_change_history_on_stamps: % (%)', sqlerrm, sqlstate;
  end;
  return null;
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Inventario
-- ---------------------------------------------------------------------------

-- Ajustes, salidas e inventario inicial. Corre al COMMIT (constraint trigger
-- diferido): fn_inventory_adjust y fn_inventory_record_outflow ponen el
-- motivo con un UPDATE justo después del INSERT, y aquí se lee ya completo.
create or replace function public.fn_change_history_on_stock_move()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row   jsonb;
  v_type  text;
  v_ref   text;
begin
  begin
    select to_jsonb(m) into v_row
    from public.inventory_movements m
    where m.id = new.id;
    if v_row is null then
      return null;
    end if;
    v_type := v_row ->> 'movement_type';
    v_ref := coalesce(v_row ->> 'reference_type', '');
    perform private.fn_change_history_add(
      (v_row ->> 'business_id')::uuid, 'inventory_movements', v_row ->> 'id', 'create',
      (select i.name from public.inventory_items i where i.id = (v_row ->> 'item_id')::uuid),
      (select w.name from public.warehouses w where w.id = (v_row ->> 'warehouse_id')::uuid),
      coalesce((v_row ->> 'created_by')::uuid, auth.uid()), null,
      jsonb_build_object(
        'event', case
                   when v_ref in ('initial_stock', 'inventory_setup') then 'stock_initial'
                   when v_type = 'waste' then 'stock_outflow'
                   when v_type = 'adjustment' then 'stock_adjust'
                   else 'stock_move'
                 end,
        'quantity', v_row -> 'quantity',
        'cost_per_unit', v_row -> 'cost_per_unit',
        'reason_code', v_row ->> 'reason_code',
        'destination', nullif(v_row ->> 'destination', ''),
        'notes', nullif(v_row ->> 'notes', '')),
      (v_row ->> 'created_at')::timestamptz);
  exception when others then
    raise warning 'fn_change_history_on_stock_move: % (%)', sqlerrm, sqlstate;
  end;
  return null;
end;
$$;

-- Activos fijos: ya llevan su propio registro (fixed_asset_movements); se copia.
create or replace function public.fn_change_history_on_asset()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_changes jsonb := jsonb_build_object('event', 'asset_' || new.event_type);
  k text;
begin
  begin
    if new.from_warehouse_name is distinct from new.to_warehouse_name
       and new.event_type <> 'created' then
      v_changes := v_changes || jsonb_build_object('warehouse_id',
        jsonb_build_array(new.from_warehouse_name, new.to_warehouse_name));
    end if;
    if new.from_location_note is distinct from new.to_location_note then
      v_changes := v_changes || jsonb_build_object('location_note',
        jsonb_build_array(new.from_location_note, new.to_location_note));
    end if;
    if new.from_employee_name is distinct from new.to_employee_name then
      v_changes := v_changes || jsonb_build_object('assigned_employee_id',
        jsonb_build_array(new.from_employee_name, new.to_employee_name));
    end if;
    if new.from_status is distinct from new.to_status then
      v_changes := v_changes || jsonb_build_object('status',
        jsonb_build_array(new.from_status, new.to_status));
    end if;
    -- {campo: {from, to}} → {campo: [antes, después]}
    if jsonb_typeof(new.changes) = 'object' then
      for k in select jsonb_object_keys(new.changes) loop
        v_changes := v_changes || jsonb_build_object(k, jsonb_build_array(
          coalesce(new.changes -> k -> 'from', 'null'::jsonb),
          coalesce(new.changes -> k -> 'to', 'null'::jsonb)));
      end loop;
    end if;
    v_changes := v_changes || jsonb_build_object('notes', nullif(new.notes, ''));

    perform private.fn_change_history_add(
      new.business_id, 'fixed_assets', new.asset_id::text,
      case new.event_type when 'created' then 'create'
                          when 'retired' then 'delete' else 'update' end,
      (select a.name from public.fixed_assets a where a.id = new.asset_id),
      (select a.code from public.fixed_assets a where a.id = new.asset_id),
      coalesce(new.created_by, auth.uid()), null, v_changes, new.created_at);
  exception when others then
    raise warning 'fn_change_history_on_asset: % (%)', sqlerrm, sqlstate;
  end;
  return null;
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. Seguridad: cerrar la sesión de un equipo a distancia
-- ---------------------------------------------------------------------------
create or replace function public.fn_change_history_on_device_revoke()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  begin
    perform private.fn_change_history_add(
      new.business_id, 'device_sessions', new.id::text, 'update',
      coalesce(nullif(new.label, ''), nullif(new.device_name, ''),
               nullif(new.hostname, ''), new.device_id),
      coalesce(nullif(new.employee_name, ''), nullif(new.user_name, ''), new.user_email),
      coalesce(new.revoked_by, auth.uid()), null,
      jsonb_build_object('event', 'device_revoke', 'user_email', new.user_email));
  exception when others then
    raise warning 'fn_change_history_on_device_revoke: % (%)', sqlerrm, sqlstate;
  end;
  return null;
end;
$$;

-- ---------------------------------------------------------------------------
-- 8. Arreglo: anulaciones que en realidad fueron traslados (0001)
-- ---------------------------------------------------------------------------
update public.change_history h
   set table_name = 'table_sessions',
       action = 'update',
       context = '',
       changes = h.changes || '{"event": "items_transfer"}'::jsonb
 where h.table_name = 'orders'
   and h.action = 'void'
   and h.source like '%/rpc/fn_transfer_table_session%';

-- ---------------------------------------------------------------------------
-- 9. Triggers (lo último: sus candados duran hasta el COMMIT)
-- ---------------------------------------------------------------------------
do $$
declare
  t text;
begin
  -- Trigger general: crear, editar y borrar.
  foreach t in array array[
    'menu_item_links', 'combo_group_items', 'modifier_ingredients',
    'menu_item_print_areas', 'print_area_printers', 'device_printer_bindings',
    'supplier_items', 'inventory_item_presentations', 'accounting_accounts',
    'accounting_cost_centers', 'loyalty_stamp_programs',
    'order_item_removal_reasons', 'gift_cards', 'external_api_keys',
    'reservations', 'purchase_orders', 'purchase_receptions',
    'direct_receipts', 'stock_transfers', 'physical_count_sessions',
    'requisitions', 'production_orders'
  ] loop
    if to_regclass('public.' || t) is null then
      raise notice 'change_history: la tabla % no existe, se salta', t;
      continue;
    end if;
    execute format('drop trigger if exists trg_zz_change_history on public.%I', t);
    execute format(
      'create trigger trg_zz_change_history '
      'after insert or update or delete on public.%I '
      'for each row execute function public.fn_change_history_record()', t);
  end loop;
end;
$$;

-- Crea un trigger solo si la tabla existe (en vivo puede faltar alguna).
do $$
declare
  r record;
begin
  for r in
    select * from (values
      ('cash_transactions', 'trg_zz_change_history',
       'after insert on public.cash_transactions for each row '
       'when (new.type in (''deposit'', ''withdrawal'', ''expense'') and new.reason_code is not null) '
       'execute function public.fn_change_history_on_cash_tx()'),
      ('cash_transactions', 'trg_zz_change_history_edit',
       'after update or delete on public.cash_transactions for each row '
       'when (old.type in (''deposit'', ''withdrawal'', ''expense'') and old.reason_code is not null) '
       'execute function public.fn_change_history_on_cash_tx()'),
      ('cash_register_sessions', 'trg_zz_change_history',
       'after insert on public.cash_register_sessions for each row '
       'execute function public.fn_change_history_on_cash_session()'),
      ('cash_register_sessions', 'trg_zz_change_history_status',
       'after update of status on public.cash_register_sessions for each row '
       'when (old.status is distinct from new.status) '
       'execute function public.fn_change_history_on_cash_session()'),
      ('audit_logs', 'trg_zz_change_history',
       'after insert on public.audit_logs for each row '
       'when (new.action in (''cash_recount'', ''cash_session_moved_to_device'')) '
       'execute function public.fn_change_history_on_audit_log()'),
      ('table_sessions', 'trg_zz_change_history_move',
       'after update of table_id on public.table_sessions for each row '
       'when (old.table_id is distinct from new.table_id) '
       'execute function public.fn_change_history_on_session_move()'),
      ('order_items', 'trg_zz_change_history_move',
       'after update of order_id on public.order_items for each row '
       'when (old.order_id is distinct from new.order_id) '
       'execute function public.fn_change_history_on_items_move()'),
      ('order_items', 'trg_zz_change_history_discount',
       'after update of discounts on public.order_items for each row '
       'when (old.discounts is distinct from new.discounts) '
       'execute function public.fn_change_history_on_discount()'),
      ('payments', 'trg_zz_change_history_method',
       'after update of payment_method_id on public.payments for each row '
       'when (old.payment_method_id is distinct from new.payment_method_id) '
       'execute function public.fn_change_history_on_payment_method()'),
      ('table_session_waiter_changes', 'trg_zz_change_history',
       'after insert on public.table_session_waiter_changes for each row '
       'execute function public.fn_change_history_on_waiter_change()'),
      ('fiscal_documents', 'trg_zz_change_history_credit_note',
       'after insert on public.fiscal_documents for each row '
       'when (new.related_document_id is not null) '
       'execute function public.fn_change_history_on_credit_note()'),
      ('sales_notes', 'trg_zz_change_history_void',
       'after update of status on public.sales_notes for each row '
       'when (new.status = ''cancelled'' and old.status is distinct from ''cancelled'') '
       'execute function public.fn_change_history_on_sales_note_void()'),
      ('credit_payments', 'trg_zz_change_history',
       'after insert on public.credit_payments for each row '
       'execute function public.fn_change_history_on_credit_payment()'),
      ('customer_credits', 'trg_zz_change_history_cancel',
       'after update of status on public.customer_credits for each row '
       'when (new.status = ''cancelled'' and old.status is distinct from ''cancelled'') '
       'execute function public.fn_change_history_on_credit_cancel()'),
      ('supplier_credits', 'trg_zz_change_history',
       'after insert on public.supplier_credits for each row '
       'execute function public.fn_change_history_on_payable()'),
      ('supplier_credits', 'trg_zz_change_history_cancel',
       'after update of status on public.supplier_credits for each row '
       'when (new.status = ''cancelled'' and old.status is distinct from ''cancelled'') '
       'execute function public.fn_change_history_on_payable()'),
      ('supplier_credit_payments', 'trg_zz_change_history',
       'after insert on public.supplier_credit_payments for each row '
       'execute function public.fn_change_history_on_supplier_payment()'),
      ('table_deposit_movements', 'trg_zz_change_history',
       'after insert on public.table_deposit_movements for each row '
       'when (new.type in (''deposit'', ''refund'', ''transfer_out'', ''adjustment'')) '
       'execute function public.fn_change_history_on_table_deposit()'),
      ('loyalty_stamp_adjustments', 'trg_zz_change_history',
       'after insert on public.loyalty_stamp_adjustments for each row '
       'execute function public.fn_change_history_on_stamps()'),
      ('fixed_asset_movements', 'trg_zz_change_history',
       'after insert on public.fixed_asset_movements for each row '
       'execute function public.fn_change_history_on_asset()'),
      ('device_sessions', 'trg_zz_change_history_revoke',
       'after update of revoked_at on public.device_sessions for each row '
       'when (new.revoked_at is not null and old.revoked_at is null) '
       'execute function public.fn_change_history_on_device_revoke()')
    ) v(tbl, name, body)
  loop
    if to_regclass('public.' || r.tbl) is null then
      raise notice 'change_history: la tabla % no existe, se salta', r.tbl;
      continue;
    end if;
    execute format('drop trigger if exists %I on public.%I', r.name, r.tbl);
    execute 'create trigger ' || quote_ident(r.name) || ' ' || r.body;
  end loop;

  -- Inventario: al COMMIT, para leer el motivo que se pone después del INSERT.
  -- Lo de la venta (sale) y lo de documentos sale en su documento.
  if to_regclass('public.inventory_movements') is not null then
    execute 'drop trigger if exists trg_zz_change_history on public.inventory_movements';
    execute $t$
      create constraint trigger trg_zz_change_history
        after insert on public.inventory_movements
        deferrable initially deferred
        for each row
        when (new.movement_type::text <> 'sale'
              and coalesce(new.reference_type, '') not in (
                'order', 'order_item_removal', 'purchase_reception_line',
                'purchase_order', 'purchase_order_edit',
                'purchase_order_edit_reversal', 'purchase_order_cancel',
                'direct_receipt', 'direct_receipt_cancel', 'stock_transfer',
                'stock_transfer_variance', 'stock_transfer_cancel',
                'production', 'physical_count'))
        execute function public.fn_change_history_on_stock_move()
    $t$;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 10. Permisos de las funciones
-- ---------------------------------------------------------------------------
revoke all on function private.fn_change_history_called_from(text) from public;
revoke all on function private.fn_change_history_session_label(uuid) from public;
revoke all on function private.fn_change_history_order_label(uuid) from public;
revoke all on function private.fn_change_history_table_label(uuid) from public;
revoke all on function private.fn_change_history_cash_scope(uuid) from public;
revoke all on function private.fn_change_history_add(uuid, text, text, text, text, text, uuid, uuid, jsonb, timestamptz) from public;
revoke all on function private.fn_change_history_render(text, text, jsonb, text) from public;
revoke all on function private.fn_change_history_keep(text, text, text) from public;
revoke all on function private.fn_change_history_snapshot(text, jsonb, text) from public;
revoke all on function private.fn_change_history_scope(text, jsonb) from public;
do $$
declare
  f text;
begin
  foreach f in array array[
    'fn_change_history_record', 'fn_change_history_on_order_void',
    'fn_change_history_on_cash_tx', 'fn_change_history_on_cash_session',
    'fn_change_history_on_audit_log', 'fn_change_history_on_session_move',
    'fn_change_history_on_items_move', 'fn_change_history_on_discount',
    'fn_change_history_on_payment_method', 'fn_change_history_on_waiter_change',
    'fn_change_history_on_credit_note', 'fn_change_history_on_sales_note_void',
    'fn_change_history_on_credit_payment', 'fn_change_history_on_credit_cancel',
    'fn_change_history_on_payable', 'fn_change_history_on_supplier_payment',
    'fn_change_history_on_table_deposit', 'fn_change_history_on_stamps',
    'fn_change_history_on_stock_move', 'fn_change_history_on_asset',
    'fn_change_history_on_device_revoke'
  ] loop
    execute format('revoke all on function public.%I() from public, anon, authenticated', f);
  end loop;
end;
$$;

commit;
