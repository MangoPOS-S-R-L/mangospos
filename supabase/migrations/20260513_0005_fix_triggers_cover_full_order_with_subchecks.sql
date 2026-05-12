-- =============================================================================
-- Fix de los triggers de cierre para casos mixtos (sub-cuentas + cobro
-- full-order pendiente).
--
-- Bugs confirmados (2026-05-13) en datos reales (orden 9916d5ae):
--
--   A. trg_issue_fd_on_order_close skipea si la orden tiene CUALQUIER
--      sub-check (incluso si esos sub-checks ya cerraron con fd propio).
--      Cuando el cajero hace "Pagar todo lo pendiente" sobre una orden
--      con sub-cuentas (caso: 2 sub-cuentas ya cobradas + un payment
--      full-order para liquidar lo que quedaba), el payment con
--      check_id=NULL no genera fd.
--
--   B. trg_issue_fd_on_check_close emite fd solo si hay payments con
--      check_id apuntando a ese check. Pero un sub-check puede cerrarse
--      por trg_auto_close_empty_subcheck (cuando todos sus items pasan
--      a 'paid' via un cobro full-order). En ese caso no hay payments
--      directos del check, pero hay payments full-order que cubren
--      esos items. El fd para esos items va emitido a nivel orden por
--      el trigger order_close, no por check_close.
--
-- Fix:
--   1. trg_fn_issue_fd_on_order_close: deja de skipear por sub-checks.
--      Emite fd siempre que existan payments con check_id=NULL completed
--      sin fiscal_document_id asociado. Si la orden no tiene payments
--      full-order, no emite nada (los checks ya emitieron sus fds).
--
--   2. trg_fn_issue_fd_on_check_close: agrega guard adicional. Solo
--      emite si el check tiene payments DIRECTOS (con check_id=check.id).
--      Si el check se cerró sin payments propios (vía trg_auto_close
--      cuando sus items pasaron a paid por cobro full-order), no emite
--      — esos items quedan cubiertos por el fd full-order.
--      Este comportamiento ya estaba pero lo dejamos explícito y robusto.
--
-- Impacto:
--   - Cobro simple full-order (sin sub-checks): igual que antes, 1 fd.
--   - Cobro por sub-cuenta individual: igual que antes, 1 fd por check.
--   - Cobro full-order con sub-checks pendientes (caso fallido): emite
--     1 fd a nivel orden con SUM(payments con check_id=NULL). FIX.
--   - Cobro mixto (algunas sub-cuentas cobradas + remainder full-order):
--     N fds por sub-cuentas cobradas + 1 fd a nivel orden por el
--     remainder full-order. FIX.
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1) Reescribir trg_fn_issue_fd_on_order_close
-- ---------------------------------------------------------------------------

create or replace function public.trg_fn_issue_fd_on_order_close()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- Solo cuando una orden pasa de abierta a cerrada.
  if new.closed_at is not null
     and old.closed_at is null then

    -- Emitir fd para los payments full-order (check_id IS NULL) si los
    -- hay. Esto cubre 3 casos:
    --   * Orden simple sin sub-cuentas: 1 payment full-order → 1 fd.
    --   * Orden full-order con split methods: N payments full-order →
    --     1 fd con SUM (Migration 0002 ya lo arregló).
    --   * Orden con sub-cuentas ya cobradas + remainder full-order:
    --     los sub-checks ya emitieron sus fds; este emite el fd para
    --     el remainder full-order. FIX del bug A.
    --
    -- create_fiscal_document tiene idempotencia por (order_id, check_id)
    -- — si por alguna razón ya hay fd con check_id=NULL para esta orden,
    -- retorna ese sin duplicar.
    if exists (
      select 1 from public.payments
      where order_id = new.id
        and check_id is null
        and status = 'completed'
    ) then
      perform public.create_fiscal_document(new.id, null);
    end if;
  end if;
  return new;
end;
$$;

comment on function public.trg_fn_issue_fd_on_order_close() is
  'Emite fd para los payments full-order (check_id=NULL) cuando la orden '
  'se cierra. Si la orden tiene sub-cuentas con sus propios fds, este '
  'trigger NO los duplica — solo emite el fd del remainder full-order '
  'si lo hay. Idempotente vía create_fiscal_document.';

-- ---------------------------------------------------------------------------
-- 2) Reescribir trg_fn_issue_fd_on_check_close
-- ---------------------------------------------------------------------------

create or replace function public.trg_fn_issue_fd_on_check_close()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- Solo cuando una sub-cuenta (position > 1) pasa de abierta a cerrada.
  if new.is_closed = true
     and (old.is_closed is null or old.is_closed = false)
     and new.position > 1 then

    -- Solo emitir fd si el check tiene payments DIRECTOS (check_id=check.id).
    -- Si el check se cerró por trg_auto_close_empty_subcheck (sus items
    -- pasaron a 'paid' por un cobro full-order), no hay payments propios
    -- — esos items quedan cubiertos por el fd full-order que emitirá
    -- trg_issue_fd_on_order_close cuando la orden cierre.
    if exists (
      select 1 from public.payments
      where check_id = new.id
        and status = 'completed'
    ) then
      perform public.create_fiscal_document(new.order_id, new.id);
    end if;
  end if;
  return new;
end;
$$;

comment on function public.trg_fn_issue_fd_on_check_close() is
  'Emite fd para una sub-cuenta cobrada con payment directo al check. '
  'Si el check se cerró sin payment propio (auto-close por items paid '
  'via cobro full-order), no emite — el fd full-order de la orden '
  'cubre esos items.';

-- ---------------------------------------------------------------------------
-- 3) Reparar la orden 9916d5ae (la del reporte): emitir fd retroactivo
--    para el payment con check_id=NULL.
--
-- Esto es seguro: create_fiscal_document es idempotente. Si ya hay fd para
-- (orden, NULL) lo retorna; si no, crea uno nuevo. Para esta orden no hay
-- fd full-order todavía, así que crea uno con SUM(payments check_id=NULL).
-- ---------------------------------------------------------------------------

do $$
declare
  v_fd public.fiscal_documents;
begin
  -- Solo si la orden tiene payments full-order huérfanos.
  if exists (
    select 1 from public.payments
    where order_id = '9916d5ae-9e90-47d1-8959-67d4c07355fa'::uuid
      and check_id is null
      and status = 'completed'
      and fiscal_document_id is null
  ) then
    v_fd := public.create_fiscal_document(
      '9916d5ae-9e90-47d1-8959-67d4c07355fa'::uuid,
      null
    );
    raise notice 'Reparada orden 9916d5ae: fd id=%, total=%, ncf=%',
      v_fd.id, v_fd.total, v_fd.ncf_number;
  else
    raise notice 'Orden 9916d5ae: nada que reparar (no hay payments full-order huerfanos)';
  end if;
exception
  when others then
    raise notice 'No se pudo reparar 9916d5ae: % (SQLSTATE %)', SQLERRM, SQLSTATE;
end$$;

commit;
