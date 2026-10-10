-- =============================================================================
-- 20261010_0024 — Cuenta en revisión: «Mover a otra mesa», y quién la tomó
-- =============================================================================
--
-- POR QUÉ. Pedidos del dueño (10-oct) al probar la hoja de cuentas en revisión
-- (20261010_0020):
--   1. Una cuenta que llegó de otro equipo puede ser de OTRA mesa (se tomó sin
--      conexión en la mesa equivocada, o los clientes se cambiaron): además de
--      unirla o anularla, se puede mover.
--   2. «Debe llegar con el nombre del mesero y el número de la mesa»: la hoja
--      dice quién la tomó y en qué mesa, y al moverla a una mesa libre (o al
--      abrirse la mesa por productos tardíos de una cuenta cobrada) la sesión
--      nueva queda a nombre de ese mesero, no de quien mueve o sube.
--
-- QUÉ HACE.
--   · orders: taken_by_employee_id (mesero del PIN), taken_by_user_id (usuario
--     del equipo), taken_at_table_id (mesa donde se tomó). Se llenan en todos
--     los caminos que crean o reubican una cuenta en revisión
--     (fn_open_local_table_order, fn_move_closed_order_to_review,
--     fn_late_items_review_order, fn_reattach_orphan_order). Las cuentas en
--     revisión ya existentes se completan desde la bitácora.
--   · fn_review_accounts(sesión): las cuentas en revisión con mesero, mesa y
--     productos (la hoja de la app la usa; sin ella, cae a la lectura directa).
--   · fn_move_review_order(cuenta, mesa destino): mesa libre → se abre a nombre
--     del mesero que la tomó y la cuenta pasa a ser LA cuenta de esa mesa;
--     ocupada → sus productos se suman a la cuenta de esa mesa (cada línea
--     conserva quién la cargó); el origen se libera si queda sin cuentas.
--     Nunca con cobros; solo en el mismo negocio; candado por mesa.
--
-- Cuerpos base (vivos al 10-oct): fn_open_local_table_order d9008f11…,
-- fn_move_closed_order_to_review 2e4291ad…, fn_late_items_review_order
-- 382c1c45… (20261010_0020); fn_reattach_orphan_order 4a5cd739…
-- (20261010_0023). fn_move_review_order: la primera versión de este archivo
-- (cf0ea1a6…) si ya se aplicó; si no, se crea. Volver a correr este archivo es
-- seguro (idempotente).
--
-- ROLLBACK: 20261010_0024_move_review_order_ROLLBACK.sql
-- Prueba local: supabase/tests/move_review_order_local_test.sh
-- =============================================================================

begin;

alter table public.orders add column if not exists taken_by_employee_id uuid;
alter table public.orders add column if not exists taken_by_user_id uuid;
alter table public.orders add column if not exists taken_at_table_id uuid;

comment on column public.orders.taken_by_employee_id is
  'Mesero (empleado del PIN) que tomó la cuenta; lo usan las cuentas en revisión (20261010_0024).';
comment on column public.orders.taken_by_user_id is
  'Usuario del equipo que tomó o subió la cuenta (20261010_0024).';
comment on column public.orders.taken_at_table_id is
  'Mesa donde se tomó la cuenta; se conserva al moverla (20261010_0024).';

-- Cuentas en revisión ya existentes: quién la subió y en qué mesa (bitácora).
update public.orders o
   set taken_by_user_id  = coalesce(o.taken_by_user_id, e.actor),
       taken_at_table_id = coalesce(o.taken_at_table_id, e.table_id)
  from public.order_review_events e
 where e.order_id = o.id
   and e.event in ('conflict_opened', 'late_items_moved', 'late_items_redirected')
   and o.review_reason is not null
   and (o.taken_by_user_id is null or o.taken_at_table_id is null);

alter table public.order_review_events
  drop constraint if exists order_review_events_event_check;
alter table public.order_review_events
  add constraint order_review_events_event_check check (event in (
    'conflict_opened', 'late_items_moved', 'late_items_redirected',
    'resolved_merge', 'resolved_promote', 'resolved_void', 'resolved_move'));

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
      update public.orders
         set client_order_id      = v_client,
             taken_by_employee_id = coalesce(taken_by_employee_id, p_opened_by_employee_id),
             taken_by_user_id     = coalesce(taken_by_user_id, v_user),
             taken_at_table_id    = coalesce(taken_at_table_id, p_table_id)
       where id = v_main;
      v_order := v_main;
      v_outcome := 'adopted';
    else
      v_outcome := 'review';
    end if;
  end if;

  if v_order is null then
    insert into public.orders (
      session_id, status_ext, subtotal, discounts, tax, total, total_amount,
      client_order_id, review_reason, review_at,
      taken_by_employee_id, taken_by_user_id, taken_at_table_id
    ) values (
      v_session, 'open', 0, 0, 0, 0, 0,
      v_client,
      case when v_outcome = 'review' then 'offline_conflict' end,
      case when v_outcome = 'review' then now() end,
      p_opened_by_employee_id, v_user, p_table_id
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
  v_opened_by      uuid;
  v_opened_emp     uuid;
begin
  select o.session_id, ts.table_id, coalesce(ts.business_id, z.business_id),
         o.closed_at, o.status_ext,
         coalesce(ts.waiter_user_id, ts.opened_by), ts.opened_by_employee_id
    into v_session_before, v_table, v_business, v_closed_at, v_status,
         v_opened_by, v_opened_emp
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
         review_at      = now(),
         taken_by_employee_id = coalesce(taken_by_employee_id, v_opened_emp),
         taken_by_user_id     = coalesce(taken_by_user_id, v_opened_by),
         taken_at_table_id    = coalesce(taken_at_table_id, v_table)
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
  v_src_user uuid;
  v_src_emp  uuid;
begin
  select ts.table_id, coalesce(ts.business_id, z.business_id), ts.origin,
         coalesce(o.taken_by_user_id, ts.waiter_user_id, ts.opened_by),
         coalesce(o.taken_by_employee_id, ts.opened_by_employee_id)
    into v_table, v_business, v_origin, v_src_user, v_src_emp
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
      table_id, opened_by, origin, waiter_user_id, people_count, business_id,
      opened_by_employee_id
    ) values (
      v_table, coalesce(v_src_user, v_user),
      coalesce(v_origin, 'dine_in'::public.order_origin),
      coalesce(v_src_user, v_user), 1, v_business, v_src_emp
    )
    returning id into v_session;

    update public.dining_tables
       set state = 'occupied'
     where id = v_table
       and state is distinct from 'occupied';
  end if;

  insert into public.orders (
    session_id, status_ext, subtotal, discounts, tax, total, total_amount,
    review_reason, review_source_order_id, review_at,
    taken_by_employee_id, taken_by_user_id, taken_at_table_id
  ) values (
    v_session, 'open', 0, 0, 0, 0, 0,
    'late_items_after_settle', p_source_order_id, now(),
    v_src_emp, v_src_user, v_table
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
  v_opened_by      uuid;
  v_opened_emp     uuid;
begin
  select o.session_id, ts.table_id, coalesce(ts.business_id, z.business_id),
         o.closed_at, ts.closed_at, o.status_ext,
         coalesce(ts.waiter_user_id, ts.opened_by), ts.opened_by_employee_id
    into v_session, v_table, v_business, v_order_closed, v_session_closed, v_status,
         v_opened_by, v_opened_emp
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
         review_at     = coalesce(review_at, now()),
         taken_by_employee_id = coalesce(taken_by_employee_id, v_opened_emp),
         taken_by_user_id     = coalesce(taken_by_user_id, v_opened_by),
         taken_at_table_id    = coalesce(taken_at_table_id, v_table)
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

create or replace function public.fn_move_review_order(
  p_order_id        uuid,
  p_target_table_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_user            uuid := auth.uid();
  v_session         uuid;
  v_table           uuid;
  v_business        uuid;
  v_target_business uuid;
  v_review          text;
  v_closed          timestamptz;
  v_status          public.order_status;
  v_target_session  uuid;
  v_target_main     uuid;
  v_check           uuid;
  v_moved           integer := 0;
  v_outcome         text;
  v_taken_user      uuid;
  v_taken_emp       uuid;
begin
  if v_user is null then
    raise exception 'USER_REQUIRED';
  end if;
  if p_order_id is null or p_target_table_id is null then
    raise exception 'INVALID_INPUT';
  end if;

  select o.session_id, ts.table_id, coalesce(ts.business_id, z.business_id)
    into v_session, v_table, v_business
    from public.orders o
    join public.table_sessions ts on ts.id = o.session_id
    left join public.dining_tables dt on dt.id = ts.table_id
    left join public.zones z on z.id = dt.zone_id
   where o.id = p_order_id;
  if v_session is null then
    raise exception 'ORDER_NOT_FOUND';
  end if;

  if not exists (
    select 1 from public.current_user_business_ids() as c(business_id)
     where c.business_id = v_business
  ) then
    raise exception 'NOT_A_MEMBER';
  end if;

  select z.business_id into v_target_business
    from public.dining_tables t
    join public.zones z on z.id = t.zone_id
   where t.id = p_target_table_id;
  if v_target_business is null then
    raise exception 'TARGET_TABLE_NOT_FOUND';
  end if;
  if v_target_business is distinct from v_business then
    raise exception 'SAME_BUSINESS_REQUIRED';
  end if;
  if p_target_table_id = v_table then
    raise exception 'SAME_TABLE_NOT_ALLOWED';
  end if;

  -- Candado por mesa, origen y destino en orden fijo.
  perform pg_advisory_xact_lock(
    hashtextextended(least(v_table, p_target_table_id)::text, 0));
  perform pg_advisory_xact_lock(
    hashtextextended(greatest(v_table, p_target_table_id)::text, 0));

  select o.review_reason, o.closed_at, o.status_ext, o.session_id,
         o.taken_by_user_id, o.taken_by_employee_id
    into v_review, v_closed, v_status, v_session, v_taken_user, v_taken_emp
    from public.orders o
   where o.id = p_order_id
   for update;

  if v_review is null then
    return jsonb_build_object('outcome', 'not_in_review', 'order_id', p_order_id);
  end if;
  if v_closed is not null or v_status in ('paid'::public.order_status, 'void'::public.order_status) then
    return jsonb_build_object('outcome', 'already_closed', 'order_id', p_order_id);
  end if;
  if exists (
    select 1 from public.payments p
     where p.order_id = p_order_id
       and p.status in ('pending', 'completed')
  ) then
    return jsonb_build_object('outcome', 'has_payments', 'order_id', p_order_id);
  end if;

  select ts.id into v_target_session
    from public.table_sessions ts
   where ts.table_id = p_target_table_id
     and ts.closed_at is null
   order by ts.opened_at desc
   limit 1;

  if v_target_session is null then
    insert into public.table_sessions (
      table_id, opened_by, origin, waiter_user_id, people_count, business_id,
      opened_by_employee_id
    ) values (
      p_target_table_id, coalesce(v_taken_user, v_user), 'dine_in',
      coalesce(v_taken_user, v_user), 1, v_business, v_taken_emp
    )
    returning id into v_target_session;
    update public.dining_tables
       set state = 'occupied'
     where id = p_target_table_id
       and state is distinct from 'occupied';
  else
    select o.id into v_target_main
      from public.orders o
     where o.session_id = v_target_session
       and o.id <> p_order_id
       and o.closed_at is null
       and o.status_ext not in ('paid', 'void')
       and o.review_reason is null
     order by o.created_at desc
     limit 1
     for update;
  end if;

  if v_target_main is null then
    -- Pasa a ser LA cuenta de la mesa destino.
    update public.orders
       set session_id    = v_target_session,
           review_reason = null
     where id = p_order_id;
    perform public.fn_recalc_order_totals(p_order_id);
    v_outcome := 'moved';

    -- La mesa de origen: sin cuentas vivas, se libera.
    if not exists (
      select 1 from public.orders o
       where o.session_id = v_session
         and o.closed_at is null
         and o.status_ext not in ('paid', 'void')
    ) then
      update public.table_sessions
         set closed_at = now()
       where id = v_session
         and closed_at is null;
      update public.dining_tables
         set state = 'available'
       where id = v_table;
    end if;
  else
    -- Se suma a la cuenta de la mesa destino.
    select oc.id into v_check
      from public.order_checks oc
     where oc.order_id = v_target_main
       and not coalesce(oc.is_closed, false)
     order by oc.position
     limit 1;

    with moved as (
      update public.order_items
         set order_id = v_target_main,
             check_id = v_check
       where order_id = p_order_id
         and status::text <> 'void'
      returning 1
    )
    select count(*) into v_moved from moved;

    perform public.fn_recalc_order_totals(v_target_main);
    -- Cierra la de revisión; si en el origen no queda otra cuenta, libera.
    perform public.fn_close_order_and_table(p_order_id, 'void'::public.order_status);
    v_outcome := 'merged';
  end if;

  insert into public.order_review_events (
    order_id, business_id, event, target_order_id, session_id, table_id, items_moved
  ) values (
    p_order_id, v_business, 'resolved_move',
    coalesce(v_target_main, p_order_id), v_target_session, p_target_table_id, v_moved
  );

  return jsonb_build_object(
    'outcome', v_outcome,
    'order_id', p_order_id,
    'target_order_id', coalesce(v_target_main, p_order_id),
    'target_table_id', p_target_table_id,
    'items_moved', v_moved
  );
end;
$function$;

-- Cuentas en revisión abiertas de una sesión, con quién la tomó y en qué mesa
-- (mismo criterio de nombre que v_zone_table_status: primer nombre del
-- empleado del PIN, luego del usuario, luego su perfil; respaldo: quien cargó
-- su primer producto).
create or replace function public.fn_review_accounts(p_session_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_business uuid;
  v_result   jsonb;
begin
  select coalesce(ts.business_id, z.business_id) into v_business
    from public.table_sessions ts
    left join public.dining_tables dt on dt.id = ts.table_id
    left join public.zones z on z.id = dt.zone_id
   where ts.id = p_session_id;
  if v_business is null then
    return '[]'::jsonb;
  end if;
  if not exists (
    select 1 from public.current_user_business_ids() as c(business_id)
     where c.business_id = v_business
  ) then
    raise exception 'NOT_A_MEMBER';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', o.id,
           'review_reason', o.review_reason,
           'review_at', o.review_at,
           'review_source_order_id', o.review_source_order_id,
           'waiter_name', coalesce(
             (select nullif(split_part(btrim(e.first_name), ' ', 1), '')
                from public.employees e where e.id = o.taken_by_employee_id),
             (select nullif(split_part(btrim(e.first_name), ' ', 1), '')
                from public.employees e
               where e.user_id = o.taken_by_user_id and e.business_id = v_business
               limit 1),
             (select nullif(split_part(btrim(p.full_name), ' ', 1), '')
                from public.profiles p where p.id = o.taken_by_user_id),
             (select nullif(split_part(btrim(e.first_name), ' ', 1), '')
                from public.order_items oi
                join public.employees e on e.id = oi.created_by_employee_id
               where oi.order_id = o.id
               order by oi.created_at
               limit 1)),
           'table_code', coalesce(
             (select t.code from public.dining_tables t where t.id = o.taken_at_table_id),
             (select t.code from public.table_sessions ts
                join public.dining_tables t on t.id = ts.table_id
               where ts.id = o.session_id)),
           'order_items', coalesce((
             select jsonb_agg(jsonb_build_object(
                      'product_name', oi.product_name,
                      'quantity', oi.quantity,
                      'qty', oi.qty,
                      'total', oi.total,
                      'status', oi.status) order by oi.created_at)
               from public.order_items oi
              where oi.order_id = o.id
                and oi.status::text not in ('void', 'paid')), '[]'::jsonb)
         ) order by o.review_at), '[]'::jsonb)
    into v_result
    from public.orders o
   where o.session_id = p_session_id
     and o.review_reason is not null
     and o.closed_at is null
     and o.status_ext not in ('paid', 'void');

  return v_result;
end;
$function$;

revoke all on function public.fn_review_accounts(uuid) from public, anon;
grant execute on function public.fn_review_accounts(uuid) to authenticated, service_role;

revoke all on function public.fn_open_local_table_order(text, uuid, integer, uuid) from public, anon;
grant execute on function public.fn_open_local_table_order(text, uuid, integer, uuid) to authenticated, service_role;
revoke all on function public.fn_move_closed_order_to_review(uuid) from public, anon, authenticated;
revoke all on function public.fn_late_items_review_order(uuid) from public, anon, authenticated;
revoke all on function public.fn_reattach_orphan_order(uuid) from public, anon, authenticated;
grant execute on function public.fn_move_closed_order_to_review(uuid) to service_role;
grant execute on function public.fn_late_items_review_order(uuid) to service_role;
grant execute on function public.fn_reattach_orphan_order(uuid) to service_role;
revoke all on function public.fn_move_review_order(uuid, uuid) from public, anon;
grant execute on function public.fn_move_review_order(uuid, uuid) to authenticated, service_role;

commit;
