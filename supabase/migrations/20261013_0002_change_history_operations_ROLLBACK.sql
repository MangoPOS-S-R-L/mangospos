-- Reversa de 20261013_0002_change_history_operations.sql: quita los triggers
-- y funciones de 0002 y deja las de 0001 como estaban (copiadas textual de
-- 20261013_0001_change_history.sql). Las líneas que 0002 ya escribió en
-- change_history se quedan (son hechos ciertos); el arreglo de las
-- anulaciones que fueron traslados tampoco se deshace.

begin;

set local lock_timeout = '5s';

do $$
declare
  r record;
begin
  for r in
    select * from (values
      ('menu_item_links', 'trg_zz_change_history'),
      ('combo_group_items', 'trg_zz_change_history'),
      ('modifier_ingredients', 'trg_zz_change_history'),
      ('menu_item_print_areas', 'trg_zz_change_history'),
      ('print_area_printers', 'trg_zz_change_history'),
      ('device_printer_bindings', 'trg_zz_change_history'),
      ('supplier_items', 'trg_zz_change_history'),
      ('inventory_item_presentations', 'trg_zz_change_history'),
      ('accounting_accounts', 'trg_zz_change_history'),
      ('accounting_cost_centers', 'trg_zz_change_history'),
      ('loyalty_stamp_programs', 'trg_zz_change_history'),
      ('order_item_removal_reasons', 'trg_zz_change_history'),
      ('gift_cards', 'trg_zz_change_history'),
      ('external_api_keys', 'trg_zz_change_history'),
      ('reservations', 'trg_zz_change_history'),
      ('purchase_orders', 'trg_zz_change_history'),
      ('purchase_receptions', 'trg_zz_change_history'),
      ('direct_receipts', 'trg_zz_change_history'),
      ('stock_transfers', 'trg_zz_change_history'),
      ('physical_count_sessions', 'trg_zz_change_history'),
      ('requisitions', 'trg_zz_change_history'),
      ('production_orders', 'trg_zz_change_history'),
      ('cash_transactions', 'trg_zz_change_history'),
      ('cash_transactions', 'trg_zz_change_history_edit'),
      ('cash_register_sessions', 'trg_zz_change_history'),
      ('cash_register_sessions', 'trg_zz_change_history_status'),
      ('audit_logs', 'trg_zz_change_history'),
      ('table_sessions', 'trg_zz_change_history_move'),
      ('order_items', 'trg_zz_change_history_move'),
      ('order_items', 'trg_zz_change_history_discount'),
      ('payments', 'trg_zz_change_history_method'),
      ('table_session_waiter_changes', 'trg_zz_change_history'),
      ('fiscal_documents', 'trg_zz_change_history_credit_note'),
      ('sales_notes', 'trg_zz_change_history_void'),
      ('credit_payments', 'trg_zz_change_history'),
      ('customer_credits', 'trg_zz_change_history_cancel'),
      ('supplier_credits', 'trg_zz_change_history'),
      ('supplier_credits', 'trg_zz_change_history_cancel'),
      ('supplier_credit_payments', 'trg_zz_change_history'),
      ('table_deposit_movements', 'trg_zz_change_history'),
      ('loyalty_stamp_adjustments', 'trg_zz_change_history'),
      ('fixed_asset_movements', 'trg_zz_change_history'),
      ('device_sessions', 'trg_zz_change_history_revoke'),
      ('inventory_movements', 'trg_zz_change_history')
    ) v(tbl, name)
  loop
    if to_regclass('public.' || r.tbl) is not null then
      execute format('drop trigger if exists %I on public.%I', r.name, r.tbl);
    end if;
  end loop;
end;
$$;

drop function if exists public.fn_change_history_on_cash_tx();
drop function if exists public.fn_change_history_on_cash_session();
drop function if exists public.fn_change_history_on_audit_log();
drop function if exists public.fn_change_history_on_session_move();
drop function if exists public.fn_change_history_on_items_move();
drop function if exists public.fn_change_history_on_discount();
drop function if exists public.fn_change_history_on_payment_method();
drop function if exists public.fn_change_history_on_waiter_change();
drop function if exists public.fn_change_history_on_credit_note();
drop function if exists public.fn_change_history_on_sales_note_void();
drop function if exists public.fn_change_history_on_credit_payment();
drop function if exists public.fn_change_history_on_credit_cancel();
drop function if exists public.fn_change_history_on_payable();
drop function if exists public.fn_change_history_on_supplier_payment();
drop function if exists public.fn_change_history_on_table_deposit();
drop function if exists public.fn_change_history_on_stamps();
drop function if exists public.fn_change_history_on_stock_move();
drop function if exists public.fn_change_history_on_asset();
drop function if exists public.fn_change_history_on_device_revoke();

-- Las de 0001, como estaban (dejan de usar fn_change_history_render).
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
                      'sort_order', 'sort_index', 'display_order')
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
           e.key, private.fn_change_history_value(e.key, e.value)), '{}'::jsonb)
  from jsonb_each(p_row) e
  where private.fn_change_history_keep(p_table, e.key, p_source)
    and jsonb_typeof(e.value) <> 'null'
$$;

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
  if v_source like '%/rpc/fn_seed\_%' then
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
            coalesce(private.fn_change_history_value(k, v_old -> k, 'old'), 'null'::jsonb),
            coalesce(private.fn_change_history_value(k, v_new -> k, 'new'), 'null'::jsonb)));
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

drop function if exists private.fn_change_history_render(text, text, jsonb, text);
drop function if exists private.fn_change_history_add(uuid, text, text, text, text, text, uuid, uuid, jsonb, timestamptz);
drop function if exists private.fn_change_history_cash_scope(uuid);
drop function if exists private.fn_change_history_table_label(uuid);
drop function if exists private.fn_change_history_order_label(uuid);
drop function if exists private.fn_change_history_session_label(uuid);
drop function if exists private.fn_change_history_called_from(text);

commit;
