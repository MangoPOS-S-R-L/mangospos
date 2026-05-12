-- =============================================================================
-- Migration 2/3 del refactor de fiscal documents (2026-05-13).
--
-- CAMBIO PRINCIPAL: el NCF se emite cuando se cierra el "contenedor"
-- (sub-cuenta o orden), no por cada payment. Esto resuelve el bug
-- estructural donde split por métodos solo genera UN fd asociado al primer
-- payment, dejando los demás huérfanos.
--
-- INVARIANTES POST-MIGRATION:
--   1. Una sub-cuenta cobrada (is_closed = true) tiene exactamente 1 fd
--      activo. Total = SUM(payments del check).
--   2. Una orden cobrada sin sub-cuentas tiene exactamente 1 fd activo.
--      Total = SUM(payments con check_id IS NULL).
--   3. Una orden con sub-cuentas: 1 fd por sub-cuenta cerrada, ninguno
--      a nivel orden.
--   4. Cada payment tiene un fiscal_document_id apuntando al fd de su
--      scope (check o orden).
--   5. Idempotencia: re-disparar el trigger no crea fd duplicados.
--
-- COMPATIBILIDAD:
--   - Órdenes ya cerradas con fd existente (incluyendo las "rotas" del
--     bug previo) quedan intactas. La función NUEVA detecta fd activo
--     pre-existente y no emite uno nuevo. Esto evita duplicados en
--     migration y respeta NCFs ya enviados a DGII (inmutables).
--   - Las 80 órdenes abiertas: cuando cierren, emitirán fd según la
--     nueva lógica.
--   - `tg_alanube_enqueue_emission` AFTER INSERT en fiscal_documents
--     sigue funcionando intacto (encola cada nuevo fd para emitir a
--     DGII via Alanube).
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1) ALTER fiscal_documents: agregar columna check_id para distinguir
--    fds de check vs fds de orden full. Necesario para idempotencia
--    correcta (sin esto no podemos saber si un fd existente es para el
--    scope que queremos emitir).
-- ---------------------------------------------------------------------------

alter table public.fiscal_documents
  add column if not exists check_id uuid references public.order_checks(id) on delete set null;

comment on column public.fiscal_documents.check_id is
  'Cuando es NOT NULL, este fd corresponde a una sub-cuenta específica '
  '(split bill). Cuando es NULL, el fd es de la orden completa '
  '(full-order o cobro único). Usado para idempotencia: una sub-cuenta '
  'o una orden no pueden tener más de un fd active.';

-- Backfill: para fds existentes, derivar check_id desde el payment
-- asociado. Si el primer payment del fd tenía check_id, ese es el scope.
update public.fiscal_documents fd
set check_id = sub.check_id
from (
  select fd2.id as fd_id, p.check_id
  from public.fiscal_documents fd2
  join public.payments p on p.id = fd2.payment_id
  where p.check_id is not null
) sub
where fd.id = sub.fd_id
  and fd.check_id is null;

-- Unique index parcial: para fds 'active', no puede haber 2 con el mismo
-- (order_id, check_id). Esto bloquea físicamente el duplicado a nivel BD.
create unique index if not exists idx_fd_unique_active_per_scope
  on public.fiscal_documents (order_id, coalesce(check_id, '00000000-0000-0000-0000-000000000000'::uuid))
  where status = 'active';

-- ---------------------------------------------------------------------------
-- 2) Reescribir create_fiscal_document(p_order_id, p_check_id) con el
--    nuevo modelo de "1 fd por contenedor".
--
--    Cambios respecto a la versión anterior:
--      - Recibe explícitamente el scope (check_id puede ser NULL).
--      - Calcula el total como SUM(payments del scope completados).
--      - Asocia TODOS los payments del scope al fd creado.
--      - Idempotencia: si ya hay fd active para ese scope, retorna sin
--        crear duplicado (y asocia payments huérfanos al fd existente
--        para que el listado del historial sea correcto).
-- ---------------------------------------------------------------------------

drop function if exists public.create_fiscal_document(uuid, uuid, uuid, text);

create or replace function public.create_fiscal_document(
  p_order_id uuid,
  p_check_id uuid default null
)
returns public.fiscal_documents
language plpgsql
security definer
set search_path = public
as $$
declare
  v_doc public.fiscal_documents;
  v_doc_id uuid;
  v_existing_payment_id uuid;
begin
  -- Idempotencia: si ya existe fd activo para este (order_id, check_id),
  -- retornarlo. Esto cubre:
  --   - Re-trigger accidental (mismo cierre disparado dos veces).
  --   - Órdenes pre-refactor con fd "huérfano" del bug viejo.
  select * into v_doc
  from public.fiscal_documents fd
  where fd.order_id = p_order_id
    and fd.check_id is not distinct from p_check_id
    and fd.status = 'active'
  order by fd.created_at desc
  limit 1;

  if found then
    -- Asegurar que TODOS los payments del scope quedan apuntando al fd.
    -- Esto repara los payments huérfanos del bug anterior si los hay.
    update public.payments p
    set fiscal_document_id = v_doc.id
    where p.order_id = p_order_id
      and p.status = 'completed'
      and p.check_id is not distinct from p_check_id
      and (p.fiscal_document_id is null or p.fiscal_document_id <> v_doc.id);
    return v_doc;
  end if;

  -- Necesitamos un payment_id "representativo" para asociar al fd via
  -- la columna payment_id (FK existente). Usamos el primer payment
  -- completado del scope.
  select p.id into v_existing_payment_id
  from public.payments p
  where p.order_id = p_order_id
    and p.status = 'completed'
    and p.check_id is not distinct from p_check_id
  order by p.created_at asc
  limit 1;

  if v_existing_payment_id is null then
    -- No hay payments para este scope; no emitir fd vacío.
    raise exception 'NO_PAYMENTS_FOR_SCOPE: order=% check=%', p_order_id, p_check_id;
  end if;

  -- Delegar la creación física del fd a issue_fiscal_document, que ya
  -- maneja generate_ncf, customer resolution, business_id, etc.
  -- Nota: issue_fiscal_document calcula el desglose con el TOTAL real
  -- del payment representativo. Después de crear, sobrescribimos el
  -- total con la SUMA de todos los payments del scope.
  v_doc_id := public.issue_fiscal_document(p_order_id, v_existing_payment_id);

  -- Recalcular total y desglose con la SUMA del scope.
  perform public.fn_recompute_fd_for_scope(v_doc_id, p_order_id, p_check_id);

  -- Asociar TODOS los payments del scope al fd recién creado.
  update public.payments p
  set fiscal_document_id = v_doc_id
  where p.order_id = p_order_id
    and p.status = 'completed'
    and p.check_id is not distinct from p_check_id;

  -- Setear check_id en el fd (issue_fiscal_document no lo conoce).
  update public.fiscal_documents
  set check_id = p_check_id
  where id = v_doc_id;

  select * into v_doc from public.fiscal_documents where id = v_doc_id;
  return v_doc;
end;
$$;

grant execute on function public.create_fiscal_document(uuid, uuid)
  to authenticated, service_role;

comment on function public.create_fiscal_document(uuid, uuid) is
  'Emite 1 fd para un contenedor (sub-cuenta si p_check_id NOT NULL, '
  'orden completa si NULL). Total = SUM(payments del scope). Asocia '
  'todos los payments del scope al fd. Idempotente: si ya existe fd '
  'active para el scope, retorna ese.';

-- ---------------------------------------------------------------------------
-- 3) fn_recompute_fd_for_scope: ajusta el fd (recién creado por
--    issue_fiscal_document con el monto de UN payment) al total y
--    desglose del scope completo.
-- ---------------------------------------------------------------------------

create or replace function public.fn_recompute_fd_for_scope(
  p_fd_id uuid,
  p_order_id uuid,
  p_check_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_scope_total numeric(12,2);
  v_base_subtotal numeric(12,2);
  v_base_tax numeric(12,2);
  v_base_service_fee numeric(12,2);
  v_base_total numeric(12,2);
  v_ratio numeric(12,8);
  v_subtotal numeric(12,2);
  v_itbis numeric(12,2);
  v_service_fee numeric(12,2);
  v_sum numeric(12,2);
  v_residual numeric(12,2);
begin
  -- Suma de payments del scope NETO de cambio (lo que efectivamente entró
  -- a la caja, no lo que el cliente entregó). Si el cliente paga 600 en
  -- cash sobre un total de 500, el cajero devuelve 100 de cambio y el
  -- monto fiscal real cobrado es 500.
  select coalesce(sum(p.amount - coalesce(p.change_amount, 0)), 0)
    into v_scope_total
  from public.payments p
  where p.order_id = p_order_id
    and p.status = 'completed'
    and p.check_id is not distinct from p_check_id;

  if v_scope_total <= 0 then
    return;
  end if;

  -- Base para prorrateo: totales del check o de la orden.
  if p_check_id is not null then
    select coalesce(oc.subtotal, 0),
           coalesce(oc.tax, 0),
           coalesce(oc.service_fee, 0),
           coalesce(oc.total, 0)
      into v_base_subtotal, v_base_tax, v_base_service_fee, v_base_total
    from public.order_checks oc
    where oc.id = p_check_id;
  else
    select coalesce(o.subtotal, 0),
           coalesce(o.tax, 0),
           coalesce(o.service_fee, 0),
           coalesce(o.total, 0)
      into v_base_subtotal, v_base_tax, v_base_service_fee, v_base_total
    from public.orders o
    where o.id = p_order_id;
  end if;

  if v_base_total > 0 then
    v_ratio := v_scope_total / v_base_total;
    v_subtotal := round(v_base_subtotal * v_ratio, 2);
    v_itbis := round(v_base_tax * v_ratio, 2);
    v_service_fee := round(v_base_service_fee * v_ratio, 2);
  else
    v_subtotal := v_scope_total;
    v_itbis := 0;
    v_service_fee := 0;
  end if;

  -- Ajuste residual: la suma debe cuadrar exactamente con v_scope_total.
  v_sum := v_subtotal + v_itbis + v_service_fee;
  v_residual := v_scope_total - v_sum;
  if abs(v_residual) > 0 and abs(v_residual) < 1 then
    v_subtotal := v_subtotal + v_residual;
  end if;

  update public.fiscal_documents
  set subtotal = v_subtotal,
      taxable_amount = v_subtotal,
      itbis_amount = v_itbis,
      service_fee = v_service_fee,
      total = v_scope_total
  where id = p_fd_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4) Reemplazar triggers: eliminar trg_issue_fiscal (sobre payments) y
--    crear trg_issue_fd_on_check_close + trg_issue_fd_on_order_close.
-- ---------------------------------------------------------------------------

drop trigger if exists trg_issue_fiscal on public.payments;

create or replace function public.trg_fn_issue_fd_on_check_close()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- Solo cuando una sub-cuenta (position > 1) pasa de abierta a cerrada.
  -- El principal (position=1) no genera fd por sí mismo; ese caso lo
  -- maneja el trigger de orders.
  if new.is_closed = true
     and (old.is_closed is null or old.is_closed = false)
     and new.position > 1 then
    -- Solo emitir si hay al menos 1 payment completed para este check.
    if exists (
      select 1 from public.payments
      where check_id = new.id and status = 'completed'
    ) then
      perform public.create_fiscal_document(new.order_id, new.id);
    end if;
  end if;
  return new;
end;
$$;

create trigger trg_issue_fd_on_check_close
after update of is_closed on public.order_checks
for each row execute function public.trg_fn_issue_fd_on_check_close();

create or replace function public.trg_fn_issue_fd_on_order_close()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_has_subchecks boolean;
begin
  -- Solo cuando una orden pasa de abierta a cerrada.
  if new.closed_at is not null
     and old.closed_at is null then

    -- Si la orden tiene sub-cuentas (position > 1), los fds ya fueron
    -- emitidos por trg_issue_fd_on_check_close cuando esas se cerraron.
    -- Skip a nivel orden para no duplicar.
    select exists (
      select 1 from public.order_checks
      where order_id = new.id and position > 1
    ) into v_has_subchecks;

    if not v_has_subchecks then
      -- Full-order: emitir fd con check_id NULL.
      if exists (
        select 1 from public.payments
        where order_id = new.id and check_id is null and status = 'completed'
      ) then
        perform public.create_fiscal_document(new.id, null);
      end if;
    end if;
  end if;
  return new;
end;
$$;

create trigger trg_issue_fd_on_order_close
after update of closed_at on public.orders
for each row execute function public.trg_fn_issue_fd_on_order_close();

-- ---------------------------------------------------------------------------
-- 5) Compatibilidad: dejar trigger_issue_fiscal_on_payment como no-op para
--    no romper código histórico que pueda referenciarla. La función queda
--    pero ya no tiene trigger asociado.
-- ---------------------------------------------------------------------------

create or replace function public.trigger_issue_fiscal_on_payment()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- DEPRECATED 2026-05-13: el fd ahora se emite al cerrar check u orden,
  -- no al insertar payment. Este trigger queda como no-op para evitar
  -- emisiones duplicadas si alguna migration futura intenta reactivarlo.
  return new;
end;
$$;

commit;
