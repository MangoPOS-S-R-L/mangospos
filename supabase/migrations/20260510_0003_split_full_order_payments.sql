-- =============================================================================
-- Fix: split full-order payments
--
-- Bug observado (2026-05-10):
--   Cobrar UNA orden con 3 splits (100 efectivo + 100 tarjeta + 300 transferencia
--   = 500) sólo persistía el primer payment (100 efectivo). El listado mostraba
--   total 100 y el cierre de caja reportaba 100 en ventas, aunque el ticket
--   impreso mostraba 500.
--
-- Causa raíz (dos componentes que se combinan):
--
--   1) El índice único `payments_unique_completed_per_check` creado en
--      `20260509_0005` para defender contra duplicate-payment bug físicamente
--      bloqueaba 2 payments completed con la misma (order_id, check_id) — sin
--      importar el método. Su propio comentario lo reconocía: "para split
--      full-order ... este indice los BLOQUEA. Si en el futuro queremos
--      full-order split nativo, necesitaremos un schema distinto".
--
--   2) El RPC `fn_process_payment_v3` cierra la orden tras el primer pago
--      full-order (líneas 241-248 de `20260509_0001`). Las llamadas
--      subsecuentes ven `closed_at` no nulo y entran al idempotency guard,
--      que devuelve el payment existente sin insertar uno nuevo. El cliente
--      Dart recibe 3 respuestas "exitosas" con el mismo payment_id y arma
--      el ticket sumando lo que tiene en memoria (500), pero la DB queda
--      con 1 row de 100.
--
-- Solución (esta migración):
--
--   A. Reemplazar el unique index para que incluya `payment_method_id` en la
--      clave: bloquea duplicates del mismo método sobre la misma orden/check
--      (caso original del bug 09 mayo), pero permite métodos distintos
--      (caso legítimo de split full-order).
--
--   B. Recrear `fn_process_payment_v3` con un nuevo parámetro
--      `p_close_order boolean default true`. Cuando `p_close_order = false`,
--      el RPC inserta el payment pero NO cierra la orden ni marca items
--      como 'paid' — espera que el último split lo haga con `p_close_order
--      = true` (default).
--
--      El cliente Dart ya construye `closeOrder: isLast` en
--      `payment_split_viewmodel.dart:465`, pero ese flag se ignoraba porque
--      el RPC no aceptaba el parámetro. Ahora pasa.
--
-- Compatibilidad:
--   - Default `p_close_order = true` mantiene el comportamiento previo para
--     llamadas que no pasen el flag (pago single-method full-order, splits
--     via checks).
--   - Single-method full-order: 1 sola llamada, p_close_order=true → idem
--     comportamiento anterior. ✓
--   - Split via checks: cada check sigue su flujo propio, p_close_order
--     irrelevante en la rama `p_check_id is not null`. ✓
--   - Split full-order (este fix): N-1 llamadas con p_close_order=false +
--     1 final con p_close_order=true. Resultado: N payments insertados,
--     orden cerrada al final. ✓
--   - Retry doble-tap mismo método: el unique index lanza 23505 → el
--     cliente Dart lo recupera. ✓
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- A. Reemplazar el unique index
-- ---------------------------------------------------------------------------

drop index if exists public.payments_unique_completed_per_check;

create unique index if not exists payments_unique_completed_per_check_method
on public.payments (
  order_id,
  coalesce(check_id, '00000000-0000-0000-0000-000000000000'::uuid),
  payment_method_id
)
where status = 'completed';

comment on index public.payments_unique_completed_per_check_method is
  'Prohibe 2 payments completed para la misma (order_id, check_id, payment_method_id). '
  'Defensa fisica contra duplicate-payment bug 20260509_0001 y, a diferencia del '
  'indice previo, permite split full-order con distintos metodos (fix 20260510_0003).';

-- ---------------------------------------------------------------------------
-- B. Recrear fn_process_payment_v3 con p_close_order
-- ---------------------------------------------------------------------------
-- Hay que dropear la versión existente porque agregar un parámetro nuevo
-- (aunque tenga default) crea una sobrecarga, no reemplaza. Mantener
-- ambas versiones generaría ambigüedad para PostgREST. Drop + recreate.

drop function if exists public.fn_process_payment_v3(
  uuid, uuid, text, numeric, text, uuid, text, uuid, numeric, text
);

create or replace function public.fn_process_payment_v3(
  p_order_id uuid,
  p_check_id uuid,
  p_payment_method_id text,
  p_amount numeric,
  p_reference text,
  p_customer_id uuid default null,
  p_customer_rnc text default null,
  p_cashier_session_id uuid default null,
  p_change_amount numeric default 0,
  p_requested_ncf_type text default null,
  p_close_order boolean default true
)
returns public.payments
language plpgsql
security definer
set search_path = public
as $$
declare
  v_payment public.payments;
  v_existing_payment public.payments;
  v_business_id uuid;
  v_table_session_id uuid;
  v_payment_method_id uuid;
  v_payment_method_code text;
  v_open_items_count bigint := 0;
  v_cash_in_drawer numeric := 0;
  v_requested_ncf_type public.ncf_type;
  v_check_is_closed boolean := false;
  v_order_closed_at timestamptz;
  v_order_status_ext public.order_status;
begin
  -- Lock atomico de la orden.
  select o.session_id, o.closed_at, o.status_ext
    into v_table_session_id, v_order_closed_at, v_order_status_ext
  from public.orders o
  where o.id = p_order_id
  for update;

  if v_table_session_id is null then
    raise exception 'ORDER_NOT_FOUND';
  end if;

  -- Idempotency guard.
  if p_check_id is not null then
    select c.is_closed
      into v_check_is_closed
    from public.order_checks c
    where c.id = p_check_id
    for update;

    if v_check_is_closed then
      select * into v_existing_payment
      from public.payments
      where order_id = p_order_id
        and check_id = p_check_id
        and status = 'completed'
      order by created_at desc
      limit 1;

      if v_existing_payment.id is not null then
        return v_existing_payment;
      end if;
      raise exception 'CHECK_ALREADY_CLOSED';
    end if;
  else
    if v_order_closed_at is not null
       or v_order_status_ext in ('paid'::public.order_status,
                                 'void'::public.order_status)
    then
      select * into v_existing_payment
      from public.payments
      where order_id = p_order_id
        and check_id is null
        and status = 'completed'
      order by created_at desc
      limit 1;

      if v_existing_payment.id is not null then
        return v_existing_payment;
      end if;
      raise exception 'ORDER_ALREADY_CLOSED';
    end if;
  end if;

  -- Validaciones preservadas.
  select ts.business_id
    into v_business_id
  from public.table_sessions ts
  where ts.id = v_table_session_id;

  if v_business_id is null then
    select z.business_id
      into v_business_id
    from public.table_sessions ts
    join public.dining_tables dt on dt.id = ts.table_id
    join public.zones z on z.id = dt.zone_id
    where ts.id = v_table_session_id
    limit 1;
  end if;

  if v_business_id is null then
    raise exception 'BUSINESS_NOT_RESOLVED';
  end if;

  if p_cashier_session_id is null then
    raise exception 'CASH_SESSION_REQUIRED';
  end if;

  if not exists (
    select 1
    from public.cash_register_sessions cs
    where cs.id = p_cashier_session_id
      and cs.status = 'open'
      and cs.closed_at is null
  ) then
    raise exception 'CASH_SESSION_NOT_OPEN';
  end if;

  v_requested_ncf_type := public.normalize_ncf_type(p_requested_ncf_type);

  if p_payment_method_id ~* '^[0-9a-f-]{36}$' then
    select pm.id, pm.code
      into v_payment_method_id, v_payment_method_code
    from public.payment_methods pm
    where pm.id = p_payment_method_id::uuid
      and pm.is_active = true
    limit 1;
  else
    select pm.id, pm.code
      into v_payment_method_id, v_payment_method_code
    from public.payment_methods pm
    where pm.business_id = v_business_id
      and pm.code = p_payment_method_id
      and pm.is_active = true
    limit 1;
  end if;

  if v_payment_method_id is null then
    raise exception 'INVALID_PAYMENT_METHOD';
  end if;

  insert into public.payments(
    business_id, order_id, check_id, payment_method_id,
    amount, reference, change_amount, status,
    processed_by, session_id, customer_id, customer_rnc,
    requested_ncf_type, created_at
  )
  values (
    v_business_id, p_order_id, p_check_id, v_payment_method_id,
    p_amount, p_reference, coalesce(p_change_amount, 0), 'completed',
    auth.uid(), p_cashier_session_id, p_customer_id, p_customer_rnc,
    v_requested_ncf_type, now()
  )
  returning * into v_payment;

  -- Cierre / marcado de items.
  if p_check_id is not null then
    -- Check-mode: comportamiento previo, no cambia con p_close_order.
    update public.order_items
    set status = 'paid'
    where order_id = p_order_id
      and check_id = p_check_id
      and status <> 'void';

    update public.order_checks
    set is_closed = true,
        closed_at = now()
    where id = p_check_id;

    select count(*)
      into v_open_items_count
    from public.order_items
    where order_id = p_order_id
      and status not in ('paid', 'void');

    if v_open_items_count = 0 then
      perform public.fn_close_order_and_table(p_order_id, 'paid');
    end if;
  else
    -- Full-order: sólo cierra cuando p_close_order = true.
    -- Splits intermedios (p_close_order = false) sólo insertan el payment;
    -- la orden queda abierta esperando el split final.
    if p_close_order then
      update public.order_items
      set status = 'paid'
      where order_id = p_order_id
        and status <> 'void';

      perform public.fn_close_order_and_table(p_order_id, 'paid');
    end if;
  end if;

  -- Cash drawer (siempre, sin importar p_close_order, porque la plata
  -- entró físicamente al cajón en este splitting).
  if v_payment_method_code = 'cash' then
    v_cash_in_drawer := greatest(
      coalesce(p_amount, 0) - coalesce(p_change_amount, 0),
      0
    );

    if v_cash_in_drawer > 0 then
      insert into public.cash_transactions(
        session_id, amount, type, description, related_order_id
      )
      values (
        p_cashier_session_id, v_cash_in_drawer, 'sale',
        'Venta ' || left(p_order_id::text, 8), p_order_id
      );
    end if;
  end if;

  return v_payment;
end;
$$;

-- Grants (mismas que tenía v3 previa).
grant execute on function public.fn_process_payment_v3(
  uuid, uuid, text, numeric, text, uuid, text, uuid, numeric, text, boolean
) to anon, authenticated, service_role;

commit;
