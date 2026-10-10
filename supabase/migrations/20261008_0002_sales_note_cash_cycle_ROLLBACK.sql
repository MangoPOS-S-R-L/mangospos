-- Revierte la política nueva sin borrar notas, facturas, cuota ni contador.
-- Restaura los emisores vivos guardados por la migración y los triggers
-- anteriores de 20260910_0001_sales_notes. Revertir también la app que depende
-- de esta política. No ejecutar junto a la migración de avance.
begin;

drop trigger if exists trg_guard_sales_note_policy on public.sales_notes;
drop trigger if exists trg_guard_invoice_sale_document on public.fiscal_documents;
drop trigger if exists trg_account_sales_note_cycle on public.sales_notes;
drop trigger if exists trg_account_sales_note_cycle on public.fiscal_documents;
drop trigger if exists trg_guard_sales_note_counter on public.business_settings;
drop trigger if exists trg_guard_active_sale_document on public.sales_notes;
drop trigger if exists trg_guard_active_sale_document on public.fiscal_documents;

create or replace function public.trg_fn_issue_fd_on_check_close()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if new.is_closed = true
     and (old.is_closed is null or old.is_closed = false)
     and new.position > 1 then
    if exists (select 1 from public.payments
               where check_id = new.id and status = 'completed') then
      if coalesce(new.is_sales_note,
           (select o.is_sales_note from public.orders o where o.id = new.order_id), false) then
        perform public.fn_issue_sales_note(new.order_id, new.id);
        return new;
      end if;
      perform public.create_fiscal_document(new.order_id, new.id);
    end if;
  end if;
  return new;
end;
$$;

create or replace function public.trg_fn_issue_fd_on_order_close()
returns trigger language plpgsql security definer set search_path = public
as $$
declare v_has_subchecks boolean;
begin
  if new.closed_at is not null and old.closed_at is null then
    select exists (select 1 from public.order_checks
                   where order_id = new.id and position > 1) into v_has_subchecks;
    if not v_has_subchecks then
      if exists (select 1 from public.payments
                 where order_id = new.id and check_id is null and status = 'completed') then
        if coalesce(new.is_sales_note, false)
           or exists (select 1 from public.order_checks c
                      where c.order_id = new.id and c.is_sales_note = true) then
          perform public.fn_issue_sales_note(new.id, null);
          return new;
        end if;
        perform public.create_fiscal_document(new.id, null);
      end if;
    end if;
  end if;
  return new;
end;
$$;

drop function if exists public.fn_issue_sale_document(uuid, uuid, boolean);
drop function if exists public.fn_guard_sales_note_policy();
drop function if exists public.fn_guard_invoice_sale_document();
drop function if exists public.fn_account_sales_note_cycle();
drop function if exists public.fn_guard_sales_note_counter();
drop function if exists public.fn_guard_active_sale_document();
drop function if exists public.fn_apply_sales_note_invoice_cycle(uuid);

do $$
begin
  if to_regprocedure('public.fn_issue_sales_note_unchecked(uuid,uuid)') is not null then
    drop function public.fn_issue_sales_note(uuid, uuid);
    alter function public.fn_issue_sales_note_unchecked(uuid, uuid)
      rename to fn_issue_sales_note;
  end if;
  if to_regprocedure('public.issue_fiscal_document_unchecked(uuid,uuid)') is not null then
    drop function public.issue_fiscal_document(uuid, uuid);
    alter function public.issue_fiscal_document_unchecked(uuid, uuid)
      rename to issue_fiscal_document;
  end if;
  if to_regprocedure('public.create_fiscal_document_unchecked(uuid,uuid)') is not null then
    drop function public.create_fiscal_document(uuid, uuid);
    alter function public.create_fiscal_document_unchecked(uuid, uuid)
      rename to create_fiscal_document;
  end if;
end;
$$;

drop function if exists public.fn_sales_note_policy_scope(uuid, uuid);
grant execute on function public.fn_issue_sales_note(uuid, uuid) to authenticated, service_role;
grant execute on function public.issue_fiscal_document(uuid, uuid) to authenticated, service_role;
grant execute on function public.create_fiscal_document(uuid, uuid) to authenticated, service_role;

commit;
notify pgrst, 'reload schema';
