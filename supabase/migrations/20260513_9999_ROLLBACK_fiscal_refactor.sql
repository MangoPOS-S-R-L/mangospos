-- =============================================================================
-- ROLLBACK DE EMERGENCIA del refactor de fiscal documents (2026-05-13).
--
-- USAR SOLO SI las migrations 0001/0002/0003 fallan o producen resultados
-- inesperados. Restaura las funciones y triggers al estado pre-refactor.
--
-- IMPORTANTE:
--   - Este rollback REVIERTE la lógica pero NO destruye fds o payments
--     emitidos bajo la nueva lógica. Esos quedan en la BD (porque NCFs
--     ya emitidos a DGII son inmutables).
--   - Después del rollback, el flujo vuelve a "fd por payment con bug de
--     idempotencia por order_id". Es lo que tenías antes — no resuelve
--     el bug, pero al menos vuelve a un estado conocido.
--   - La columna `fiscal_documents.check_id` queda en la tabla (no se
--     dropea para evitar perder data si hubo fds nuevos). No afecta
--     el flujo legacy.
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1) Eliminar triggers nuevos
-- ---------------------------------------------------------------------------

drop trigger if exists trg_issue_fd_on_check_close on public.order_checks;
drop trigger if exists trg_issue_fd_on_order_close on public.orders;

drop function if exists public.trg_fn_issue_fd_on_check_close();
drop function if exists public.trg_fn_issue_fd_on_order_close();
drop function if exists public.fn_recompute_fd_for_scope(uuid, uuid, uuid);

-- ---------------------------------------------------------------------------
-- 2) Eliminar unique index nuevo (puede bloquear inserts legacy)
-- ---------------------------------------------------------------------------

drop index if exists public.idx_fd_unique_active_per_scope;

-- ---------------------------------------------------------------------------
-- 3) Restaurar create_fiscal_document con la firma vieja (4 params)
--    Esta es la versión que estaba corriendo pre-refactor (con el bug
--    de idempotencia, pero es el estado conocido).
-- ---------------------------------------------------------------------------

drop function if exists public.create_fiscal_document(uuid, uuid);

create or replace function public.create_fiscal_document(
  p_order_id uuid,
  p_payment_id uuid,
  p_customer_id uuid,
  p_customer_rnc text
)
returns public.fiscal_documents
language plpgsql
security definer
set search_path = public
as $$
declare
  v_doc public.fiscal_documents;
  v_doc_id uuid;
begin
  -- Idempotencia legacy (la del bug por order_id).
  select *
    into v_doc
  from public.fiscal_documents fd
  where (p_payment_id is not null and fd.payment_id = p_payment_id)
     or (fd.order_id = p_order_id and fd.status = 'active')
  order by fd.created_at desc
  limit 1;

  if found then
    return v_doc;
  end if;

  v_doc_id := public.issue_fiscal_document(p_order_id, p_payment_id);

  select *
    into v_doc
  from public.fiscal_documents
  where id = v_doc_id;

  if p_customer_id is not null or p_customer_rnc is not null then
    update public.fiscal_documents
       set customer_id = coalesce(customer_id, p_customer_id),
           customer_rnc = coalesce(customer_rnc, p_customer_rnc)
     where id = v_doc_id
     returning * into v_doc;
  end if;

  return v_doc;
end;
$$;

grant execute on function public.create_fiscal_document(uuid, uuid, uuid, text)
  to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4) Restaurar trigger sobre payments
-- ---------------------------------------------------------------------------

create or replace function public.trigger_issue_fiscal_on_payment()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.status = 'completed' then
    perform public.create_fiscal_document(
      new.order_id,
      new.id,
      null,
      null
    );
  end if;
  return new;
end;
$$;

create trigger trg_issue_fiscal
after insert on public.payments
for each row execute function public.trigger_issue_fiscal_on_payment();

-- ---------------------------------------------------------------------------
-- 5) Reporte de estado
-- ---------------------------------------------------------------------------

do $$
declare
  v_trg_legacy int;
  v_trg_new_check int;
  v_trg_new_order int;
begin
  select count(*) into v_trg_legacy
  from pg_trigger
  where tgrelid = 'public.payments'::regclass and tgname = 'trg_issue_fiscal';

  select count(*) into v_trg_new_check
  from pg_trigger
  where tgrelid = 'public.order_checks'::regclass and tgname = 'trg_issue_fd_on_check_close';

  select count(*) into v_trg_new_order
  from pg_trigger
  where tgrelid = 'public.orders'::regclass and tgname = 'trg_issue_fd_on_order_close';

  raise notice '=== ROLLBACK ESTADO ===';
  raise notice 'Trigger legacy trg_issue_fiscal: % (esperado 1)', v_trg_legacy;
  raise notice 'Trigger nuevo check_close: % (esperado 0)', v_trg_new_check;
  raise notice 'Trigger nuevo order_close: % (esperado 0)', v_trg_new_order;
  raise notice '======================';

  if v_trg_legacy <> 1 or v_trg_new_check <> 0 or v_trg_new_order <> 0 then
    raise exception 'ROLLBACK_INCOMPLETO: estado inconsistente, revisar triggers manualmente';
  end if;
end$$;

commit;
