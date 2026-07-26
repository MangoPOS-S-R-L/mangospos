-- =============================================================================
-- ROLLBACK de 20260725_0003 — quita el trigger de anulación y restaura el
-- trigger de creación a la versión 20260714_0002 (sin payment_id).
-- Las columnas payment_id/cancelled_by/cancelled_at se conservan (son datos;
-- eliminarlas descartaría auditoría). Descomenta los ALTER si de verdad
-- quieres eliminarlas.
-- =============================================================================

begin;

drop trigger if exists trg_payment_cancel_customer_credit on public.payments;
drop function if exists public.fn_payment_cancel_customer_credit();

create or replace function public.fn_payment_create_customer_credit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_method_code text;
  v_customer record;
  v_amount numeric;
  v_open_balance numeric;
  v_due date;
begin
  if new.status <> 'completed' then
    return new;
  end if;

  select pm.code into v_method_code
  from public.payment_methods pm
  where pm.id = new.payment_method_id;

  if coalesce(v_method_code, '') <> 'credit' then
    return new;
  end if;

  v_amount := coalesce(new.amount, 0) - coalesce(new.change_amount, 0);
  if v_amount <= 0 then
    return new;
  end if;

  if new.customer_id is null then
    raise exception 'CREDIT_CUSTOMER_REQUIRED';
  end if;

  select c.id, c.credit_enabled, c.credit_limit, c.credit_days
    into v_customer
  from public.customers c
  where c.id = new.customer_id
    and c.business_id = new.business_id;

  if v_customer.id is null then
    raise exception 'CREDIT_CUSTOMER_NOT_FOUND';
  end if;
  if not coalesce(v_customer.credit_enabled, false) then
    raise exception 'CREDIT_NOT_ENABLED_FOR_CUSTOMER';
  end if;

  if coalesce(v_customer.credit_limit, 0) > 0 then
    select coalesce(sum(cc.balance), 0)
      into v_open_balance
    from public.customer_credits cc
    where cc.customer_id = new.customer_id
      and cc.business_id = new.business_id
      and cc.status in ('pending','partial','overdue');

    if v_open_balance + v_amount > v_customer.credit_limit then
      raise exception 'CREDIT_LIMIT_EXCEEDED: deuda % + venta % supera límite %',
        round(v_open_balance, 2), round(v_amount, 2), round(v_customer.credit_limit, 2);
    end if;
  end if;

  if coalesce(v_customer.credit_days, 0) > 0 then
    v_due := (new.created_at at time zone 'America/Santo_Domingo')::date
             + v_customer.credit_days;
  end if;

  insert into public.customer_credits(
    business_id, customer_id, order_id, fiscal_document_id,
    original_amount, balance, due_date, status, notes, created_by, created_at
  )
  values (
    new.business_id, new.customer_id, new.order_id, new.fiscal_document_id,
    round(v_amount, 2), round(v_amount, 2), v_due, 'pending',
    'Venta a crédito', new.processed_by, new.created_at
  );

  return new;
end;
$$;

-- alter table public.customer_credits drop column if exists payment_id;
-- alter table public.customer_credits drop column if exists cancelled_by;
-- alter table public.customer_credits drop column if exists cancelled_at;

commit;
