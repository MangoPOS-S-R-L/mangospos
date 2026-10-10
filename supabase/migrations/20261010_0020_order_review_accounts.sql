-- =============================================================================
-- 20261010_0020 — Fase 2: la cuenta de un equipo que vuelve no desaparece
-- =============================================================================
--
-- POR QUÉ (Food Shop, MESA4, 10-oct; aplica a TODOS los negocios). Una cuenta
-- tomada sin conexión vivía solo en un equipo. Al volver la red hay tres
-- caminos por los que se perdía o se mezclaba:
--   (a) productos que llegan a una cuenta liberada cuya mesa ya tomó otra
--       cuenta: el candado de ítems (20260819_0004) los rechazaba con MP402 y
--       quedaban atascados en la cola del equipo (8 intentos → dead-letter);
--       si la cuenta estaba cobrada, MP401 con el mismo final;
--   (b) la cuenta local se subía con fn_open_table(mesa), que devuelve la
--       cuenta abierta ACTUAL de la mesa: los productos se sumaban a la cuenta
--       que otro mesero ya había vuelto a teclear;
--   (c) (app) reenviar la salida de una cuenta local nunca subida abría y
--       liberaba la cuenta actual de otro.
--
-- PRINCIPIO. La mesa es el lugar; la cuenta es una venta concreta. Una cuenta
-- conserva su identidad desde que nace en el equipo hasta confirmarse en el
-- servidor. Si al llegar choca con otra cuenta, se guarda APARTE, marcada en
-- revisión: nunca se mezcla ni se cobra sola. Decisión del dueño (opción A):
-- se ve en la MISMA mesa («2 cuentas · revisar»).
--
-- POR QUÉ UNA SEGUNDA ORDEN Y NO OTRA SESIÓN. uniq_open_session_per_table
-- (vivo) impide dos sesiones abiertas en una mesa. Una sesión sí admite varias
-- órdenes; la cuenta en revisión es una orden más de la sesión de la mesa,
-- con orders.review_reason. Todo lo que elige «la orden de la mesa» la ignora.
--
-- QUÉ HACE.
--   1. orders: client_order_id (identidad de la cuenta local, única),
--      review_reason, review_source_order_id, review_at. Bitácora
--      order_review_events.
--   2. fn_open_table: elige la orden principal (review_reason null). Es la
--      única diferencia con la viva; fn_open_table_and_load solo delega en ella.
--   3. fn_open_local_table_order(client_order_id, mesa, …): para la cola.
--      Misma identidad → la misma cuenta (reintento, respuesta perdida).
--      Mesa libre → cuenta normal. Mesa con cuenta vacía que abrió el mismo
--      usuario (apertura lenta que sí se guardó) → la adopta. Cualquier otro
--      caso → cuenta aparte en revisión ('offline_conflict').
--   4. Candado de ítems: con la mesa tomada por otra cuenta, la cuenta liberada
--      vuelve como cuenta en revisión dentro de la sesión actual
--      ('late_items_after_release') y el producto entra. Si la cuenta estaba
--      cobrada NO se revive: el producto va a una cuenta en revisión nueva
--      ('late_items_after_settle', con la de origen). MP403 (orden inexistente)
--      no cambia; MP401 queda solo si no hay a quién atribuir la sesión nueva.
--   5. v_zone_table_status: total sin las cuentas en revisión; columnas nuevas
--      al final review_orders_count y review_total (la app anterior las ignora).
--   6. fn_resolve_review_order(orden, 'merge'|'void', motivo): «Unir a la
--      cuenta actual» (mueve sus productos; si no hay cuenta actual, pasa a ser
--      la principal) o «Anular, era duplicado» (motivo obligatorio, vía
--      fn_void_order_if_unpaid: nunca anula con cobros).
--
-- LO QUE NO CAMBIA. Cobro, cocina, precuenta y cierre de caja trabajan por
-- orden; una cuenta en revisión con productos bloquea el cierre de caja igual
-- que cualquier mesa con productos sin cobrar. fn_close_order_and_table libera
-- la mesa solo sin órdenes vivas: cobrar la principal no libera la mesa
-- mientras quede una cuenta en revisión.
--
-- PENDIENTE ANTES DE APLICAR: fn_transfer_table_session (transferir / unir
-- mesa) elige «la orden más nueva» de la sesión; con una cuenta en revisión
-- podría mover esa y dejar la otra huérfana. Se agrega en esta misma migración
-- cuando llegue su definición viva. NO aplicar sin esa parte.
--
-- LÍMITES CONOCIDOS (plan Hub, F5): un cobro offline encolado de la cuenta
-- original sí se aplica a su cuenta en revisión (es dinero que se cobró); la
-- cuenta retecleada queda abierta y hay que anularla a mano. Anular el
-- duplicado no devuelve insumos ya consumidos por cocina.
--
-- Cuerpos base vivos: supabase/tests/fixtures/live_table_open_release_20261010.sql
-- (fn_open_table, v_zone_table_status) y 20260819_0004 (candado de ítems).
-- Antes de aplicar, comparar huellas con la base viva.
--
-- IDEMPOTENTE. ROLLBACK: 20261010_0020_order_review_accounts_ROLLBACK.sql
-- Prueba local: supabase/tests/order_review_accounts_local_test.sh
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Identidad y revisión en orders
-- ---------------------------------------------------------------------------
alter table public.orders add column if not exists client_order_id text;
alter table public.orders add column if not exists review_reason text;
alter table public.orders add column if not exists review_source_order_id uuid;
alter table public.orders add column if not exists review_at timestamptz;

do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conname = 'orders_review_reason_check'
       and conrelid = 'public.orders'::regclass
  ) then
    alter table public.orders add constraint orders_review_reason_check
      check (review_reason is null or review_reason in (
        'offline_conflict', 'late_items_after_release', 'late_items_after_settle'));
  end if;
end $$;

create unique index if not exists uniq_orders_client_order_id
  on public.orders (client_order_id) where client_order_id is not null;
create index if not exists idx_orders_open_review
  on public.orders (session_id)
  where review_reason is not null and closed_at is null;

comment on column public.orders.client_order_id is
  'Identidad de una cuenta creada en un equipo (local-order-…). Única: la cola la usa para reencontrar SU cuenta.';
comment on column public.orders.review_reason is
  'Cuenta en revisión (no se cobra ni se elige como cuenta de la mesa hasta resolverla): offline_conflict | late_items_after_release | late_items_after_settle.';

create table if not exists public.order_review_events (
  id              uuid primary key default gen_random_uuid(),
  order_id        uuid not null,
  business_id     uuid,
  event           text not null check (event in (
                    'conflict_opened', 'late_items_moved', 'late_items_redirected',
                    'resolved_merge', 'resolved_promote', 'resolved_void')),
  source_order_id uuid,
  target_order_id uuid,
  session_id      uuid,
  table_id        uuid,
  reason          text,
  items_moved     integer,
  actor           uuid default auth.uid(),
  created_at      timestamptz not null default now()
);
create index if not exists idx_order_review_events_order
  on public.order_review_events (order_id);
create index if not exists idx_order_review_events_business
  on public.order_review_events (business_id, created_at desc);

-- Solo las funciones (security definer) la escriben; se consulta con service_role.
alter table public.order_review_events enable row level security;
revoke all on public.order_review_events from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. fn_open_table: la cuenta de la mesa es la principal
--    (cuerpo vivo del 10-oct; única diferencia: `and o.review_reason is null`)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_open_table(p_table_id uuid, p_user_id uuid, p_people_count integer DEFAULT 1, p_opened_by_employee_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_session_id uuid;
  v_order_id uuid;
  v_user_id uuid;
  v_business_id uuid;
begin
  if p_table_id is null then
    raise exception 'TABLE_ID_REQUIRED';
  end if;

  if auth.uid() is not null and p_user_id is not null and p_user_id <> auth.uid() then
    raise exception 'INVALID_USER_CONTEXT';
  end if;

  v_user_id := coalesce(auth.uid(), p_user_id);

  if v_user_id is null then
    raise exception 'USER_REQUIRED';
  end if;

  -- Validar que el empleado pertenece al business de la mesa si se pasó.
  if p_opened_by_employee_id is not null then
    select z.business_id
      into v_business_id
    from public.dining_tables t
    join public.zones z on z.id = t.zone_id
    where t.id = p_table_id;

    if v_business_id is null then
      raise exception 'TABLE_BUSINESS_NOT_FOUND';
    end if;

    if not exists (
      select 1 from public.employees e
      where e.id = p_opened_by_employee_id
        and e.business_id = v_business_id
        and e.status = 'active'
    ) then
      raise exception 'EMPLOYEE_NOT_IN_BUSINESS';
    end if;
  end if;

  perform public.fn_require_open_cash_session(v_user_id);

  -- Serialize by table to avoid double-open races.
  perform pg_advisory_xact_lock(hashtextextended(p_table_id::text, 0));

  select ts.id
    into v_session_id
  from public.table_sessions ts
  where ts.table_id = p_table_id
    and ts.closed_at is null
  order by ts.opened_at desc
  limit 1;

  if v_session_id is null then
    insert into public.table_sessions (
      table_id, opened_by, origin, waiter_user_id, people_count,
      opened_by_employee_id
    )
    values (
      p_table_id, v_user_id, 'dine_in', v_user_id,
      greatest(1, coalesce(p_people_count, 1)),
      p_opened_by_employee_id
    )
    returning id into v_session_id;
  end if;

  update public.dining_tables
     set state = 'occupied'
   where id = p_table_id
     and state is distinct from 'occupied';

  select o.id
    into v_order_id
  from public.orders o
  where o.session_id = v_session_id
    and o.closed_at is null
    and o.status_ext not in ('paid', 'void')
    and o.review_reason is null
  order by o.created_at desc
  limit 1;

  if v_order_id is null then
    insert into public.orders (session_id, status_ext, subtotal, discounts, tax, total, total_amount)
    values (v_session_id, 'open', 0, 0, 0, 0, 0)
    returning id into v_order_id;

    insert into public.order_checks (order_id, label, position)
    values (v_order_id, 'C1', 1)
    on conflict (order_id, position) do nothing;
  end if;

  return jsonb_build_object('session_id', v_session_id, 'order_id', v_order_id);
end;
$function$;

-- ---------------------------------------------------------------------------
-- 3. Subir una cuenta local a una mesa conservando su identidad
-- ---------------------------------------------------------------------------
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

revoke all on function public.fn_open_local_table_order(text, uuid, integer, uuid) from public, anon;
grant execute on function public.fn_open_local_table_order(text, uuid, integer, uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. Productos que llegan tarde: preservar, nunca rechazar ni mezclar
-- ---------------------------------------------------------------------------

-- Mesa tomada por otra cuenta: la cuenta liberada vuelve, con su MISMA
-- identidad, como cuenta en revisión dentro de la sesión actual. Corre dentro
-- del candado de mesa que ya tomó fn_reopen_orphan_order.
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

-- Cuenta ya cobrada: no se revive (dinero asentado, puede haber NCF). El
-- producto va a una cuenta en revisión de la sesión actual de la mesa, con la
-- cobrada como origen; si la mesa está libre se abre la sesión a nombre de
-- quien sube. Una sola cuenta en revisión por cuenta de origen.
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

revoke all on function public.fn_move_closed_order_to_review(uuid) from public, anon, authenticated;
revoke all on function public.fn_late_items_review_order(uuid) from public, anon, authenticated;
grant execute on function public.fn_move_closed_order_to_review(uuid) to service_role;
grant execute on function public.fn_late_items_review_order(uuid) to service_role;

-- El candado de ítems (20260819_0004) con los dos destinos nuevos. El camino
-- normal (orden abierta) sigue siendo una lectura por PK.
create or replace function public.fn_block_items_on_closed_order()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_state  text;
  v_target uuid;
  v_check  uuid;
begin
  if new.order_id is null then
    return new;
  end if;

  if not exists (
    select 1 from public.orders o
     where o.id = new.order_id
       and o.closed_at is not null
  ) then
    return new;
  end if;

  v_state := public.fn_reopen_orphan_order(new.order_id, 'order_item_insert');

  if v_state in ('revived', 'not_closed') then
    return new;
  elsif v_state = 'table_taken' then
    perform public.fn_move_closed_order_to_review(new.order_id);
    return new;
  elsif v_state = 'settled' then
    v_target := public.fn_late_items_review_order(new.order_id);
    if v_target is null then
      raise exception 'Esta cuenta ya fue cobrada. Abre la mesa otra vez para cargar productos nuevos.'
        using errcode = 'MP401';
    end if;
    select oc.id into v_check
      from public.order_checks oc
     where oc.order_id = v_target
       and not coalesce(oc.is_closed, false)
     order by oc.position
     limit 1;
    new.order_id := v_target;
    new.check_id := v_check;
    return new;
  else
    raise exception 'La orden ya no existe.'
      using errcode = 'MP403';
  end if;
end;
$function$;

alter function public.fn_block_items_on_closed_order() owner to postgres;

-- ---------------------------------------------------------------------------
-- 5. Salón: total sin cuentas en revisión + cuántas hay y su total
--    (definición viva del 10-oct; columnas nuevas AL FINAL)
--    CREATE OR REPLACE VIEW borra las opciones de la vista (security_invoker,
--    security_barrier…); los permisos los conserva. Se copian y se reaplican.
-- ---------------------------------------------------------------------------
create temp table _vzts_options (stmt text) on commit drop;
insert into _vzts_options
select format('alter view public.v_zone_table_status set (%s)', array_to_string(c.reloptions, ', '))
  from pg_class c
 where c.oid = 'public.v_zone_table_status'::regclass
   and c.reloptions is not null;

CREATE OR REPLACE VIEW public.v_zone_table_status AS
 SELECT t.id AS table_id,
    z.id AS zone_id,
    z.name AS zone_name,
    z.business_id,
    t.code,
    t.label,
    t.shape,
    t.capacity,
    t.state,
    s.id AS session_id,
    s.opened_by,
    s.opened_at,
    s.waiter_user_id,
    s.customer_name,
    s.people_count,
    COALESCE(( SELECT NULLIF(split_part(btrim(e.first_name), ' '::text, 1), ''::text) AS "nullif"
           FROM public.employees e
          WHERE e.id = s.opened_by_employee_id), ( SELECT NULLIF(split_part(btrim(e.first_name), ' '::text, 1), ''::text) AS "nullif"
           FROM public.employees e
          WHERE e.user_id = s.waiter_user_id AND e.business_id = z.business_id
         LIMIT 1), ( SELECT NULLIF(split_part(btrim(p.full_name), ' '::text, 1), ''::text) AS "nullif"
           FROM public.profiles p
          WHERE p.id = s.waiter_user_id), ( SELECT NULLIF(split_part(btrim(e.first_name), ' '::text, 1), ''::text) AS "nullif"
           FROM public.employees e
          WHERE e.user_id = s.opened_by AND e.business_id = z.business_id
         LIMIT 1), ( SELECT NULLIF(split_part(btrim(p.full_name), ' '::text, 1), ''::text) AS "nullif"
           FROM public.profiles p
          WHERE p.id = s.opened_by)) AS waiter_name,
    auth.uid() IS NOT NULL AND auth.uid() = COALESCE(s.waiter_user_id, s.opened_by) AS is_own,
        CASE
            WHEN s.opened_at IS NOT NULL AND s.closed_at IS NULL THEN EXTRACT(epoch FROM now() - s.opened_at)::integer / 60
            ELSE NULL::integer
        END AS minutes_open,
    COALESCE(( SELECT count(*) AS count
           FROM public.orders o
          WHERE o.session_id = s.id), 0::bigint) AS orders_count,
    COALESCE(( SELECT round(sum(
                CASE
                    WHEN oi.tax_mode = 'inclusive'::text THEN oi.unit_price * COALESCE(oi.qty, oi.quantity, 1::numeric) + COALESCE(( SELECT sum(m.price * m.qty) AS sum
                       FROM public.order_item_modifiers m
                      WHERE m.item_id = oi.id), 0::numeric) - COALESCE(oi.discounts, 0::numeric)
                    ELSE oi.total
                END), 2) AS round
           FROM public.order_items oi
             JOIN public.orders o2 ON o2.id = oi.order_id
          WHERE o2.session_id = s.id AND o2.closed_at IS NULL AND (o2.status_ext <> ALL (ARRAY['paid'::public.order_status, 'void'::public.order_status])) AND (oi.status <> ALL (ARRAY['paid'::public.item_status, 'void'::public.item_status]))
            AND o2.review_reason IS NULL), 0::numeric) AS total,
        CASE
            WHEN s.precheck_printed_at IS NOT NULL AND s.closed_at IS NULL THEN 'paying'::text
            ELSE NULL::text
        END AS status,
    COALESCE(( SELECT count(*) AS count
           FROM public.orders o3
          WHERE o3.session_id = s.id AND o3.closed_at IS NULL AND (o3.status_ext <> ALL (ARRAY['paid'::public.order_status, 'void'::public.order_status]))
            AND o3.review_reason IS NOT NULL), 0::bigint) AS review_orders_count,
    COALESCE(( SELECT round(sum(
                CASE
                    WHEN oi.tax_mode = 'inclusive'::text THEN oi.unit_price * COALESCE(oi.qty, oi.quantity, 1::numeric) + COALESCE(( SELECT sum(m.price * m.qty) AS sum
                       FROM public.order_item_modifiers m
                      WHERE m.item_id = oi.id), 0::numeric) - COALESCE(oi.discounts, 0::numeric)
                    ELSE oi.total
                END), 2) AS round
           FROM public.order_items oi
             JOIN public.orders o4 ON o4.id = oi.order_id
          WHERE o4.session_id = s.id AND o4.closed_at IS NULL AND (o4.status_ext <> ALL (ARRAY['paid'::public.order_status, 'void'::public.order_status])) AND (oi.status <> ALL (ARRAY['paid'::public.item_status, 'void'::public.item_status]))
            AND o4.review_reason IS NOT NULL), 0::numeric) AS review_total
   FROM public.dining_tables t
     JOIN public.zones z ON z.id = t.zone_id
     LEFT JOIN LATERAL ( SELECT s2.id,
            s2.table_id,
            s2.opened_by,
            s2.opened_at,
            s2.closed_at,
            s2.customer_name,
            s2.note,
            s2.origin,
            s2.waiter_user_id,
            s2.people_count,
            s2.business_id,
            s2.customer_id,
            s2.delivery_type,
            s2.opened_by_employee_id,
            s2.precheck_printed_at,
            s2.delivery_address
           FROM public.table_sessions s2
          WHERE s2.table_id = t.id AND s2.closed_at IS NULL
          ORDER BY s2.opened_at DESC
         LIMIT 1) s ON true;

do $$
declare r record;
begin
  for r in select stmt from _vzts_options loop
    execute r.stmt;
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 6. Resolver una cuenta en revisión
-- ---------------------------------------------------------------------------
create or replace function public.fn_resolve_review_order(
  p_order_id uuid,
  p_action   text,
  p_reason   text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_user     uuid := auth.uid();
  v_reason   text := nullif(btrim(coalesce(p_reason, '')), '');
  v_session  uuid;
  v_table    uuid;
  v_business uuid;
  v_review   text;
  v_closed   timestamptz;
  v_status   public.order_status;
  v_main     uuid;
  v_check    uuid;
  v_moved    integer := 0;
  v_void     text;
begin
  if v_user is null then
    raise exception 'USER_REQUIRED';
  end if;
  if p_action is null or p_action not in ('merge', 'void') then
    raise exception 'INVALID_ACTION';
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

  -- Candado de mesa ANTES de la fila (mismo orden que fn_open_table).
  if v_table is not null then
    perform pg_advisory_xact_lock(hashtextextended(v_table::text, 0));
  end if;

  select o.review_reason, o.closed_at, o.status_ext, o.session_id
    into v_review, v_closed, v_status, v_session
    from public.orders o
   where o.id = p_order_id
   for update;

  if v_review is null then
    return jsonb_build_object('outcome', 'not_in_review', 'order_id', p_order_id);
  end if;
  if v_closed is not null or v_status in ('paid'::public.order_status, 'void'::public.order_status) then
    return jsonb_build_object('outcome', 'already_closed', 'order_id', p_order_id);
  end if;

  if p_action = 'void' then
    if v_reason is null then
      raise exception 'REASON_REQUIRED';
    end if;
    v_void := public.fn_void_order_if_unpaid(p_order_id);
    if v_void <> 'voided' then
      return jsonb_build_object('outcome', v_void, 'order_id', p_order_id);
    end if;
    insert into public.order_review_events (
      order_id, business_id, event, session_id, table_id, reason
    ) values (p_order_id, v_business, 'resolved_void', v_session, v_table, v_reason);
    return jsonb_build_object('outcome', 'voided', 'order_id', p_order_id);
  end if;

  -- merge
  select o.id into v_main
    from public.orders o
   where o.session_id = v_session
     and o.id <> p_order_id
     and o.closed_at is null
     and o.status_ext not in ('paid', 'void')
     and o.review_reason is null
   order by o.created_at desc
   limit 1
   for update;

  if v_main is null then
    -- No queda otra cuenta: esta pasa a ser la de la mesa.
    update public.orders set review_reason = null where id = p_order_id;
    insert into public.order_review_events (
      order_id, business_id, event, session_id, table_id, reason
    ) values (p_order_id, v_business, 'resolved_promote', v_session, v_table, v_reason);
    return jsonb_build_object('outcome', 'promoted', 'order_id', p_order_id);
  end if;

  if exists (
    select 1 from public.payments p
     where p.order_id = p_order_id
       and p.status in ('pending', 'completed')
  ) then
    return jsonb_build_object('outcome', 'has_payments', 'order_id', p_order_id);
  end if;

  select oc.id into v_check
    from public.order_checks oc
   where oc.order_id = v_main
     and not coalesce(oc.is_closed, false)
   order by oc.position
   limit 1;

  with moved as (
    update public.order_items
       set order_id = v_main,
           check_id = v_check
     where order_id = p_order_id
       and status::text <> 'void'
    returning 1
  )
  select count(*) into v_moved from moved;

  perform public.fn_recalc_order_totals(v_main);
  perform public.fn_close_order_and_table(p_order_id, 'void'::public.order_status);

  insert into public.order_review_events (
    order_id, business_id, event, target_order_id, session_id, table_id, reason, items_moved
  ) values (p_order_id, v_business, 'resolved_merge', v_main, v_session, v_table, v_reason, v_moved);

  return jsonb_build_object('outcome', 'merged', 'order_id', p_order_id,
    'target_order_id', v_main, 'items_moved', v_moved);
end;
$function$;

revoke all on function public.fn_resolve_review_order(uuid, text, text) from public, anon;
grant execute on function public.fn_resolve_review_order(uuid, text, text) to authenticated, service_role;

commit;
