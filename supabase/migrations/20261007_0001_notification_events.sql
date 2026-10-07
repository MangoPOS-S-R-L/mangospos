-- =============================================================================
-- 20261007_0001 — Avisos del dashboard: productos quitados después de cocina,
--                  órdenes anuladas y ventas anuladas
-- =============================================================================
--
-- EL PROBLEMA:
--   El dashboard avisaba "producto anulado" cuando un order_items pasaba a
--   status='void' (Realtime en la app + trigger hacia push-notify). En la
--   práctica:
--     * Quitar un producto de la cuenta es un DELETE (nunca pasa a 'void'):
--       no avisaba nunca, ni siquiera si ya había salido a cocina.
--     * Anular una orden abierta (fn_close_order_and_table 'void') no toca
--       order_items: no avisaba.
--     * Solo annulOrder (anular una venta cobrada) pone los ítems en 'void',
--       y avisaba UNA VEZ POR ÍTEM (8 productos = 8 pushes).
--     * El canal Realtime sobre order_items no puede filtrar por negocio: un
--       usuario con varios negocios veía avisos de otro.
--
-- REGLA: si el producto salió a cocina, quitarlo o bajarle la cantidad AVISA,
--   sin importar quién ni por dónde (pantalla de la mesa, subcuenta, caja
--   cliente del Hub, cola offline, otra app, Studio). Lo que nunca salió a
--   cocina ('draft' sin marca de envío) no avisa.
--
-- POR QUÉ NO SE APOYA EN order_item_removals (20260919_0002):
--   Ese registro es la auditoría del POS y tiene huecos para esto:
--     * Una reducción solo queda si la etiqueta [REDUCCION:] viaja en la
--       MISMA escritura. La caja cliente del Hub, la cola offline y el
--       respaldo REST de fn_update_item_details bajan la cantidad SIN
--       etiqueta (fn_update_item_qty) → no queda nada.
--     * Marca como "interno" todo borrado vía RPC que no sea fn_delete_item,
--       y todo lo hecho sin JWT.
--     * Si no resuelve el negocio (order_items/orders sin business_id), no
--       registra.
--   Aquí se mira order_items directamente y el negocio sale de
--   table_sessions. El registro del POS solo se usa para ENRIQUECER el texto
--   (motivo, operador con PIN, quién autorizó).
--
-- QUÉ HACE:
--   1. `notification_events`: una fila por aviso ya decidido (negocio, clave
--      de preferencia, título, cuerpo). El dashboard la escucha por Realtime
--      filtrando por business_id, y su INSERT dispara el push.
--   2. Fuentes (los triggers NUNCA abortan la operación del POS: cualquier
--      error se traga con un WARNING):
--        a) order_items DELETE (por sentencia) y bajada de qty/quantity (por
--           fila) de un ítem enviado a cocina. Lo de la misma orden y la
--           misma cuenta dentro de 5 s (o de la misma transacción) se junta
--           en UN aviso: borrar una subcuenta o quitar 3 productos seguidos.
--           Solo se excluyen las RPC que REDISTRIBUYEN cantidades sin quitar
--           nada (ver private.fn_notif_is_rewrite).
--        b) orders.status_ext → 'void': UN aviso por orden, solo si tenía
--           pagos completados ("Venta anulada") o algo enviado a cocina
--           ("Orden anulada"). Mesa vacía o con solo borradores → sin aviso.
--        c) payments 'completed' → 'cancelled' con la orden SIN anular:
--           anulación parcial (una subcuenta o un NCF de varios). Las piernas
--           de un pago mixto se juntan en UN aviso.
--   3. El motivo y quién lo hizo llegan DESPUÉS (fn_note_order_item_removal,
--      fn_approve_order_item_removal, la línea [ANULACION] de
--      table_sessions.note, fiscal_documents.cancellation_reason).
--      `fn_notification_event_refresh` vuelve a armar el texto; push-notify y
--      el dashboard la llaman unos segundos después del INSERT.
--   4. Push: AFTER INSERT → pg_net → Edge Function push-notify con
--      {"kind":"notification_event","event_id":…} y el bearer service_role de
--      private.dashboard_cron_config (20260617_billing_reminders_push).
--      Respaldo: un cron cada 2 min reintenta los avisos que no salieron
--      (pushed_at nulo). Sin esa config la fila igual se crea y el aviso
--      dentro de la app funciona.
--   5. Quita `push_order_item_void` (trigger creado a mano en producción que
--      mandaba un push por cada ítem en 'void'), si existe.
--
-- PREFERENCIAS (notification_preferences.event_type, modelo opt-out):
--   item_voided  → producto quitado después de cocina (clave de siempre)
--   order_voided → orden o venta anulada (nueva)
--
-- NO TOCA el registro de auditoría del POS ni sus reportes.
-- IDEMPOTENTE. ROLLBACK: 20261007_0001_notification_events_ROLLBACK.sql
-- Prueba local: supabase/tests/notification_events_local_test.sh (mangospos).
-- =============================================================================

begin;

create schema if not exists private;

-- ---------------------------------------------------------------------------
-- 1. Avisos
-- ---------------------------------------------------------------------------
create table if not exists public.notification_events (
  id            uuid primary key default gen_random_uuid(),
  business_id   uuid not null references public.businesses(id) on delete cascade,
  -- Clave de preferencia (notification_preferences.event_type).
  event_type    text not null,
  -- Qué pasó; decide cómo se arma el texto.
  kind          text not null check (kind in (
                  'items_removed', 'order_voided', 'sale_annulled',
                  'sale_partially_annulled')),
  order_id      uuid,
  -- items_removed: foto de cada producto quitado (el ítem borrado ya no
  -- existe): item_id, product_name, change (deleted|reduced), qty,
  -- qty_before, qty_after, reason (etiqueta [REDUCCION:] si vino).
  items         jsonb not null default '[]'::jsonb,
  payment_ids   uuid[] not null default '{}',
  -- La cuenta que hizo la operación (auth.uid()); respaldo del "Por:".
  actor_user_id uuid,
  source_txid   bigint not null default txid_current(),
  title         text not null,
  body          text not null,
  created_at    timestamptz not null default now(),
  -- Lo marca push-notify al enviar: un evento nunca sale dos veces.
  pushed_at     timestamptz
);

create index if not exists idx_notification_events_business_created
  on public.notification_events (business_id, created_at desc);
create index if not exists idx_notification_events_order
  on public.notification_events (order_id, created_at desc);
create index if not exists idx_notification_events_unpushed
  on public.notification_events (created_at)
  where pushed_at is null;

alter table public.notification_events enable row level security;

drop policy if exists notification_events_select on public.notification_events;
create policy notification_events_select on public.notification_events
  for select to authenticated
  using (business_id in (select public.current_user_business_ids()));

-- Solo lectura para la app; escriben los triggers (SECURITY DEFINER) y
-- push-notify (service_role).
revoke all on public.notification_events from anon, authenticated;
grant select on public.notification_events to authenticated;
grant all on public.notification_events to service_role;

comment on table public.notification_events is
  'Avisos del dashboard (20261007_0001): producto quitado después de cocina, '
  'orden anulada, venta anulada. Los crean triggers; el dashboard los escucha '
  'por Realtime y su INSERT dispara push-notify.';

-- ---------------------------------------------------------------------------
-- 2. Armado del texto
-- ---------------------------------------------------------------------------
create or replace function private.fn_notif_money(p numeric)
returns text
language sql
immutable
as $$
  select 'RD$ ' || to_char(coalesce(p, 0), 'FM999,999,999,990.00')
$$;

create or replace function private.fn_notif_qty(p numeric)
returns text
language sql
immutable
as $$
  select trim_scale(coalesce(p, 0))::text
$$;

-- Nombre de una persona: el empleado (PIN) o, si no, la cuenta que operó.
create or replace function private.fn_notif_person(
  p_business uuid,
  p_employee uuid,
  p_user     uuid
)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_name text;
begin
  if p_employee is not null then
    select nullif(trim(concat_ws(' ', e.first_name, e.last_name)), '')
      into v_name
    from public.employees e
    where e.id = p_employee;
    if v_name is not null then
      return v_name;
    end if;
  end if;

  if p_user is not null then
    select nullif(trim(concat_ws(' ', e.first_name, e.last_name)), '')
      into v_name
    from public.employees e
    where e.user_id = p_user
      and e.business_id = p_business
    limit 1;
    if v_name is not null then
      return v_name;
    end if;
    begin
      select nullif(trim(p.full_name), '')
        into v_name
      from public.profiles p
      where p.id = p_user;
    exception when others then
      v_name := null;
    end;
  end if;

  return v_name;
end;
$$;

-- Dónde pasó: mesa, venta rápida, etc. (misma regla que el dashboard:
-- label → code → 'Mesa'), con el cliente si lo hay.
create or replace function private.fn_notif_place(
  p_order uuid,
  out place        text,
  out session_note text,
  out order_total  numeric
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_customer text;
begin
  select
    case
      when ts.origin::text = 'manual' then 'Venta manual'
      when ts.origin::text in ('quick', 'quick_sale') then 'Venta rápida'
      when ts.origin::text = 'delivery' then 'Delivery'
      when ts.origin::text = 'self_service' then 'Autoservicio'
      when dt.id is not null then coalesce(nullif(trim(dt.label), ''), dt.code, 'Mesa')
      else 'Venta'
    end,
    nullif(trim(ts.customer_name), ''),
    ts.note,
    o.total
    into place, v_customer, session_note, order_total
  from public.orders o
  left join public.table_sessions ts on ts.id = o.session_id
  left join public.dining_tables dt  on dt.id = ts.table_id
  where o.id = p_order;

  if v_customer is not null and v_customer is distinct from place then
    place := coalesce(place, 'Venta') || ' (' || v_customer || ')';
  end if;
end;
$$;

-- Última línea `[ANULACION][iso-ts] actor: motivo` de table_sessions.note
-- (formato de appendVoidAuditNote en el POS).
create or replace function private.fn_notif_void_note(
  p_note     text,
  out actor  text,
  out reason text
)
language plpgsql
immutable
as $$
declare
  v_m text[];
begin
  select t.m
    into v_m
  from regexp_matches(
         coalesce(p_note, ''),
         '\[ANULACION\]\[[^\]]*\]\s*([^:\n]*):\s*([^\n]*)',
         'g'
       ) with ordinality as t(m, n)
  order by t.n desc
  limit 1;

  actor := nullif(trim(v_m[1]), '');
  -- 'Usuario' es el relleno del POS cuando no sabe quién: no aporta.
  if actor = 'Usuario' then
    actor := null;
  end if;
  reason := nullif(trim(v_m[2]), '');
end;
$$;

create or replace function private.fn_notif_text(
  p_kind     text,
  p_business uuid,
  p_order    uuid,
  p_items    jsonb,
  p_payments uuid[],
  p_actor    uuid,
  p_since    timestamptz,
  out title  text,
  out body   text
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_place       text;
  v_note        text;
  v_total       numeric;
  v_count       integer;
  v_all_reduced boolean;
  v_lines       text;
  v_tag_reason  text;
  v_reason      text;
  v_code        text;
  v_waste       boolean;
  v_emp         uuid;
  v_approver_id uuid;
  v_who         text;
  v_approver    text;
  v_amount      numeric;
  v_ncf         text;
  v_cancel_by   uuid;
  v_check       text;
  v_note_actor  text;
  v_note_reason text;
begin
  select pl.place, pl.session_note, pl.order_total
    into v_place, v_note, v_total
  from private.fn_notif_place(p_order) pl;

  if p_kind = 'items_removed' then
    select count(*)::int,
           coalesce(bool_and(i.value ->> 'change' = 'reduced'), false),
           (array_agg(nullif(trim(i.value ->> 'reason'), '') order by i.ord)
              filter (where nullif(trim(i.value ->> 'reason'), '') is not null))[1]
      into v_count, v_all_reduced, v_tag_reason
    from jsonb_array_elements(coalesce(p_items, '[]'::jsonb))
           with ordinality as i(value, ord);
    if v_count = 0 then
      return;
    end if;

    select string_agg(l.line, ', ' order by l.ord)
      into v_lines
    from (
      select
        i.ord,
        case
          when i.value ->> 'change' = 'reduced' then
            coalesce(i.value ->> 'product_name', 'Producto') || ' ('
              || private.fn_notif_qty((i.value ->> 'qty_before')::numeric) || ' → '
              || private.fn_notif_qty((i.value ->> 'qty_after')::numeric) || ')'
          else
            private.fn_notif_qty((i.value ->> 'qty')::numeric) || ' x '
              || coalesce(i.value ->> 'product_name', 'Producto')
        end as line
      from jsonb_array_elements(p_items) with ordinality as i(value, ord)
    ) l
    where l.ord <= 4;
    if v_count > 4 then
      v_lines := v_lines || ' y ' || (v_count - 4) || ' más';
    end if;

    -- Motivo, operador (PIN) y aprobador: el registro del POS los anota
    -- después del borrado. Opcional: sin la tabla o sin las columnas de
    -- 20260920_0002 / 20261005_0003, el texto sale sin ese dato.
    begin
      select
        nullif(trim(x.reason), ''),
        nullif(trim(to_jsonb(x) ->> 'reason_code'), ''),
        (to_jsonb(x) ->> 'is_waste')::boolean,
        x.reason_employee_id,
        (to_jsonb(x) ->> 'approved_by_employee_id')::uuid
        into v_reason, v_code, v_waste, v_emp, v_approver_id
      from public.order_item_removals x
      where x.item_id in (
              select (i.value ->> 'item_id')::uuid
              from jsonb_array_elements(p_items) i
            )
        and x.removed_at >= coalesce(p_since, now()) - interval '1 minute'
      order by
        (x.reason is not null or (to_jsonb(x) ->> 'reason_code') is not null) desc,
        ((to_jsonb(x) ->> 'approved_by_employee_id') is not null) desc,
        x.removed_at
      limit 1;
    exception when others then
      v_reason := null;
      v_code := null;
      v_waste := null;
      v_emp := null;
      v_approver_id := null;
    end;

    if v_reason is null and v_code is not null then
      begin
        select nullif(trim(rr.label), '')
          into v_reason
        from public.order_item_removal_reasons rr
        where rr.business_id = p_business
          and rr.code = v_code
        limit 1;
      exception when others then
        v_reason := null;
      end;
      v_reason := coalesce(v_reason, v_code);
    end if;
    v_reason := coalesce(v_tag_reason, v_reason);

    v_who := private.fn_notif_person(p_business, v_emp, p_actor);
    v_approver := private.fn_notif_person(p_business, v_approver_id, null);
    if v_approver is not distinct from v_who then
      v_approver := null;
    end if;

    title := case
      when v_all_reduced then 'Cantidad reducida'
      when v_count = 1 then 'Producto eliminado'
      else 'Productos eliminados'
    end;
    body := coalesce(v_place, 'Venta') || ' · ' || v_lines || '.'
      || coalesce(' Motivo: ' || v_reason
                  || case when v_waste then ' (merma)' else '' end || '.', '')
      || coalesce(' Por: ' || v_who || '.', '')
      || coalesce(' Autorizó: ' || v_approver || '.', '');
    return;
  end if;

  if p_kind = 'order_voided' then
    select a.actor, a.reason
      into v_note_actor, v_note_reason
    from private.fn_notif_void_note(v_note) a;
    v_who := coalesce(v_note_actor, private.fn_notif_person(p_business, null, p_actor));

    title := 'Orden anulada';
    body := coalesce(v_place, 'Venta') || ' · Cuenta de '
      || private.fn_notif_money(v_total) || ' sin cobrar.'
      || coalesce(' Motivo: ' || v_note_reason || '.', '')
      || coalesce(' Por: ' || v_who || '.', '');
    return;
  end if;

  if p_kind in ('sale_annulled', 'sale_partially_annulled') then
    select coalesce(sum(p.amount - coalesce(p.change_amount, 0)), 0)
      into v_amount
    from public.payments p
    where p.id = any(p_payments);
    if coalesce(v_amount, 0) = 0 and p_kind = 'sale_annulled' then
      v_amount := v_total;
    end if;

    -- Motivo, NCF y quién: el comprobante fiscal de esos pagos (lo anula el
    -- POS después de cancelar los pagos, de ahí el refresh).
    begin
      select
        nullif(trim(fd.cancellation_reason), ''),
        nullif(trim(to_jsonb(fd) ->> 'ncf_number'), ''),
        (to_jsonb(fd) ->> 'cancelled_by')::uuid
        into v_reason, v_ncf, v_cancel_by
      from public.fiscal_documents fd
      where fd.id in (
              select p.fiscal_document_id
              from public.payments p
              where p.id = any(p_payments)
            )
         or (p_kind = 'sale_annulled' and fd.order_id = p_order)
      order by (fd.cancellation_reason is not null) desc
      limit 1;
    exception when others then
      v_reason := null;
    end;

    if v_reason is null and p_kind = 'sale_annulled' then
      begin
        select nullif(trim(sn.cancellation_reason), '')
          into v_reason
        from public.sales_notes sn
        where sn.order_id = p_order
          and sn.cancellation_reason is not null
        limit 1;
      exception when others then
        v_reason := null;
      end;
    end if;

    if p_kind = 'sale_annulled' then
      select a.actor, a.reason
        into v_note_actor, v_note_reason
      from private.fn_notif_void_note(v_note) a;
      v_reason := coalesce(v_reason, v_note_reason);
    end if;

    v_who := coalesce(
      private.fn_notif_person(p_business, null, v_cancel_by),
      v_note_actor,
      private.fn_notif_person(p_business, null, p_actor)
    );

    title := 'Venta anulada';
    if p_kind = 'sale_annulled' then
      body := coalesce(v_place, 'Venta') || ' · '
        || private.fn_notif_money(v_amount) || ' cobrados'
        || coalesce(' · NCF ' || v_ncf, '') || '.';
    else
      select string_agg(distinct oc.label, ', ')
        into v_check
      from public.payments p
      join public.order_checks oc on oc.id = p.check_id
      where p.id = any(p_payments);
      body := coalesce(v_place, 'Venta')
        || coalesce(' · Subcuenta ' || v_check, '') || ' · '
        || private.fn_notif_money(v_amount) || ' anulados'
        || coalesce(' · NCF ' || v_ncf, '')
        || '; la cuenta volvió a quedar abierta.';
    end if;
    body := body
      || coalesce(' Motivo: ' || v_reason || '.', '')
      || coalesce(' Por: ' || v_who || '.', '');
    return;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Productos quitados después de cocina
-- ---------------------------------------------------------------------------

-- ¿La operación en curso es una RPC que REDISTRIBUYE cantidades sin quitar
-- nada? Dividir la cuenta borra/achica filas y las recrea; mover a otra
-- subcuenta o transferir la mesa parte filas. Lista verificada el 2026-10-07
-- con el grafo de llamadas de las migraciones (las únicas funciones que bajan
-- qty o borran order_items son estas, fn_delete_item y fn_update_item_details)
-- y las RPC que llaman mangospos y mangospos-apple. TODO lo demás (REST,
-- fn_delete_item, fn_update_item_qty, fn_update_item_details, RPC
-- desconocidas, Studio, cron) cuenta como quitar. Si se agrega otra RPC que
-- redistribuya, va aquí.
create or replace function private.fn_notif_is_rewrite()
returns boolean
language sql
stable
as $$
  select coalesce(current_setting('request.path', true), '') ~
    '/rpc/(fn_split_items_equally|fn_explode_items_to_units|fn_consolidate_order_to_integer|fn_consolidate_keeper_atomic|fn_move_item_to_check|fn_move_items_to_check_batch|fn_transfer_table_session)/?$'
$$;

-- ¿Salió a cocina? Todo lo que dejó de ser borrador, o un borrador con marca
-- de envío. 'void' ya avisó como venta anulada.
create or replace function private.fn_notif_item_was_sent(p_item jsonb)
returns boolean
language sql
immutable
as $$
  select coalesce(p_item ->> 'status', 'draft') <> 'void'
     and (coalesce(p_item ->> 'status', 'draft') <> 'draft'
          or p_item ->> 'kitchen_sent_at' is not null)
$$;

-- Agrega productos quitados al aviso abierto de esa orden (misma cuenta,
-- todavía sin enviar y de hace menos de 5 s o de la misma transacción) o
-- crea uno nuevo. push-notify y el dashboard esperan más de 5 s antes de
-- leer el texto, así que el aviso sale completo.
create or replace function private.fn_notif_add_removed_items(
  p_order    uuid,
  p_business uuid,
  p_items    jsonb,
  p_actor    uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_business uuid;
  v_id       uuid;
  v_items    jsonb;
  v_created  timestamptz;
  v_title    text;
  v_body     text;
begin
  if p_items is null or jsonb_array_length(p_items) = 0 then
    return;
  end if;

  select ts.business_id
    into v_business
  from public.orders o
  join public.table_sessions ts on ts.id = o.session_id
  where o.id = p_order;
  v_business := coalesce(v_business, p_business);
  if v_business is null then
    raise warning 'fn_notif_add_removed_items: sin negocio para la orden %', p_order;
    return;
  end if;

  select e.id, e.items, e.created_at
    into v_id, v_items, v_created
  from public.notification_events e
  where e.kind = 'items_removed'
    and e.business_id = v_business
    and e.order_id is not distinct from p_order
    and e.actor_user_id is not distinct from p_actor
    and e.pushed_at is null
    and (e.source_txid = txid_current()
         or e.created_at > clock_timestamp() - interval '5 seconds')
  order by e.created_at desc
  limit 1
  for update;

  v_items := coalesce(v_items, '[]'::jsonb) || p_items;

  select t.title, t.body
    into v_title, v_body
  from private.fn_notif_text(
         'items_removed', v_business, p_order, v_items, '{}'::uuid[],
         p_actor, coalesce(v_created, now())) t;

  if v_id is null then
    insert into public.notification_events (
      business_id, event_type, kind, order_id, items, actor_user_id,
      title, body
    )
    values (
      v_business, 'item_voided', 'items_removed', p_order, v_items, p_actor,
      coalesce(v_title, 'Producto eliminado'), coalesce(v_body, '')
    );
  else
    update public.notification_events e
       set items = v_items,
           title = coalesce(v_title, e.title),
           body = coalesce(v_body, e.body)
     where e.id = v_id;
  end if;
end;
$$;

-- a1) Borrados: por sentencia, para que borrar una subcuenta entera sea un
--     solo aviso por orden.
create or replace function public.fn_notif_on_items_deleted()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid;
  r       record;
begin
  begin
    if private.fn_notif_is_rewrite() then
      return null;
    end if;
    v_actor := auth.uid();

    for r in
      select
        d.order_id,
        (array_agg(d.business_id) filter (where d.business_id is not null))[1]
          as business_id,
        jsonb_agg(
          jsonb_build_object(
            'item_id', d.id,
            'product_name', d.product_name,
            'change', 'deleted',
            'qty', d.q,
            'qty_before', d.q,
            'qty_after', 0
          )
          order by d.created_at, d.product_name
        ) as items
      from (
        select
          o.order_id,
          o.id,
          o.product_name::text as product_name,
          o.created_at,
          (to_jsonb(o) ->> 'business_id')::uuid as business_id,
          coalesce(nullif(o.qty, 0), (to_jsonb(o) ->> 'quantity')::numeric, 1) as q
        from old_rows o
        where private.fn_notif_item_was_sent(to_jsonb(o))
      ) d
      group by d.order_id
    loop
      begin
        perform private.fn_notif_add_removed_items(
          r.order_id, r.business_id, r.items, v_actor);
      exception when others then
        raise warning 'fn_notif_on_items_deleted (orden %): % (%)',
          r.order_id, sqlerrm, sqlstate;
      end;
    end loop;
  exception when others then
    raise warning 'fn_notif_on_items_deleted: % (%)', sqlerrm, sqlstate;
  end;
  return null;
end;
$$;

drop trigger if exists trg_zz_notif_items_deleted on public.order_items;
create trigger trg_zz_notif_items_deleted
  after delete on public.order_items
  referencing old table as old_rows
  for each statement
  execute function public.fn_notif_on_items_deleted();

-- a2) Bajada de cantidad, con o sin etiqueta [REDUCCION:] (la caja cliente
--     del Hub y la cola offline bajan la cantidad sin etiqueta).
create or replace function public.fn_notif_on_item_reduced()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old      numeric;
  v_new      numeric;
  v_old_tags integer;
  v_new_tags integer;
  v_reason   text;
begin
  begin
    if not private.fn_notif_item_was_sent(to_jsonb(old)) then
      return null;
    end if;

    -- qty es la cantidad de verdad; quantity (entero) es la heredada.
    if new.qty is distinct from old.qty then
      v_old := coalesce(old.qty, 0);
      v_new := coalesce(new.qty, 0);
    else
      v_old := coalesce((to_jsonb(old) ->> 'quantity')::numeric, 0);
      v_new := coalesce((to_jsonb(new) ->> 'quantity')::numeric, 0);
    end if;
    if v_new >= v_old - 0.0001 then
      return null;
    end if;

    if private.fn_notif_is_rewrite() then
      return null;
    end if;

    -- El motivo, si la etiqueta [REDUCCION:…] llegó en esta misma escritura.
    v_old_tags := (length(coalesce(old.notes, ''))
      - length(replace(coalesce(old.notes, ''), '[REDUCCION:', '')));
    v_new_tags := (length(coalesce(new.notes, ''))
      - length(replace(coalesce(new.notes, ''), '[REDUCCION:', '')));
    if v_new_tags > v_old_tags then
      select nullif(trim(t.m[1]), '')
        into v_reason
      from regexp_matches(new.notes, '\[REDUCCION:([^\]]*)\]', 'g')
             with ordinality as t(m, n)
      order by t.n desc
      limit 1;
    end if;

    perform private.fn_notif_add_removed_items(
      new.order_id,
      (to_jsonb(new) ->> 'business_id')::uuid,
      jsonb_build_array(
        jsonb_build_object(
          'item_id', new.id,
          'product_name', new.product_name,
          'change', 'reduced',
          'qty', v_old - v_new,
          'qty_before', v_old,
          'qty_after', v_new,
          'reason', v_reason
        )
      ),
      auth.uid()
    );
  exception when others then
    raise warning 'fn_notif_on_item_reduced: % (%)', sqlerrm, sqlstate;
  end;
  return null;
end;
$$;

drop trigger if exists trg_zz_notif_item_reduced on public.order_items;
create trigger trg_zz_notif_item_reduced
  after update of qty, quantity on public.order_items
  for each row
  when (new.qty is distinct from old.qty or new.quantity is distinct from old.quantity)
  execute function public.fn_notif_on_item_reduced();

-- ---------------------------------------------------------------------------
-- 4. Orden anulada (abierta con algo enviado a cocina, o venta cobrada)
-- ---------------------------------------------------------------------------
create or replace function public.fn_notif_on_order_void()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_business uuid;
  v_payments uuid[];
  v_kind     text;
  v_actor    uuid;
  v_title    text;
  v_body     text;
begin
  begin
    select ts.business_id
      into v_business
    from public.table_sessions ts
    where ts.id = new.session_id;
    if v_business is null then
      return null;
    end if;

    -- Una orden avisa su anulación una sola vez.
    if exists (
      select 1
      from public.notification_events e
      where e.order_id = new.id
        and e.kind in ('order_voided', 'sale_annulled')
    ) then
      return null;
    end if;

    -- annulOrder anula la orden ANTES de cancelar los pagos y de pasar los
    -- ítems a 'void': aquí todavía se ven como estaban.
    select coalesce(array_agg(p.id order by p.created_at), '{}'::uuid[])
      into v_payments
    from public.payments p
    where p.order_id = new.id
      and p.status = 'completed';

    if cardinality(v_payments) > 0 then
      v_kind := 'sale_annulled';
    elsif exists (
      select 1
      from public.order_items i
      where i.order_id = new.id
        and private.fn_notif_item_was_sent(to_jsonb(i))
    ) then
      v_kind := 'order_voided';
    else
      -- Mesa vacía o solo borradores: nada salió a cocina.
      return null;
    end if;

    v_actor := auth.uid();
    select t.title, t.body
      into v_title, v_body
    from private.fn_notif_text(
           v_kind, v_business, new.id, '[]'::jsonb, v_payments, v_actor,
           now()) t;

    insert into public.notification_events (
      business_id, event_type, kind, order_id, payment_ids, actor_user_id,
      title, body
    )
    values (
      v_business, 'order_voided', v_kind, new.id, v_payments, v_actor,
      coalesce(v_title, 'Orden anulada'), coalesce(v_body, '')
    );
  exception when others then
    raise warning 'fn_notif_on_order_void: % (%)', sqlerrm, sqlstate;
  end;
  return null;
end;
$$;

drop trigger if exists trg_zz_notif_order_void on public.orders;
create trigger trg_zz_notif_order_void
  after update of status_ext on public.orders
  for each row
  when (
    new.status_ext::text = 'void'
    and old.status_ext::text is distinct from 'void'
  )
  execute function public.fn_notif_on_order_void();

-- ---------------------------------------------------------------------------
-- 5. Anulación parcial de una venta (la orden sigue viva)
-- ---------------------------------------------------------------------------
create or replace function public.fn_notif_on_payment_cancel()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_status text;
  v_id     uuid;
  v_ids    uuid[];
  v_actor  uuid;
  v_title  text;
  v_body   text;
begin
  begin
    if new.order_id is null then
      return null;
    end if;

    select o.status_ext::text
      into v_status
    from public.orders o
    where o.id = new.order_id;
    -- Anulación total: la orden ya quedó 'void' y avisó fn_notif_on_order_void.
    if v_status is null or v_status = 'void' then
      return null;
    end if;

    select e.id, e.payment_ids
      into v_id, v_ids
    from public.notification_events e
    where e.source_txid = txid_current()
      and e.kind = 'sale_partially_annulled'
      and e.order_id = new.order_id
    limit 1;

    v_ids := coalesce(v_ids, '{}'::uuid[]) || new.id;
    v_actor := auth.uid();

    select t.title, t.body
      into v_title, v_body
    from private.fn_notif_text(
           'sale_partially_annulled', new.business_id, new.order_id,
           '[]'::jsonb, v_ids, v_actor, now()) t;

    if v_id is null then
      insert into public.notification_events (
        business_id, event_type, kind, order_id, payment_ids, actor_user_id,
        title, body
      )
      values (
        new.business_id, 'order_voided', 'sale_partially_annulled',
        new.order_id, v_ids, v_actor, coalesce(v_title, 'Venta anulada'),
        coalesce(v_body, '')
      );
    else
      update public.notification_events e
         set payment_ids = v_ids,
             title = coalesce(v_title, e.title),
             body = coalesce(v_body, e.body)
       where e.id = v_id;
    end if;
  exception when others then
    raise warning 'fn_notif_on_payment_cancel: % (%)', sqlerrm, sqlstate;
  end;
  return null;
end;
$$;

drop trigger if exists trg_zz_notif_payment_cancel on public.payments;
create trigger trg_zz_notif_payment_cancel
  after update of status on public.payments
  for each row
  when (old.status = 'completed' and new.status = 'cancelled')
  execute function public.fn_notif_on_payment_cancel();

-- ---------------------------------------------------------------------------
-- 6. Texto final (motivo y quién llegan después del hecho)
-- ---------------------------------------------------------------------------
create or replace function public.fn_notification_event_refresh(p_event_id uuid)
returns table (
  id          uuid,
  business_id uuid,
  event_type  text,
  kind        text,
  title       text,
  body        text,
  created_at  timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
#variable_conflict use_column
declare
  v_e     public.notification_events;
  v_role  text;
  v_title text;
  v_body  text;
begin
  select * into v_e from public.notification_events n where n.id = p_event_id;
  if not found then
    return;
  end if;

  v_role := coalesce(
    nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role',
    ''
  );
  if v_role <> 'service_role'
     and v_e.business_id not in (select public.current_user_business_ids()) then
    return;
  end if;

  begin
    select t.title, t.body
      into v_title, v_body
    from private.fn_notif_text(
           v_e.kind, v_e.business_id, v_e.order_id, v_e.items,
           v_e.payment_ids, v_e.actor_user_id, v_e.created_at) t;
    if v_title is not null
       and (v_title, v_body) is distinct from (v_e.title, v_e.body) then
      update public.notification_events n
         set title = v_title,
             body = v_body
       where n.id = v_e.id;
      v_e.title := v_title;
      v_e.body := v_body;
    end if;
  exception when others then
    raise warning 'fn_notification_event_refresh: % (%)', sqlerrm, sqlstate;
  end;

  return query
    select v_e.id, v_e.business_id, v_e.event_type, v_e.kind, v_e.title,
           v_e.body, v_e.created_at;
end;
$$;

revoke all on function public.fn_notification_event_refresh(uuid) from public, anon;
grant execute on function public.fn_notification_event_refresh(uuid)
  to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 7. Push (pg_net → push-notify). Asíncrono: sale al hacer COMMIT.
-- ---------------------------------------------------------------------------
create or replace function private.fn_notif_call_push(p_body jsonb)
returns void
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_url text;
  v_key text;
begin
  select c.functions_base_url, c.service_role_key
    into v_url, v_key
  from private.dashboard_cron_config c
  where c.id = true;
  if v_url is null or v_key is null then
    raise warning 'fn_notif_call_push: private.dashboard_cron_config sin configurar; sin push.';
    return;
  end if;

  -- push-notify espera unos segundos a que llegue el motivo antes de
  -- responder; el timeout por defecto de pg_net (5 s) no alcanza.
  perform net.http_post(
    url := rtrim(v_url, '/') || '/push-notify',
    body := p_body,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || v_key
    ),
    timeout_milliseconds := 60000
  );
end;
$$;

create or replace function public.fn_notif_event_push()
returns trigger
language plpgsql
security definer
set search_path = public, private
as $$
begin
  begin
    perform private.fn_notif_call_push(
      jsonb_build_object('kind', 'notification_event', 'event_id', new.id));
  exception when others then
    raise warning 'fn_notif_event_push: % (%)', sqlerrm, sqlstate;
  end;
  return null;
end;
$$;

drop trigger if exists trg_notification_events_push on public.notification_events;
create trigger trg_notification_events_push
  after insert on public.notification_events
  for each row
  execute function public.fn_notif_event_push();

-- Respaldo: si la llamada inmediata se perdió (función reiniciando, red,
-- timeout), el cron le pide a push-notify que mande los avisos de más de
-- 1 minuto que siguen sin pushed_at (hasta 2 h atrás).
create or replace function private.fn_run_notification_event_sweep()
returns void
language plpgsql
security definer
set search_path = public, private
as $$
begin
  if not exists (
    select 1
    from public.notification_events e
    where e.pushed_at is null
      and e.created_at < now() - interval '1 minute'
      and e.created_at > now() - interval '2 hours'
  ) then
    return;
  end if;
  perform private.fn_notif_call_push(
    jsonb_build_object('kind', 'notification_event_sweep'));
end;
$$;

revoke all on function private.fn_notif_money(numeric) from public;
revoke all on function private.fn_notif_qty(numeric) from public;
revoke all on function private.fn_notif_person(uuid, uuid, uuid) from public;
revoke all on function private.fn_notif_place(uuid) from public;
revoke all on function private.fn_notif_void_note(text) from public;
revoke all on function private.fn_notif_text(text, uuid, uuid, jsonb, uuid[], uuid, timestamptz) from public;
revoke all on function private.fn_notif_is_rewrite() from public;
revoke all on function private.fn_notif_item_was_sent(jsonb) from public;
revoke all on function private.fn_notif_add_removed_items(uuid, uuid, jsonb, uuid) from public;
revoke all on function private.fn_notif_call_push(jsonb) from public;
revoke all on function private.fn_run_notification_event_sweep() from public;
revoke all on function public.fn_notif_on_items_deleted() from public, anon, authenticated;
revoke all on function public.fn_notif_on_item_reduced() from public, anon, authenticated;
revoke all on function public.fn_notif_on_order_void() from public, anon, authenticated;
revoke all on function public.fn_notif_on_payment_cancel() from public, anon, authenticated;
revoke all on function public.fn_notif_event_push() from public, anon, authenticated;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'notification_events_push_retry';
    perform cron.schedule(
      'notification_events_push_retry',
      '*/2 * * * *',
      $cron$select private.fn_run_notification_event_sweep()$cron$
    );
  else
    raise notice 'pg_cron no disponible. Agenda manual: select cron.schedule(''notification_events_push_retry'',''*/2 * * * *'',''select private.fn_run_notification_event_sweep()'');';
  end if;
exception when insufficient_privilege then
  raise notice 'Sin privilegio para pg_cron; agendar manualmente fn_run_notification_event_sweep.';
end $$;

-- ---------------------------------------------------------------------------
-- 8. Realtime + retiro del aviso viejo
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'notification_events'
  ) then
    alter publication supabase_realtime add table public.notification_events;
  end if;
end $$;

-- Un push por cada ítem en 'void' (creado a mano en producción, 2026-06).
-- Lo reemplazan los avisos de arriba. push_cash_session_close NO se toca.
drop trigger if exists push_order_item_void on public.order_items;

do $$
begin
  if to_regclass('private.dashboard_cron_config') is null
     or not exists (select 1 from private.dashboard_cron_config where id = true) then
    raise warning 'private.dashboard_cron_config sin configurar: los avisos se verán en la app pero NO saldrá push. Ver README de push-notify, sección 6.';
  end if;
end $$;

commit;

-- Verificación (correr aparte):
--   select tgname, tgrelid::regclass from pg_trigger
--    where tgname like 'trg_zz_notif_%' or tgname in
--          ('trg_notification_events_push', 'push_order_item_void');
--   select jobname, schedule from cron.job where jobname = 'notification_events_push_retry';
--   select * from public.notification_events order by created_at desc limit 20;
