-- =============================================================================
-- 20260725_0003 — Integridad al cancelar/anular créditos (CxC).
--
-- PROBLEMA:
--   1. Anular el pago de una venta a crédito (annulPayment/annulOrder ponen
--      payments.status='cancelled') dejaba la cuenta por cobrar VIVA: el
--      cliente aparecía debiendo una venta que ya no existe.
--   2. `customer_credits` no guarda quién/cuándo canceló (solo status+notes)
--      y no tiene vínculo directo al payment que la originó (solo order_id +
--      fiscal_document_id).
--
-- FIX:
--   1. Columna `payment_id` en customer_credits + el trigger de creación la
--      llena; backfill best-effort para filas existentes.
--   2. Columnas `cancelled_by` / `cancelled_at` (auditoría).
--   3. Trigger en payments: al pasar un pago credit de completed →
--      cancelled/void, cancela su customer_credit vinculada. Si la cuenta ya
--      tiene ABONOS, BLOQUEA la anulación (raise) — hay dinero recibido que
--      devolver y eso debe resolverse manualmente primero.
--      SECURITY DEFINER: no depende del RLS del usuario que anula.
--
-- La app además pre-valida (mensaje amigable antes de tocar nada) y el
-- diálogo "Cancelar crédito" ahora exige razón y graba cancelled_by/at.
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Columnas nuevas
-- ---------------------------------------------------------------------------

alter table public.customer_credits
  add column if not exists payment_id uuid references public.payments(id) on delete set null;
alter table public.customer_credits
  add column if not exists cancelled_by uuid references auth.users(id) on delete set null;
alter table public.customer_credits
  add column if not exists cancelled_at timestamptz;

create index if not exists idx_customer_credits_payment
  on public.customer_credits (payment_id);

-- Backfill best-effort del vínculo payment_id para créditos existentes:
-- match por business + order + (fiscal_document si ambos lo tienen) de pagos
-- con método credit.
update public.customer_credits cc
   set payment_id = p.id
  from public.payments p
  join public.payment_methods pm on pm.id = p.payment_method_id
 where cc.payment_id is null
   and pm.code = 'credit'
   and p.business_id = cc.business_id
   and p.order_id = cc.order_id
   and (cc.fiscal_document_id is null
        or p.fiscal_document_id is null
        or p.fiscal_document_id = cc.fiscal_document_id);

-- ---------------------------------------------------------------------------
-- 2. Trigger de creación: guardar payment_id
--    (misma lógica que 20260714_0002 + payment_id = new.id)
-- ---------------------------------------------------------------------------

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

  -- Backstops (la app valida primero y muestra mensajes amigables).
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
    business_id, customer_id, order_id, fiscal_document_id, payment_id,
    original_amount, balance, due_date, status, notes, created_by, created_at
  )
  values (
    new.business_id, new.customer_id, new.order_id, new.fiscal_document_id,
    new.id, round(v_amount, 2), round(v_amount, 2), v_due, 'pending',
    'Venta a crédito', new.processed_by, new.created_at
  );

  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Trigger de anulación: pago credit completed → cancelled/void
--    cancela la CxC vinculada, o bloquea si ya tiene abonos.
-- ---------------------------------------------------------------------------

create or replace function public.fn_payment_cancel_customer_credit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_method_code text;
  v_credit record;
begin
  if old.status <> 'completed'
     or new.status not in ('cancelled', 'void') then
    return new;
  end if;

  select pm.code into v_method_code
  from public.payment_methods pm
  where pm.id = new.payment_method_id;

  if coalesce(v_method_code, '') <> 'credit' then
    return new;
  end if;

  -- CxC vinculada abierta: por payment_id; fallback legacy por order.
  select cc.* into v_credit
  from public.customer_credits cc
  where cc.status in ('pending', 'partial', 'overdue')
    and (
      cc.payment_id = new.id
      or (cc.payment_id is null and cc.order_id = new.order_id
          and cc.business_id = new.business_id)
    )
  order by (cc.payment_id = new.id) desc, cc.created_at desc
  limit 1;

  if v_credit.id is null then
    return new;
  end if;

  -- Con abonos recibidos NO se puede anular el pago sin resolverlos antes:
  -- habría dinero del cliente ya en caja para una venta anulada.
  if v_credit.balance < v_credit.original_amount
     or exists (
       select 1 from public.credit_payments cp
       where cp.credit_id = v_credit.id
     ) then
    raise exception
      'CREDIT_HAS_ABONOS: la cuenta por cobrar de este pago ya tiene abonos '
      'registrados. Resuelve/devuelve los abonos antes de anular la venta.';
  end if;

  update public.customer_credits
     set status = 'cancelled',
         cancelled_by = auth.uid(),
         cancelled_at = now(),
         notes = trim(both ' | ' from coalesce(notes, '') || ' | ' ||
                 'Cancelado por anulación del pago')
   where id = v_credit.id;

  return new;
end;
$$;

drop trigger if exists trg_payment_cancel_customer_credit on public.payments;
create trigger trg_payment_cancel_customer_credit
  after update of status on public.payments
  for each row
  execute function public.fn_payment_cancel_customer_credit();

comment on trigger trg_payment_cancel_customer_credit on public.payments is
  'Anular un pago con método credit cancela su cuenta por cobrar vinculada; '
  'si la CxC ya tiene abonos, bloquea la anulación (CREDIT_HAS_ABONOS).';

commit;
