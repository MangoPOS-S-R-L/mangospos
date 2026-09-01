-- =============================================================================
-- 20260902_0002 — El abono a crédito es un documento: número, recibo y cierre.
--
-- QUÉ FALTABA:
--   1. El abono no tenía número. El recibo decía "Abono crédito CxC 1a2b3c4d"
--      (los primeros 8 del uuid). No se puede referenciar por teléfono ni
--      buscar en un cuaderno.
--   2. No había ticket. El cliente que abona RD$5,000 se iba sin papel.
--   3. En el cierre, el abono en EFECTIVO caía dentro de "Depósitos",
--      mezclado con los depósitos manuales del turno; y el abono con TARJETA
--      o TRANSFERENCIA no aparecía en ninguna parte — la caja ni se enteraba.
--
-- QUÉ HACE:
--   - `credit_payments` gana `code` (AB-00001 por negocio) y `business_id`.
--   - `fn_register_credit_abono_v2`: mismo motor, devuelve jsonb con el
--     crédito Y el recibo (code, monto, método, cliente) para imprimir.
--   - `fn_register_credit_abono` (v1) NO cambia de firma: delega en la v2 y
--     sigue devolviendo `customer_credits`. Una app vieja no se rompe.
--   - `fn_cash_session_credit_payments`: desglose de abonos del turno por
--     método, para el cierre.
--
-- LO QUE NO TOCA — A PROPÓSITO:
--   `fn_get_cash_session_summary` queda intacta. El abono en efectivo sigue
--   sumando dentro de `total_deposits` y el efectivo esperado NO cambia ni
--   un centavo. Lo que se agrega es VISIBILIDAD, no aritmética: el cierre
--   lee el desglose por la función nueva y lo imprime como un bloque aparte.
--   Mover el abono fuera de deposits habría cambiado el cuadre de todos los
--   turnos y esa función fiscal ya diverge entre el repo y la BD viva.
--
-- REQUIERE: 20260714_0002 (módulo de créditos).
-- IDEMPOTENTE: sí. REVERSIBLE: sí (ver _ROLLBACK).
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. El recibo: número propio y negocio
-- ---------------------------------------------------------------------------
-- `business_id` va denormalizado desde el crédito. Sin él, numerar por
-- negocio obliga a un join en cada inserción y el cierre a cruzar dos tablas
-- para algo que se consulta en cada corte.

alter table public.credit_payments
  add column if not exists code text,
  add column if not exists business_id uuid references public.businesses(id);

update public.credit_payments cp
   set business_id = cc.business_id
  from public.customer_credits cc
 where cc.id = cp.credit_id
   and cp.business_id is null;

create index if not exists idx_credit_payments_business_created
  on public.credit_payments (business_id, created_at desc);

-- Los abonos viejos no tienen número y no se les inventa uno: un recibo
-- numerado a posteriori es un documento que nadie firmó. El índice es
-- parcial para que convivan con los nuevos.
create unique index if not exists uq_credit_payments_business_code
  on public.credit_payments (business_id, code)
  where code is not null;

comment on column public.credit_payments.code is
  'Número del recibo de abono (AB-00001), único por negocio. NULL en los '
  'abonos anteriores a 20260902_0002: no se numeran hacia atrás.';

-- ---------------------------------------------------------------------------
-- 2. El abono, devolviendo el recibo
-- ---------------------------------------------------------------------------

create or replace function public.fn_register_credit_abono_v2(
  p_credit_id uuid,
  p_amount numeric,
  p_payment_method_code text default 'cash',
  p_reference text default null,
  p_session_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_credit public.customer_credits;
  v_method_id uuid;
  v_method_code text;
  v_method_name text;
  v_customer_name text;
  v_applied numeric;
  v_code text;
  v_seq bigint;
  v_payment public.credit_payments;
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
  v_applied     := round(least(p_amount, v_credit.balance), 2);

  select pm.id, pm.name into v_method_id, v_method_name
  from public.payment_methods pm
  where pm.business_id = v_credit.business_id
    and pm.code = v_method_code
  limit 1;

  select c.name into v_customer_name
  from public.customers c
  where c.id = v_credit.customer_id;

  -- Numeración por negocio. Mismo patrón que las requisiciones: lock propio
  -- y el cast adentro del max, para que AB-100000 no pierda contra AB-99999
  -- comparándose como texto.
  perform pg_advisory_xact_lock(
    hashtextextended(v_credit.business_id::text || ':credit_abono_code', 0));
  select coalesce(
           max(nullif(regexp_replace(code, '\D', '', 'g'), '')::bigint), 0) + 1
    into v_seq
    from public.credit_payments
   where business_id = v_credit.business_id
     and code is not null;
  v_code := 'AB-' || lpad(v_seq::text, 5, '0');

  -- Abono en efectivo: entra a la caja abierta como depósito. La descripción
  -- lleva el número del recibo para que el arqueo se pueda cruzar contra el
  -- papel que se le dio al cliente.
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

    insert into public.cash_transactions(
      session_id, amount, type, description, related_order_id)
    values (
      p_session_id, v_applied, 'deposit',
      'Abono a crédito ' || v_code ||
        coalesce(' · ' || nullif(trim(v_customer_name), ''), ''),
      v_credit.order_id
    );
  end if;

  insert into public.credit_payments(
    credit_id, business_id, code, amount, payment_method_id,
    reference, received_by, session_id)
  values (
    v_credit.id, v_credit.business_id, v_code, v_applied, v_method_id,
    nullif(trim(coalesce(p_reference, '')), ''), auth.uid(), p_session_id)
  returning * into v_payment;

  update public.customer_credits
     set balance = greatest(round(balance - p_amount, 2), 0),
         status  = case when round(balance - p_amount, 2) <= 0
                        then 'paid' else 'partial' end
   where id = v_credit.id
   returning * into v_credit;

  -- El recibo sale acá armado: el ticket no tiene que volver a consultar el
  -- nombre del cliente ni el método para imprimir.
  return jsonb_build_object(
    'credit',  to_jsonb(v_credit),
    'payment', to_jsonb(v_payment) || jsonb_build_object(
      'method_code',      v_method_code,
      'method_name',      coalesce(v_method_name, initcap(v_method_code)),
      'customer_name',    v_customer_name,
      'balance_after',    v_credit.balance,
      'original_amount',  v_credit.original_amount,
      'credit_status',    v_credit.status
    )
  );
end;
$$;

comment on function public.fn_register_credit_abono_v2(uuid, numeric, text, text, uuid) is
  'Abono a una CxC. Devuelve {credit, payment} — el payment trae el número '
  'del recibo, el método y el saldo que quedó, que es lo que imprime el '
  'ticket. El efectivo entra a la caja abierta como depósito.';

-- ---------------------------------------------------------------------------
-- 3. La v1 sigue viva y con la MISMA firma
-- ---------------------------------------------------------------------------
-- Una app instalada que todavía llame a fn_register_credit_abono tiene que
-- seguir cobrando. Delega y devuelve el crédito, como siempre.

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
  v_result jsonb;
begin
  v_result := public.fn_register_credit_abono_v2(
    p_credit_id, p_amount, p_payment_method_code, p_reference, p_session_id);
  return jsonb_populate_record(
    null::public.customer_credits, v_result->'credit');
end;
$$;

comment on function public.fn_register_credit_abono(uuid, numeric, text, text, uuid) is
  'Compatibilidad. El motor vive en fn_register_credit_abono_v2; esta '
  'conserva la firma para las apps ya instaladas.';

-- ---------------------------------------------------------------------------
-- 4. Los abonos del turno, para el cierre
-- ---------------------------------------------------------------------------
-- Lee de credit_payments directo, NO de la descripción del cash_transaction:
-- el texto es para el humano que lee el arqueo, no una llave.
--
-- Incluye los abonos con tarjeta y transferencia, que no tocan la caja. No
-- suman al efectivo esperado — van como informativos, para que el turno
-- pueda responder "¿cuánto se cobró de fiao hoy?" sin salir del cierre.

create or replace function public.fn_cash_session_credit_payments(
  p_session_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_business_id uuid;
  v_rows jsonb;
  v_by_method jsonb;
  v_cash numeric := 0;
  v_other numeric := 0;
  v_total numeric := 0;
  v_count int := 0;
begin
  -- La sesión no guarda el negocio: se llega por la caja. (cash_register_sessions
  -- solo tiene cash_register_id.)
  select cr.business_id into v_business_id
  from public.cash_register_sessions cs
  join public.cash_registers cr on cr.id = cs.cash_register_id
  where cs.id = p_session_id;

  if v_business_id is null then
    raise exception 'SESSION_NOT_FOUND';
  end if;
  if not public.user_has_business_access(auth.uid(), v_business_id) then
    raise exception 'ACCESS_DENIED';
  end if;

  select
    coalesce(sum(cp.amount), 0),
    count(*),
    coalesce(sum(cp.amount) filter (
      where coalesce(pm.code, 'cash') = 'cash'), 0),
    coalesce(sum(cp.amount) filter (
      where coalesce(pm.code, 'cash') <> 'cash'), 0)
  into v_total, v_count, v_cash, v_other
  from public.credit_payments cp
  left join public.payment_methods pm on pm.id = cp.payment_method_id
  where cp.session_id = p_session_id;

  select coalesce(jsonb_agg(t order by t->>'method_name'), '[]'::jsonb)
    into v_by_method
  from (
    select jsonb_build_object(
             'method_code', coalesce(pm.code, 'cash'),
             'method_name', coalesce(pm.name, 'Efectivo'),
             'amount',      round(sum(cp.amount), 2),
             'count',       count(*)
           ) as t
      from public.credit_payments cp
      left join public.payment_methods pm on pm.id = cp.payment_method_id
     where cp.session_id = p_session_id
     group by coalesce(pm.code, 'cash'), coalesce(pm.name, 'Efectivo')
  ) g;

  -- El detalle, para el bloque del ticket de cierre. Ordenado por hora:
  -- así se lee igual que la cinta.
  select coalesce(jsonb_agg(t order by t->>'created_at'), '[]'::jsonb)
    into v_rows
  from (
    select jsonb_build_object(
             'code',          cp.code,
             'amount',        cp.amount,
             'method_code',   coalesce(pm.code, 'cash'),
             'method_name',   coalesce(pm.name, 'Efectivo'),
             'reference',     cp.reference,
             'customer_name', c.name,
             'created_at',    cp.created_at
           ) as t
      from public.credit_payments cp
      left join public.payment_methods pm on pm.id = cp.payment_method_id
      join public.customer_credits cc on cc.id = cp.credit_id
      left join public.customers c on c.id = cc.customer_id
     where cp.session_id = p_session_id
  ) d;

  return jsonb_build_object(
    'total',      round(v_total, 2),
    'count',      v_count,
    -- Este monto YA está dentro de total_deposits del cierre. Se expone para
    -- poder decir cuánto de los depósitos fue abono, no para volver a sumarlo.
    'cash',       round(v_cash, 2),
    'other',      round(v_other, 2),
    'by_method',  v_by_method,
    'payments',   v_rows
  );
end;
$$;

comment on function public.fn_cash_session_credit_payments(uuid) is
  'Abonos a crédito recibidos en un turno, por método y en detalle. El monto '
  'en efectivo YA está contado dentro de total_deposits de '
  'fn_get_cash_session_summary: acá se expone para desglosarlo, nunca para '
  'sumarlo otra vez.';

grant execute on function public.fn_register_credit_abono_v2(uuid, numeric, text, text, uuid)
  to authenticated;
grant execute on function public.fn_cash_session_credit_payments(uuid)
  to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5. Permiso de reimpresión
-- ---------------------------------------------------------------------------
-- Un código que no esté en este catálogo lo descarta EN SILENCIO el join del
-- RPC de permisos: el gate existiría en Flutter y no dejaría pasar a nadie.

insert into public.permissions (code, name, module, description) values
  ('creditos.reimprimir', 'Reimprimir recibos de crédito', 'credits',
   'Reimprime el recibo de un abono y la factura que originó la deuda.')
on conflict (code) do nothing;

commit;
