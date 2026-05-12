-- =============================================================================
-- Migration 3/3 del refactor de fiscal documents (2026-05-13).
--
-- Verifica invariantes después del refactor de Migration 2. NO modifica
-- datos — solo reporta. Sirve como gate antes de considerar el refactor
-- "estable en producción".
--
-- Si alguna verificación arroja conteos inesperados, NO impide la
-- migration (no falla), pero loguea por RAISE NOTICE para que el
-- operador investigue.
--
-- INVARIANTES VERIFICADOS:
--   I1. No hay más de 1 fd active por (order_id, check_id). El unique
--       index parcial creado en Migration 2 lo refuerza físicamente.
--   I2. Toda orden cerrada sin sub-cuentas y con payments completed
--       tiene al menos 1 fd active.
--   I3. Toda sub-cuenta cerrada con payments completed tiene al menos
--       1 fd active.
--   I4. Triggers `trg_issue_fd_on_check_close` y
--       `trg_issue_fd_on_order_close` están instalados.
--   I5. El trigger viejo `trg_issue_fiscal` está eliminado.
--   I6. Payments huérfanos (status=completed, fiscal_document_id=NULL)
--       quedan reportados para auditoría manual.
-- =============================================================================

begin;

do $$
declare
  v_dup_active_scopes int;
  v_closed_orders_no_fd int;
  v_closed_checks_no_fd int;
  v_orphan_payments int;
  v_trg_check_close int;
  v_trg_order_close int;
  v_trg_legacy int;
begin
  -- I1: scopes con > 1 fd active
  select count(*) into v_dup_active_scopes
  from (
    select order_id,
           coalesce(check_id, '00000000-0000-0000-0000-000000000000'::uuid) as scope_key
    from public.fiscal_documents
    where status = 'active'
    group by 1, 2
    having count(*) > 1
  ) as d;

  -- I2: órdenes cerradas sin sub-cuentas, con payments completed, sin fd active
  select count(*) into v_closed_orders_no_fd
  from public.orders o
  where o.closed_at is not null
    and not exists (
      select 1 from public.order_checks oc
      where oc.order_id = o.id and oc.position > 1
    )
    and exists (
      select 1 from public.payments p
      where p.order_id = o.id and p.check_id is null and p.status = 'completed'
    )
    and not exists (
      select 1 from public.fiscal_documents fd
      where fd.order_id = o.id and fd.check_id is null and fd.status = 'active'
    );

  -- I3: sub-cuentas cerradas con payments completed, sin fd active
  select count(*) into v_closed_checks_no_fd
  from public.order_checks oc
  where oc.is_closed = true
    and oc.position > 1
    and exists (
      select 1 from public.payments p
      where p.check_id = oc.id and p.status = 'completed'
    )
    and not exists (
      select 1 from public.fiscal_documents fd
      where fd.check_id = oc.id and fd.status = 'active'
    );

  -- I4 & I5: triggers
  select count(*) into v_trg_check_close
  from pg_trigger
  where tgrelid = 'public.order_checks'::regclass
    and tgname = 'trg_issue_fd_on_check_close';

  select count(*) into v_trg_order_close
  from pg_trigger
  where tgrelid = 'public.orders'::regclass
    and tgname = 'trg_issue_fd_on_order_close';

  select count(*) into v_trg_legacy
  from pg_trigger
  where tgrelid = 'public.payments'::regclass
    and tgname = 'trg_issue_fiscal';

  -- I6: payments huérfanos (status=completed, fd_id=NULL)
  select count(*) into v_orphan_payments
  from public.payments
  where status = 'completed' and fiscal_document_id is null;

  -- Reporte
  raise notice '=== VERIFICACION POST-REFACTOR FISCAL (Migration 0003) ===';
  raise notice 'I1 duplicados (scopes con >1 fd active): % (esperado 0)', v_dup_active_scopes;
  raise notice 'I2 ordenes full cerradas sin fd: % (revisar manualmente si > 0, son legacy)', v_closed_orders_no_fd;
  raise notice 'I3 sub-cuentas cerradas sin fd: % (revisar manualmente si > 0)', v_closed_checks_no_fd;
  raise notice 'I4 trigger check_close instalado: % (esperado 1)', v_trg_check_close;
  raise notice 'I5 trigger order_close instalado: % (esperado 1)', v_trg_order_close;
  raise notice 'I6 trigger legacy trg_issue_fiscal: % (esperado 0)', v_trg_legacy;
  raise notice 'I7 payments huerfanos (status=completed sin fd_id): % (legacy del bug)', v_orphan_payments;
  raise notice '=========================================================';

  -- Hard fail solo si los triggers no quedaron correctamente instalados.
  if v_trg_check_close <> 1 then
    raise exception 'TRIGGER_CHECK_CLOSE_MISSING: migration 0002 no instaló trg_issue_fd_on_check_close';
  end if;
  if v_trg_order_close <> 1 then
    raise exception 'TRIGGER_ORDER_CLOSE_MISSING: migration 0002 no instaló trg_issue_fd_on_order_close';
  end if;
  if v_trg_legacy <> 0 then
    raise exception 'TRIGGER_LEGACY_STILL_ACTIVE: trg_issue_fiscal no fue eliminado, riesgo de fd duplicados';
  end if;
end$$;

commit;
