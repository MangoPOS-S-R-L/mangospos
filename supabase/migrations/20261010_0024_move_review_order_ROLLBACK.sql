-- Reversa de 20261010_0024: quita «Mover a otra mesa» y fn_review_accounts, y
-- vuelve las funciones de cuentas en revisión a 20261010_0020 / 0023 (sin
-- guardar quién tomó la cuenta). Las columnas taken_* y la bitácora se
-- conservan (datos); la restricción de eventos sigue admitiendo 'resolved_move'.
begin;

drop function if exists public.fn_move_review_order(uuid, uuid);
drop function if exists public.fn_review_accounts(uuid);

create or replace function public.fn_open_local_table_order(
  p_client_order_id       text,
  p_table_id              uuid,
  p_people_count          integer default 1,
  p_opened_by_employee_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_user           uuid := auth.uid();
  v_client         text := nullif(btrim(coalesce(p_client_order_id, '')), '');
  v_business       uuid;
  v_found_order    uuid;
  v_found_session  uuid;
  v_found_review   text;
  v_found_business uuid;
  v_session        uuid;
  v_session_opener uuid;
  v_main           uuid;
  v_main_client    text;
  v_order          uuid;
  v_outcome        text;
begin
  if v_client is null or length(v_client) > 120 then
    raise exception 'CLIENT_ORDER_ID_REQUIRED';
  end if;
  if p_table_id is null then
    raise exception 'TABLE_ID_REQUIRED';
  end if;
  if v_user is null then
    raise exception 'USER_REQUIRED';
  end if;

  select z.business_id into v_business
    from public.dining_tables t
    join public.zones z on z.id = t.zone_id
   where t.id = p_table_id;
  if v_business is null then
    raise exception 'TABLE_BUSINESS_NOT_FOUND';
  end if;

  -- Alias de columna EXPLÍCITO (ver project_current_user_business_ids_alias_42703).
  if not exists (
    select 1 from public.current_user_business_ids() as c(business_id)
     where c.business_id = v_business
  ) then
    raise exception 'NOT_A_MEMBER';
  end if;

  if p_opened_by_employee_id is not null and not exists (
    select 1 from public.employees e
     where e.id = p_opened_by_employee_id
       and e.business_id = v_business
       and e.status = 'active'
  ) then
    raise exception 'EMPLOYEE_NOT_IN_BUSINESS';
  end if;

  -- Misma identidad → la misma cuenta. Antes del requisito de caja: volver a
  -- encontrar lo que ya subió no abre nada.
  select o.id, o.session_id, o.review_reason, coalesce(ts.business_id, z.business_id)
    into v_found_order, v_found_session, v_found_review, v_found_business
    from public.orders o
    left join public.table_sessions ts on ts.id = o.session_id
    left join public.dining_tables dt on dt.id = ts.table_id
    left join public.zones z on z.id = dt.zone_id
   where o.client_order_id = v_client;
  if v_found_order is not null then
    if v_found_business is distinct from v_business then
      raise exception 'CLIENT_ORDER_ID_CONFLICT' using errcode = 'MP411';
    end if;
    return jsonb_build_object('session_id', v_found_session, 'order_id', v_found_order,
      'outcome', 'existing', 'review', v_found_review is not null);
  end if;

  perform public.fn_require_open_cash_session(v_user);

  -- MISMO candado que fn_open_table y las liberaciones.
  perform pg_advisory_xact_lock(hashtextextended(p_table_id::text, 0));

  -- Re-chequeo dentro del candado: dos reenvíos simultáneos de la misma cuenta.
  select o.id, o.session_id, o.review_reason
    into v_found_order, v_found_session, v_found_review
    from public.orders o
   where o.client_order_id = v_client;
  if v_found_order is not null then
    return jsonb_build_object('session_id', v_found_session, 'order_id', v_found_order,
      'outcome', 'existing', 'review', v_found_review is not null);
  end if;

  select ts.id, ts.opened_by
    into v_session, v_session_opener
    from public.table_sessions ts
   where ts.table_id = p_table_id
     and ts.closed_at is null
   order by ts.opened_at desc
   limit 1;

  if v_session is null then
    insert into public.table_sessions (
      table_id, opened_by, origin, waiter_user_id, people_count,
      opened_by_employee_id, business_id
    ) values (
      p_table_id, v_user, 'dine_in', v_user,
      greatest(1, coalesce(p_people_count, 1)),
      p_opened_by_employee_id, v_business
    )
    returning id into v_session;
    v_outcome := 'created';
  else
    select o.id, o.client_order_id
      into v_main, v_main_client
      from public.orders o
     where o.session_id = v_session
       and o.closed_at is null
       and o.status_ext not in ('paid', 'void')
       and o.review_reason is null
     order by o.created_at desc
     limit 1;

    if v_main is null then
      v_outcome := 'created';
    elsif v_main_client is null
      and v_session_opener = v_user
      and not exists (
        select 1 from public.order_items oi
         where oi.order_id = v_main and oi.status::text <> 'void')
      and not exists (select 1 from public.payments p where p.order_id = v_main)
    then
      -- La abrió este mismo usuario y está vacía: es la apertura lenta que sí
      -- se guardó. Se adopta; no hay nada que mezclar.
      update public.orders set client_order_id = v_client where id = v_main;
      v_order := v_main;
      v_outcome := 'adopted';
    else
      v_outcome := 'review';
    end if;
  end if;

  if v_order is null then
    insert into public.orders (
      session_id, status_ext, subtotal, discounts, tax, total, total_amount,
      client_order_id, review_reason, review_at
    ) values (
      v_session, 'open', 0, 0, 0, 0, 0,
      v_client,
      case when v_outcome = 'review' then 'offline_conflict' end,
      case when v_outcome = 'review' then now() end
    )
    returning id into v_order;

    insert into public.order_checks (order_id, label, position)
    values (v_order, 'C1', 1)
    on conflict (order_id, position) do nothing;
  end if;

  update public.dining_tables
     set state = 'occupied'
   where id = p_table_id
     and state is distinct from 'occupied';

  if v_outcome = 'review' then
    insert into public.order_review_events (
      order_id, business_id, event, target_order_id, session_id, table_id
    ) values (v_order, v_business, 'conflict_opened', v_main, v_session, p_table_id);
  end if;

  return jsonb_build_object('session_id', v_session, 'order_id', v_order,
    'outcome', v_outcome, 'review', v_outcome = 'review');
end;
$function$;

create or replace function public.fn_move_closed_order_to_review(p_order_id uuid)
returns uuid
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_session_before uuid;
  v_table          uuid;
  v_business       uuid;
  v_closed_at      timestamptz;
  v_status         public.order_status;
  v_target_session uuid;
begin
  select o.session_id, ts.table_id, coalesce(ts.business_id, z.business_id),
         o.closed_at, o.status_ext
    into v_session_before, v_table, v_business, v_closed_at, v_status
    from public.orders o
    join public.table_sessions ts on ts.id = o.session_id
    left join public.dining_tables dt on dt.id = ts.table_id
    left join public.zones z on z.id = dt.zone_id
   where o.id = p_order_id
   for update of o;

  if not found or v_closed_at is null then
    return p_order_id;
  end if;

  perform pg_advisory_xact_lock(hashtextextended(v_table::text, 0));

  select ts.id into v_target_session
    from public.table_sessions ts
   where ts.table_id = v_table
     and ts.closed_at is null
   order by ts.opened_at desc
   limit 1;

  if v_target_session is null then
    raise exception 'La mesa ya se abrió en otra cuenta. Carga el producto en la cuenta activa.'
      using errcode = 'MP402';
  end if;

  update public.orders
     set session_id     = v_target_session,
         closed_at      = null,
         status_ext     = case when status_ext = 'void'::public.order_status
                               then 'open'::public.order_status else status_ext end,
         status         = case when status = 'canceled' then 'open' else status end,
         review_reason  = 'late_items_after_release',
         review_at      = now()
   where id = p_order_id;

  -- La anulación cerró sus subcuentas; sin esto el producto quedaría sin subcuenta.
  update public.order_checks
     set is_closed = false,
         closed_at = null
   where order_id = p_order_id
     and coalesce(is_closed, false);

  insert into public.orphan_order_revivals (
    order_id, session_id, table_id, business_id,
    closed_at_before, status_ext_before, source
  ) values (
    p_order_id, v_session_before, v_table, v_business,
    v_closed_at, v_status::text, 'order_item_insert_review'
  );

  insert into public.order_review_events (
    order_id, business_id, event, session_id, table_id
  ) values (p_order_id, v_business, 'late_items_moved', v_target_session, v_table);

  return p_order_id;
end;
$function$;

create or replace function public.fn_late_items_review_order(p_source_order_id uuid)
returns uuid
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_user     uuid := auth.uid();
  v_table    uuid;
  v_business uuid;
  v_origin   public.order_origin;
  v_session  uuid;
  v_review   uuid;
begin
  select ts.table_id, coalesce(ts.business_id, z.business_id), ts.origin
    into v_table, v_business, v_origin
    from public.orders o
    join public.table_sessions ts on ts.id = o.session_id
    left join public.dining_tables dt on dt.id = ts.table_id
    left join public.zones z on z.id = dt.zone_id
   where o.id = p_source_order_id;

  if v_table is null then
    return null;
  end if;

  perform pg_advisory_xact_lock(hashtextextended(v_table::text, 0));

  select ts.id into v_session
    from public.table_sessions ts
   where ts.table_id = v_table
     and ts.closed_at is null
   order by ts.opened_at desc
   limit 1;

  if v_session is not null then
    select o.id into v_review
      from public.orders o
     where o.session_id = v_session
       and o.closed_at is null
       and o.review_reason = 'late_items_after_settle'
       and o.review_source_order_id = p_source_order_id
     order by o.created_at desc
     limit 1;
    if v_review is not null then
      return v_review;
    end if;
  else
    if v_user is null then
      return null;
    end if;
    insert into public.table_sessions (
      table_id, opened_by, origin, waiter_user_id, people_count, business_id
    ) values (
      v_table, v_user, coalesce(v_origin, 'dine_in'::public.order_origin), v_user, 1, v_business
    )
    returning id into v_session;

    update public.dining_tables
       set state = 'occupied'
     where id = v_table
       and state is distinct from 'occupied';
  end if;

  insert into public.orders (
    session_id, status_ext, subtotal, discounts, tax, total, total_amount,
    review_reason, review_source_order_id, review_at
  ) values (
    v_session, 'open', 0, 0, 0, 0, 0,
    'late_items_after_settle', p_source_order_id, now()
  )
  returning id into v_review;

  insert into public.order_checks (order_id, label, position)
  values (v_review, 'C1', 1)
  on conflict (order_id, position) do nothing;

  insert into public.order_review_events (
    order_id, business_id, event, source_order_id, session_id, table_id
  ) values (v_review, v_business, 'late_items_redirected', p_source_order_id, v_session, v_table);

  return v_review;
end;
$function$;

create or replace function public.fn_reattach_orphan_order(p_order_id uuid)
returns text
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_session        uuid;
  v_table          uuid;
  v_business       uuid;
  v_order_closed   timestamptz;
  v_session_closed timestamptz;
  v_status         public.order_status;
  v_other_session  uuid;
begin
  select o.session_id, ts.table_id, coalesce(ts.business_id, z.business_id),
         o.closed_at, ts.closed_at, o.status_ext
    into v_session, v_table, v_business, v_order_closed, v_session_closed, v_status
    from public.orders o
    join public.table_sessions ts on ts.id = o.session_id
    left join public.dining_tables dt on dt.id = ts.table_id
    left join public.zones z on z.id = dt.zone_id
   where o.id = p_order_id
   for update of o;

  if not found or v_order_closed is not null or v_session_closed is null
     or v_table is null then
    return 'not_orphan';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(v_table::text, 0));

  -- Re-chequeo dentro del candado (snapshot nuevo).
  select ts.closed_at into v_session_closed
    from public.table_sessions ts where ts.id = v_session;
  if v_session_closed is null then
    return 'not_orphan';
  end if;

  select ts.id into v_other_session
    from public.table_sessions ts
   where ts.table_id = v_table
     and ts.closed_at is null
   order by ts.opened_at desc
   limit 1;

  if v_other_session is null then
    update public.table_sessions set closed_at = null where id = v_session;
    update public.dining_tables
       set state = 'occupied'
     where id = v_table
       and state is distinct from 'occupied';
    insert into public.orphan_order_revivals (
      order_id, session_id, table_id, business_id,
      closed_at_before, status_ext_before, source
    ) values (
      p_order_id, v_session, v_table, v_business,
      v_session_closed, v_status::text, 'order_item_insert_session'
    );
    return 'reattached';
  end if;

  update public.orders
     set session_id    = v_other_session,
         review_reason = coalesce(review_reason, 'late_items_after_release'),
         review_at     = coalesce(review_at, now())
   where id = p_order_id;
  insert into public.orphan_order_revivals (
    order_id, session_id, table_id, business_id,
    closed_at_before, status_ext_before, source
  ) values (
    p_order_id, v_session, v_table, v_business,
    v_session_closed, v_status::text, 'order_item_insert_session_review'
  );
  insert into public.order_review_events (
    order_id, business_id, event, session_id, table_id
  ) values (p_order_id, v_business, 'late_items_moved', v_other_session, v_table);
  return 'moved_to_review';
end;
$function$;

revoke all on function public.fn_open_local_table_order(text, uuid, integer, uuid) from public, anon;
grant execute on function public.fn_open_local_table_order(text, uuid, integer, uuid) to authenticated, service_role;
revoke all on function public.fn_move_closed_order_to_review(uuid) from public, anon, authenticated;
revoke all on function public.fn_late_items_review_order(uuid) from public, anon, authenticated;
revoke all on function public.fn_reattach_orphan_order(uuid) from public, anon, authenticated;
grant execute on function public.fn_move_closed_order_to_review(uuid) to service_role;
grant execute on function public.fn_late_items_review_order(uuid) to service_role;
grant execute on function public.fn_reattach_orphan_order(uuid) to service_role;

commit;
