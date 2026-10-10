-- =============================================================================
-- 20261010_0030 — T02: liberar mesas solo con la confirmación de sus terminales
-- =============================================================================
--
-- PROBLEMA. Las tres liberaciones automáticas (cron fn_release_empty_tables(20),
-- el barrido del salón desde cualquier equipo y fn_release_empty_table al salir
-- de una mesa vacía) decidían solo con lo que veía el servidor: una cuenta sin
-- productos ni cobros. Un equipo aislado (sin red) podía tener productos de esa
-- cuenta en su cola: la cuenta se anulaba y la mesa se liberaba con información
-- incompleta. «Un timeout no prueba vacío».
--
-- PROTOCOLO.
--   1. Versión de la sesión: table_session_versions sube con cada cambio de sus
--      órdenes, líneas y cobros (disparadores). Tabla aparte para no generar
--      eventos de Realtime en table_sessions.
--   2. Participantes: cada terminal se registra al cargar la cuenta en línea
--      (fn_register_session_participant).
--   3. Pedido de liberación: el barrido (y la salida de una mesa vacía) ya no
--      libera directo: deja un pedido con la versión actual.
--   4. Confirmación: cada participante revisa su cola (y el op-log, si es el
--      Hub) y confirma esa versión con o sin pendientes
--      (fn_pending_release_requests / fn_ack_session_release).
--   5. Liberación: en una transacción con el candado de la mesa, solo si TODOS
--      los participantes confirmaron SIN pendientes la MISMA versión vigente.
--      Si entró un producto, un cobro o un cambio, la versión ya es otra y la
--      sesión se conserva.
--   - Sin participantes registrados (cuentas abiertas por versiones anteriores
--     de la app) no se puede comprobar: el barrido no la libera.
--   - Un equipo desconectado o sin confirmar retiene la sesión. Solo deja de
--     retenerla un equipo cerrado a distancia (device_sessions.revoked_at).
--
-- Reemplaza fn_release_empty_tables y fn_release_empty_table (mismas firmas:
-- el cron y las versiones anteriores de la app quedan protegidos) y agrega
-- fn_release_empty_table_v2 (la app nueva, con su equipo y su cola).
-- Cuerpos base comparados con la base viva el 2026-10-10: fn_release_empty_tables
-- es la de 20261010_0021_sweep_dine_in_30min (sobre la contención de
-- 20261010_0004): T02 conserva su mínimo de 30 min para las mesas de salón.
-- fn_release_empty_table viva se serializa con la fila de dining_tables (FOR
-- UPDATE), así que aquí se toman los dos candados.
--
-- ORDEN: va DESPUÉS de 20261010_0004, 0021 y 0023 (por eso su número; antes
-- se llamaba 0005). Aplicarlas antes que esta; su reversa restaura la salida
-- de 0023 (fila de la mesa + candado consultivo) y el barrido de 0021.
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Tablas
-- ---------------------------------------------------------------------------
create table if not exists public.table_session_versions (
  session_id uuid primary key references public.table_sessions(id) on delete cascade,
  version    bigint not null default 0,
  changed_at timestamptz not null default now()
);

create table if not exists public.table_session_participants (
  session_id    uuid not null references public.table_sessions(id) on delete cascade,
  device_id     text not null,
  business_id   uuid not null,
  registered_at timestamptz not null default now(),
  last_seen_at  timestamptz not null default now(),
  primary key (session_id, device_id)
);

create table if not exists public.table_session_release_requests (
  session_id   uuid primary key references public.table_sessions(id) on delete cascade,
  business_id  uuid not null,
  version      bigint not null,
  origin       text not null check (origin in ('sweep', 'leave')),
  order_id     uuid,
  requested_at timestamptz not null default now()
);

create index if not exists idx_session_release_requests_business
  on public.table_session_release_requests (business_id);

create table if not exists public.table_session_release_acks (
  session_id  uuid not null references public.table_sessions(id) on delete cascade,
  device_id   text not null,
  version     bigint not null,
  has_pending boolean not null,
  acked_at    timestamptz not null default now(),
  primary key (session_id, device_id)
);

-- Solo las funciones (security definer) las leen y escriben.
alter table public.table_session_versions enable row level security;
alter table public.table_session_participants enable row level security;
alter table public.table_session_release_requests enable row level security;
alter table public.table_session_release_acks enable row level security;
revoke all on public.table_session_versions from anon, authenticated;
revoke all on public.table_session_participants from anon, authenticated;
revoke all on public.table_session_release_requests from anon, authenticated;
revoke all on public.table_session_release_acks from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Versión de la sesión
-- ---------------------------------------------------------------------------
create or replace function public.fn_bump_session_version(p_session_id uuid)
returns void
language sql
security definer
set search_path = public
as $$
  insert into public.table_session_versions (session_id, version, changed_at)
  values (p_session_id, 1, now())
  on conflict (session_id) do update
     set version = public.table_session_versions.version + 1,
         changed_at = now();
$$;

create or replace function public.fn_session_version(p_session_id uuid)
returns bigint
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select v.version from public.table_session_versions v
      where v.session_id = p_session_id),
    0
  );
$$;

create or replace function public.trg_session_version_from_order()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op in ('UPDATE', 'DELETE') and old.session_id is not null then
    perform public.fn_bump_session_version(old.session_id);
  end if;
  if tg_op in ('INSERT', 'UPDATE') and new.session_id is not null
     and (tg_op = 'INSERT' or new.session_id is distinct from old.session_id) then
    perform public.fn_bump_session_version(new.session_id);
  end if;
  return null;
end;
$$;

-- Líneas y cobros: por su orden.
create or replace function public.trg_session_version_from_order_ref()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_session uuid;
begin
  if tg_op in ('UPDATE', 'DELETE') then
    select o.session_id into v_session from public.orders o where o.id = old.order_id;
    if v_session is not null then
      perform public.fn_bump_session_version(v_session);
    end if;
  end if;
  if tg_op in ('INSERT', 'UPDATE')
     and (tg_op = 'INSERT' or new.order_id is distinct from old.order_id) then
    select o.session_id into v_session from public.orders o where o.id = new.order_id;
    if v_session is not null then
      perform public.fn_bump_session_version(v_session);
    end if;
  end if;
  return null;
end;
$$;

drop trigger if exists trg_zz_session_version_orders on public.orders;
create trigger trg_zz_session_version_orders
  after insert or update or delete on public.orders
  for each row execute function public.trg_session_version_from_order();

drop trigger if exists trg_zz_session_version_items on public.order_items;
create trigger trg_zz_session_version_items
  after insert or update or delete on public.order_items
  for each row execute function public.trg_session_version_from_order_ref();

drop trigger if exists trg_zz_session_version_payments on public.payments;
create trigger trg_zz_session_version_payments
  after insert or update or delete on public.payments
  for each row execute function public.trg_session_version_from_order_ref();

-- ---------------------------------------------------------------------------
-- 3. Reglas comunes
-- ---------------------------------------------------------------------------
create or replace function public.fn_session_business(p_session_id uuid)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(ts.business_id, z.business_id)
    from public.table_sessions ts
    left join public.dining_tables dt on dt.id = ts.table_id
    left join public.zones z on z.id = dt.zone_id
   where ts.id = p_session_id;
$$;

-- Con JWT: solo alguien del negocio. Sin JWT solo llega service_role / cron.
create or replace function public.fn_assert_session_member(p_business_id uuid)
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is not null and not coalesce(
    exists (
      select 1 from public.user_businesses ub
       where ub.user_id = auth.uid() and ub.business_id = p_business_id
    )
    or exists (
      select 1 from public.current_user_business_ids() as c(business_id)
       where c.business_id = p_business_id
    ),
    false
  ) then
    raise exception 'NOT_A_MEMBER';
  end if;
end;
$$;

-- Un equipo cerrado a distancia por el dueño ya no retiene sesiones.
create or replace function public.fn_device_retired(
  p_business_id uuid,
  p_device_id text
)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if to_regclass('public.device_sessions') is null then
    return false;
  end if;
  return exists (
    select 1 from public.device_sessions d
     where d.business_id = p_business_id
       and d.device_id = p_device_id
       and d.revoked_at is not null
  );
end;
$$;

-- null = se puede liberar la versión [p_version]. Si no, el motivo.
create or replace function public.fn_session_release_blocker(
  p_session_id uuid,
  p_version bigint
)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_requested_at timestamptz;
  v_participants integer;
  v_pending integer;
  v_missing integer;
begin
  select r.requested_at into v_requested_at
    from public.table_session_release_requests r
   where r.session_id = p_session_id and r.version = p_version;
  if v_requested_at is null then
    return 'no_request';
  end if;

  select count(*),
         count(*) filter (
           where a.device_id is not null and a.version = p_version
             and a.acked_at >= v_requested_at and a.has_pending
         ),
         count(*) filter (
           where a.device_id is null or a.version <> p_version
              or a.acked_at < v_requested_at
         )
    into v_participants, v_pending, v_missing
    from public.table_session_participants p
    left join public.table_session_release_acks a
      on a.session_id = p.session_id and a.device_id = p.device_id
   where p.session_id = p_session_id
     and not public.fn_device_retired(p.business_id, p.device_id);

  if v_participants = 0 then
    return 'no_participants';
  end if;
  if v_pending > 0 then
    return 'pending_reported';
  end if;
  if v_missing > 0 then
    return 'awaiting_acks';
  end if;
  return null;
end;
$$;

-- Deja (o actualiza) el pedido de liberación de la versión vigente. Un pedido
-- de la misma versión conserva su hora: las confirmaciones ya dadas valen.
create or replace function public.fn_request_session_release(
  p_session_id uuid,
  p_origin text,
  p_order_id uuid
)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_version bigint := public.fn_session_version(p_session_id);
begin
  insert into public.table_session_release_requests (
    session_id, business_id, version, origin, order_id, requested_at
  )
  values (
    p_session_id, public.fn_session_business(p_session_id), v_version,
    p_origin, p_order_id, now()
  )
  on conflict (session_id) do update
     set version = excluded.version,
         origin = excluded.origin,
         order_id = excluded.order_id,
         requested_at = excluded.requested_at
   where public.table_session_release_requests.version <> excluded.version;
  return v_version;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Liberaciones (con el candado de la mesa ya tomado por quien llama)
-- ---------------------------------------------------------------------------

-- Barrido de UNA sesión: el paso 1 y el paso 2 de 20260814_0002, acotados.
create or replace function public.fn_release_session_sweep_locked(
  p_session_id uuid,
  p_cutoff timestamptz
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_batch integer := 0;
  v_table uuid;
begin
  with candidates as (
    select o.id,
           exists (
             select 1 from public.order_items oi
              where oi.order_id = o.id and oi.status = 'paid'
           ) as has_paid
      from public.orders o
     where o.session_id = p_session_id
       and o.closed_at is null
       and o.status_ext not in ('paid', 'void')
       and coalesce(o.created_at, 'epoch'::timestamptz) < p_cutoff
       and not exists (
         select 1 from public.order_items oi
          where oi.order_id = o.id
            and oi.status not in ('void', 'paid')
       )
  ),
  classified as (
    select c.id, c.has_paid,
      coalesce((
        select sum(p.amount) from public.payments p
         where p.order_id = c.id and p.status = 'completed'
      ), 0) as paid_amount,
      coalesce((
        select sum(oc.total) from public.order_checks oc
         where oc.order_id = c.id and oc.is_closed
      ), 0) as closed_checks_total
      from candidates c
  ),
  to_close as (
    select id,
      case
        when not has_paid then 'void'::public.order_status
        when paid_amount > 0
             and closed_checks_total > 0
             and paid_amount >= closed_checks_total - 1
          then 'paid'::public.order_status
        else null  -- 'paid' sin cobertura: NO tocar, dejar para revisión.
      end as final_status
      from classified
  ),
  updated as (
    update public.orders o
       set status_ext = t.final_status,
           closed_at = now()
      from to_close t
     where o.id = t.id
       and t.final_status is not null
    returning o.id
  )
  select count(*) into v_batch from updated;

  update public.table_sessions ts
     set closed_at = now()
   where ts.id = p_session_id
     and ts.closed_at is null
     and not exists (
       select 1 from public.orders o
        where o.session_id = ts.id
          and o.closed_at is null
          and o.status_ext not in ('paid', 'void')
     )
  returning ts.table_id into v_table;

  if v_table is not null then
    update public.dining_tables dt
       set state = 'available'
     where dt.id = v_table
       and dt.state <> 'available';
  end if;

  return coalesce(v_batch, 0);
end;
$$;

-- Salida de una mesa vacía: lo de 20260814_0001 después del candado.
create or replace function public.fn_release_left_order_locked(p_order_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_session_id     uuid;
  v_table_id       uuid;
  v_other_orders   integer;
  v_closed_session boolean := false;
begin
  select o.session_id, ts.table_id
    into v_session_id, v_table_id
    from public.orders o
    join public.table_sessions ts on ts.id = o.session_id
   where o.id = p_order_id;

  if exists (
    select 1 from public.order_items oi
     where oi.order_id = p_order_id
       and oi.status is distinct from 'void'
  ) then
    return jsonb_build_object('released', false, 'reason', 'order_has_items');
  end if;

  update public.orders
     set status_ext = 'void',
         closed_at  = now()
   where id = p_order_id
     and closed_at is null;

  select count(*)
    into v_other_orders
    from public.orders o
   where o.session_id = v_session_id
     and o.id <> p_order_id
     and o.closed_at is null
     and o.status_ext not in ('paid', 'void');

  if v_other_orders = 0 then
    update public.table_sessions
       set closed_at = now()
     where id = v_session_id
       and closed_at is null;
    v_closed_session := true;
    if v_table_id is not null then
      update public.dining_tables set state = 'available' where id = v_table_id;
    end if;
  end if;

  return jsonb_build_object(
    'released',       true,
    'closed_session', v_closed_session,
    'session_id',     v_session_id,
    'table_id',       v_table_id,
    'other_orders',   v_other_orders
  );
end;
$$;

-- Cumple un pedido ya confirmado por todos. null si no se pudo.
create or replace function public.fn_fulfill_session_release_locked(
  p_session_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_request public.table_session_release_requests%rowtype;
  v_version bigint := public.fn_session_version(p_session_id);
  v_blocker text;
  v_result jsonb;
  v_closed integer;
begin
  select * into v_request
    from public.table_session_release_requests
   where session_id = p_session_id;
  if not found then
    return jsonb_build_object('released', false, 'reason', 'no_request');
  end if;
  -- Entró un producto, un cobro o un cambio después del pedido.
  if v_request.version <> v_version then
    return jsonb_build_object('released', false, 'reason', 'changed_after_request');
  end if;
  v_blocker := public.fn_session_release_blocker(p_session_id, v_version);
  if v_blocker is not null then
    return jsonb_build_object('released', false, 'reason', v_blocker);
  end if;

  if v_request.origin = 'leave' and v_request.order_id is not null then
    v_result := public.fn_release_left_order_locked(v_request.order_id);
  else
    v_closed := public.fn_release_session_sweep_locked(p_session_id, now());
    v_result := jsonb_build_object(
      'released', true,
      'closed_orders', v_closed,
      'closed_session', exists (
        select 1 from public.table_sessions ts
         where ts.id = p_session_id and ts.closed_at is not null
      )
    );
  end if;

  if coalesce((v_result ->> 'released')::boolean, false) then
    delete from public.table_session_release_requests where session_id = p_session_id;
    delete from public.table_session_release_acks where session_id = p_session_id;
  end if;
  return v_result;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. RPC para las terminales
-- ---------------------------------------------------------------------------
create or replace function public.fn_register_session_participant(
  p_order_id uuid,
  p_device_id text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_session uuid;
  v_business uuid;
begin
  if p_order_id is null or coalesce(trim(p_device_id), '') = '' then
    return;
  end if;
  select o.session_id into v_session
    from public.orders o
    join public.table_sessions ts on ts.id = o.session_id
   where o.id = p_order_id and ts.closed_at is null;
  if v_session is null then
    return;
  end if;
  v_business := public.fn_session_business(v_session);
  perform public.fn_assert_session_member(v_business);
  insert into public.table_session_participants (session_id, device_id, business_id)
  values (v_session, p_device_id, v_business)
  on conflict (session_id, device_id) do update set last_seen_at = now();
end;
$$;

create or replace function public.fn_pending_release_requests(
  p_business_id uuid,
  p_device_id text
)
returns table (session_id uuid, version bigint, order_ids uuid[])
language plpgsql
security definer
set search_path = public
as $$
#variable_conflict use_column
begin
  perform public.fn_assert_session_member(p_business_id);
  return query
    select r.session_id,
           r.version,
           coalesce(array(
             select o.id from public.orders o
              where o.session_id = r.session_id
              order by o.created_at
           ), array[]::uuid[])
      from public.table_session_release_requests r
      join public.table_sessions ts on ts.id = r.session_id
      join public.table_session_participants p
        on p.session_id = r.session_id and p.device_id = p_device_id
      left join public.table_session_release_acks a
        on a.session_id = r.session_id and a.device_id = p_device_id
     where r.business_id = p_business_id
       and ts.closed_at is null
       and r.version = public.fn_session_version(r.session_id)
       and (a.device_id is null
            or a.version <> r.version
            or a.acked_at < r.requested_at
            or a.has_pending);
end;
$$;

create or replace function public.fn_ack_session_release(
  p_session_id uuid,
  p_device_id text,
  p_version bigint,
  p_has_pending boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_business uuid;
  v_table uuid;
begin
  select ts.table_id into v_table
    from public.table_sessions ts where ts.id = p_session_id;
  if not found then
    return jsonb_build_object('released', false, 'reason', 'session_not_found');
  end if;
  v_business := public.fn_session_business(p_session_id);
  perform public.fn_assert_session_member(v_business);
  if not exists (
    select 1 from public.table_session_participants p
     where p.session_id = p_session_id and p.device_id = p_device_id
  ) then
    return jsonb_build_object('released', false, 'reason', 'not_participant');
  end if;

  -- Mismos candados que abrir la mesa y liberarla (consultivo y la fila de
  -- la mesa, como fn_release_empty_table viva).
  if v_table is not null then
    perform pg_advisory_xact_lock(hashtextextended(v_table::text, 0));
    perform 1 from public.dining_tables where id = v_table for update;
  end if;

  insert into public.table_session_release_acks (
    session_id, device_id, version, has_pending, acked_at
  )
  values (p_session_id, p_device_id, p_version, coalesce(p_has_pending, true), now())
  on conflict (session_id, device_id) do update
     set version = excluded.version,
         has_pending = excluded.has_pending,
         acked_at = excluded.acked_at;

  if coalesce(p_has_pending, true) then
    return jsonb_build_object('released', false, 'reason', 'pending_reported');
  end if;
  if exists (
    select 1 from public.table_sessions ts
     where ts.id = p_session_id and ts.closed_at is not null
  ) then
    return jsonb_build_object('released', false, 'reason', 'session_closed');
  end if;
  return public.fn_fulfill_session_release_locked(p_session_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Liberaciones automáticas (mismas firmas)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_release_empty_tables(
  p_older_than_minutes integer DEFAULT 20,
  p_business_id uuid DEFAULT NULL::uuid
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
declare
  v_cutoff timestamptz := now() - make_interval(mins => greatest(0, coalesce(p_older_than_minutes, 20)));
  -- Mesas de salón: mínimo 30 min (20261010_0021; antes 6 h en 20261010_0004).
  -- T02 lo conserva.
  v_cutoff_dine_in timestamptz := now() - make_interval(mins => greatest(30, coalesce(p_older_than_minutes, 20)));
  v_closed int := 0;
  v_table  uuid;
  v_session uuid;
  v_version bigint;
  v_result jsonb;
begin
  -- Guard de tenant: si se pide acotado a un negocio, el caller debe pertenecer
  -- a él. El barrido global (p_business_id null) lo dispara solo pg_cron.
  if p_business_id is not null and not public.is_member_of_business(p_business_id) then
    raise exception 'forbidden';
  end if;

  -- Pedidos de sesiones ya cerradas: no esperan nada.
  delete from public.table_session_release_requests r
   where (p_business_id is null or r.business_id = p_business_id)
     and exists (
       select 1 from public.table_sessions ts
        where ts.id = r.session_id and ts.closed_at is not null
     );

  for v_table in
    select tbl
    from (
      -- Rama A: mesas con órdenes candidatas a cerrarse.
      select ts.table_id as tbl
        from public.orders o
        join public.table_sessions ts on ts.id = o.session_id
       where o.closed_at is null
         and ts.closed_at is null
         and o.status_ext not in ('paid', 'void')
         and coalesce(o.created_at, 'epoch'::timestamptz)
             < case when ts.origin::text = 'dine_in' then v_cutoff_dine_in else v_cutoff end
         and not exists (
           select 1 from public.order_items oi
            where oi.order_id = o.id
              and oi.status not in ('void', 'paid')
         )
         and (p_business_id is null or ts.business_id = p_business_id)

      union

      -- Rama B: mesas con sesiones ya vacías candidatas a cerrarse.
      select ts.table_id
        from public.table_sessions ts
       where ts.closed_at is null
         and coalesce(ts.opened_at, 'epoch'::timestamptz)
             < case when ts.origin::text = 'dine_in' then v_cutoff_dine_in else v_cutoff end
         and (p_business_id is null or ts.business_id = p_business_id)
         and not exists (
           select 1 from public.orders o
            where o.session_id = ts.id
              and o.closed_at is null
              and o.status_ext not in ('paid', 'void')
         )
    ) c
    where tbl is not null
    order by tbl
  loop
    -- Mesa ocupada por una apertura en vuelo: se salta, la agarra el próximo
    -- barrido. Nunca se hace esperar a un mesero por una tarea de limpieza.
    if not pg_try_advisory_xact_lock(hashtextextended(v_table::text, 0)) then
      continue;
    end if;
    -- La fila de la mesa (fn_open_table la retiene al ocuparla): si está
    -- tomada, también se salta.
    perform 1 from public.dining_tables where id = v_table for update skip locked;
    if not found then
      continue;
    end if;

    for v_session in
      select ts.id
        from public.table_sessions ts
       where ts.table_id = v_table
         and ts.closed_at is null
         and (p_business_id is null or ts.business_id = p_business_id)
         and (
           exists (
             select 1 from public.orders o
              where o.session_id = ts.id
                and o.closed_at is null
                and o.status_ext not in ('paid', 'void')
                and coalesce(o.created_at, 'epoch'::timestamptz)
             < case when ts.origin::text = 'dine_in' then v_cutoff_dine_in else v_cutoff end
                and not exists (
                  select 1 from public.order_items oi
                   where oi.order_id = o.id
                     and oi.status not in ('void', 'paid')
                )
           )
           or (
             coalesce(ts.opened_at, 'epoch'::timestamptz)
             < case when ts.origin::text = 'dine_in' then v_cutoff_dine_in else v_cutoff end
             and not exists (
               select 1 from public.orders o
                where o.session_id = ts.id
                  and o.closed_at is null
                  and o.status_ext not in ('paid', 'void')
             )
           )
         )
    loop
      v_version := public.fn_session_version(v_session);
      if public.fn_session_release_blocker(v_session, v_version) is null then
        v_result := public.fn_fulfill_session_release_locked(v_session);
        v_closed := v_closed + coalesce((v_result ->> 'closed_orders')::int, 0);
      else
        -- Sin todas las confirmaciones de esta versión: se pide (o se renueva
        -- el pedido) y la sesión se conserva.
        perform public.fn_request_session_release(v_session, 'sweep', null);
      end if;
    end loop;
  end loop;

  return v_closed;
end;
$function$;

COMMENT ON FUNCTION public.fn_release_empty_tables(integer, uuid) IS
  'Barrido de mesas vacías viejas (T02, 20261010_0030): libera una sesión solo '
  'si todos sus participantes confirmaron sin pendientes la versión vigente; si '
  'no, deja un pedido de liberación y la conserva.';

-- Salida de una mesa vacía desde una versión anterior de la app: no sabe qué
-- equipo llama, así que solo libera con todas las confirmaciones.
CREATE OR REPLACE FUNCTION public.fn_release_empty_table(p_order_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_session_id  uuid;
  v_table_id    uuid;
  v_business_id uuid;
BEGIN
  IF p_order_id IS NULL THEN
    RETURN jsonb_build_object('released', false, 'reason', 'null_order');
  END IF;

  SELECT o.session_id, ts.table_id
    INTO v_session_id, v_table_id
    FROM public.orders o
    JOIN public.table_sessions ts ON ts.id = o.session_id
   WHERE o.id = p_order_id;
  IF v_session_id IS NULL THEN
    RETURN jsonb_build_object('released', false, 'reason', 'order_not_found');
  END IF;
  v_business_id := public.fn_session_business(v_session_id);
  IF v_business_id IS NOT NULL
     AND NOT EXISTS (
       SELECT 1
         FROM public.current_user_business_ids() AS c(business_id)
        WHERE c.business_id = v_business_id
     ) THEN
    RAISE EXCEPTION 'No autorizado para liberar mesas de este negocio';
  END IF;

  -- Los dos candados de la mesa: el consultivo del barrido y la fila que
  -- fn_open_table retiene al ocuparla (la versión viva de esta función).
  IF v_table_id IS NOT NULL THEN
    PERFORM pg_advisory_xact_lock(hashtextextended(v_table_id::text, 0));
    PERFORM 1 FROM public.dining_tables WHERE id = v_table_id FOR UPDATE;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.order_items oi
     WHERE oi.order_id = p_order_id
       AND oi.status IS DISTINCT FROM 'void'
  ) THEN
    RETURN jsonb_build_object('released', false, 'reason', 'order_has_items');
  END IF;

  PERFORM public.fn_request_session_release(v_session_id, 'leave', p_order_id);
  RETURN public.fn_fulfill_session_release_locked(v_session_id)
         || jsonb_build_object('session_id', v_session_id);
END;
$function$;

-- La app nueva: el equipo que sale confirma con su cola en el mismo paso.
create or replace function public.fn_release_empty_table_v2(
  p_order_id uuid,
  p_device_id text,
  p_has_pending boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_session_id  uuid;
  v_table_id    uuid;
  v_business_id uuid;
  v_version     bigint;
begin
  if p_order_id is null or coalesce(trim(p_device_id), '') = '' then
    return jsonb_build_object('released', false, 'reason', 'null_order');
  end if;

  select o.session_id, ts.table_id
    into v_session_id, v_table_id
    from public.orders o
    join public.table_sessions ts on ts.id = o.session_id
   where o.id = p_order_id;
  if v_session_id is null then
    return jsonb_build_object('released', false, 'reason', 'order_not_found');
  end if;
  v_business_id := public.fn_session_business(v_session_id);
  perform public.fn_assert_session_member(v_business_id);

  if v_table_id is not null then
    perform pg_advisory_xact_lock(hashtextextended(v_table_id::text, 0));
    perform 1 from public.dining_tables where id = v_table_id for update;
  end if;

  if exists (
    select 1 from public.order_items oi
     where oi.order_id = p_order_id
       and oi.status is distinct from 'void'
  ) then
    return jsonb_build_object('released', false, 'reason', 'order_has_items');
  end if;
  if exists (
    select 1 from public.table_sessions ts
     where ts.id = v_session_id and ts.closed_at is not null
  ) then
    return jsonb_build_object('released', false, 'reason', 'session_closed');
  end if;

  insert into public.table_session_participants (session_id, device_id, business_id)
  values (v_session_id, p_device_id, v_business_id)
  on conflict (session_id, device_id) do update set last_seen_at = now();

  v_version := public.fn_request_session_release(v_session_id, 'leave', p_order_id);
  insert into public.table_session_release_acks (
    session_id, device_id, version, has_pending, acked_at
  )
  values (v_session_id, p_device_id, v_version, coalesce(p_has_pending, true), now())
  on conflict (session_id, device_id) do update
     set version = excluded.version,
         has_pending = excluded.has_pending,
         acked_at = excluded.acked_at;

  return public.fn_fulfill_session_release_locked(v_session_id)
         || jsonb_build_object('session_id', v_session_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. Permisos
-- ---------------------------------------------------------------------------
revoke all on function public.fn_bump_session_version(uuid) from public, anon, authenticated;
revoke all on function public.fn_session_version(uuid) from public, anon, authenticated;
revoke all on function public.fn_session_business(uuid) from public, anon, authenticated;
revoke all on function public.fn_assert_session_member(uuid) from public, anon, authenticated;
revoke all on function public.fn_device_retired(uuid, text) from public, anon, authenticated;
revoke all on function public.fn_session_release_blocker(uuid, bigint) from public, anon, authenticated;
revoke all on function public.fn_request_session_release(uuid, text, uuid) from public, anon, authenticated;
revoke all on function public.fn_release_session_sweep_locked(uuid, timestamptz) from public, anon, authenticated;
revoke all on function public.fn_release_left_order_locked(uuid) from public, anon, authenticated;
revoke all on function public.fn_fulfill_session_release_locked(uuid) from public, anon, authenticated;

revoke all on function public.fn_register_session_participant(uuid, text) from public, anon;
revoke all on function public.fn_pending_release_requests(uuid, text) from public, anon;
revoke all on function public.fn_ack_session_release(uuid, text, bigint, boolean) from public, anon;
revoke all on function public.fn_release_empty_table_v2(uuid, text, boolean) from public, anon;
grant execute on function public.fn_register_session_participant(uuid, text) to authenticated, service_role;
grant execute on function public.fn_pending_release_requests(uuid, text) to authenticated, service_role;
grant execute on function public.fn_ack_session_release(uuid, text, bigint, boolean) to authenticated, service_role;
grant execute on function public.fn_release_empty_table_v2(uuid, text, boolean) to authenticated, service_role;
REVOKE ALL ON FUNCTION public.fn_release_empty_table(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_release_empty_table(uuid) TO authenticated;

commit;
