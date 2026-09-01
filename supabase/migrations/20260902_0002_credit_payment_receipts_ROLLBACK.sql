-- Rollback de 20260902_0002.
--
-- OJO: `credit_payments.code` NO se borra. Son números de recibo que ya se
-- imprimieron y se le entregaron al cliente; tirar la columna deja papeles
-- en la calle sin respaldo en la base. Si de verdad hay que eliminarla, va
-- a mano y con la decisión tomada por escrito (ver el final del archivo).

begin;

drop function if exists public.fn_cash_session_credit_payments(uuid);

-- La v1 vuelve a ser el motor, tal como estaba en 20260714_0002.
create or replace function public.fn_register_credit_abono(
  p_credit_id uuid,
  p_amount numeric,
  p_payment_method_code text default 'cash',
  p_reference text default null,
  p_session_id uuid default null
)
returns public.customer_credits
language plpgsql
security definer
set search_path = public
as $$
declare
  v_credit public.customer_credits;
  v_method_id uuid;
  v_method_code text;
begin
  if p_amount is null or p_amount <= 0 then
    raise exception 'ABONO_AMOUNT_INVALID';
  end if;

  select * into v_credit
  from public.customer_credits
  where id = p_credit_id
  for update;

  if v_credit.id is null then
    raise exception 'CREDIT_NOT_FOUND';
  end if;
  if not public.user_has_business_access(auth.uid(), v_credit.business_id) then
    raise exception 'ACCESS_DENIED';
  end if;
  if v_credit.status in ('paid','cancelled') then
    raise exception 'CREDIT_ALREADY_CLOSED';
  end if;
  if p_amount > v_credit.balance + 0.01 then
    raise exception 'ABONO_EXCEEDS_BALANCE: abono % > saldo %',
      round(p_amount, 2), round(v_credit.balance, 2);
  end if;

  v_method_code := lower(coalesce(nullif(trim(p_payment_method_code), ''), 'cash'));

  select pm.id into v_method_id
  from public.payment_methods pm
  where pm.business_id = v_credit.business_id
    and pm.code = v_method_code
  limit 1;

  if v_method_code = 'cash' then
    if p_session_id is null then
      raise exception 'CASH_SESSION_REQUIRED';
    end if;
    if not exists (
      select 1 from public.cash_register_sessions cs
      where cs.id = p_session_id
        and cs.status = 'open'
        and cs.closed_at is null
    ) then
      raise exception 'CASH_SESSION_NOT_OPEN';
    end if;

    insert into public.cash_transactions(session_id, amount, type, description, related_order_id)
    values (
      p_session_id, round(least(p_amount, v_credit.balance), 2), 'deposit',
      'Abono crédito CxC ' || left(v_credit.id::text, 8), v_credit.order_id
    );
  end if;

  insert into public.credit_payments(credit_id, amount, payment_method_id, reference, received_by, session_id)
  values (v_credit.id, round(least(p_amount, v_credit.balance), 2), v_method_id,
          nullif(trim(coalesce(p_reference, '')), ''), auth.uid(), p_session_id);

  update public.customer_credits
     set balance = greatest(round(balance - p_amount, 2), 0),
         status  = case when round(balance - p_amount, 2) <= 0 then 'paid' else 'partial' end
   where id = v_credit.id
   returning * into v_credit;

  return v_credit;
end;
$$;

drop function if exists public.fn_register_credit_abono_v2(uuid, numeric, text, text, uuid);

delete from public.permissions where code = 'creditos.reimprimir';

commit;

-- Solo si se decidió a mano borrar los números de recibo ya emitidos:
--
--   begin;
--   drop index if exists public.uq_credit_payments_business_code;
--   drop index if exists public.idx_credit_payments_business_created;
--   alter table public.credit_payments
--     drop column if exists code,
--     drop column if exists business_id;
--   commit;
