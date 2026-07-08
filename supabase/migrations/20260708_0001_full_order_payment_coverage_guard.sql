-- ============================================================================
-- 20260708_0001_full_order_payment_coverage_guard
--
-- BACKSTOP server-side del sub-cobro por cierre full-order.
--
-- Contexto (Car City, orden 6425d61a): un split dejó un ítem en check_id NULL;
-- un cobro full-order (p_check_id NULL) cerró la orden marcando TODOS los ítems
-- no-void como `paid`, pero el monto cobrado no cubría ese ítem suelto → se
-- cerró como pagado sin cobrarse (sub-cobro + NCF sub-declarado). Ver
-- [[project_full_order_close_coverage_gap]].
--
-- El guard FINO y exacto ya vive en la app (table_order_screen._openPaymentModal
-- recomputa con summarizeOrderPricing y bloquea/corrige). Esto es solo la red de
-- seguridad para clientes que no pasen por esa UI (sync offline u otro cliente).
--
-- ⚠️  NO APLICAR A CIEGAS. Riesgos a validar antes:
--   1. Un RAISE falso BLOQUEA el cobro por completo (peor que la fuga rara). Por
--      eso la tolerancia es AMPLIA (3% o RD$5): atrapa fugas grandes como los
--      RD$100/16.7% del caso real, sin bloquear por redondeo/descuento.
--   2. `sum(subtotal + tax)` asume el modelo actual donde el descuento ya está
--      restado dentro de oi.subtotal (mig 20260509_0004, ver
--      [[project_exclusive_discount_double_count]]). Si hay órdenes legacy con
--      el descuento NO baked, esto sobre-cuenta → verificar antes de aplicar.
--   3. Fee de delivery / service_fee a nivel de orden hacen `pagado > ítems` →
--      dirección SEGURA (nunca bloquean). Solo bloquea sub-cobertura real.
--   4. Esta función VIVE divergente del repo ([[project_db_diverges_from_repo_migrations]]).
--      El cuerpo de abajo es COPIA EXACTA del `pg_get_functiondef` vivo del
--      overload de 15 args (2026-07-08) + el bloque GUARD. Re-verificar antes de
--      correr por si cambió.
--
-- Solo toca el overload de 15 args (el que llama la app). El de 10 args queda
-- igual (legacy).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.fn_process_payment_v3(
  p_order_id uuid,
  p_check_id uuid,
  p_payment_method_id text,
  p_amount numeric,
  p_reference text,
  p_customer_id uuid DEFAULT NULL::uuid,
  p_customer_rnc text DEFAULT NULL::text,
  p_cashier_session_id uuid DEFAULT NULL::uuid,
  p_change_amount numeric DEFAULT 0,
  p_requested_ncf_type text DEFAULT NULL::text,
  p_close_order boolean DEFAULT true,
  p_split_sequence smallint DEFAULT 0,
  p_close_check boolean DEFAULT true,
  p_paid_at timestamp with time zone DEFAULT NULL::timestamp with time zone,
  p_offline_ncf text DEFAULT NULL::text
)
 RETURNS payments
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  v_check_customer_id uuid;
  v_check_customer_rnc text;
  v_check_requested_ncf_type public.ncf_type;
  v_effective_customer_id uuid;
  v_effective_customer_rnc text;
  v_payment_id uuid;
  v_effective_at timestamptz := coalesce(p_paid_at, now());
  -- GUARD DE COBERTURA
  v_items_due numeric := 0;
  v_paid_full_order numeric := 0;
begin
  select o.session_id, o.closed_at, o.status_ext
    into v_table_session_id, v_order_closed_at, v_order_status_ext
  from public.orders o
  where o.id = p_order_id
  for update;

  if v_table_session_id is null then
    raise exception 'ORDER_NOT_FOUND';
  end if;

  if p_check_id is not null then
    select c.is_closed, c.customer_id, c.customer_rnc, c.requested_ncf_type
      into v_check_is_closed, v_check_customer_id,
           v_check_customer_rnc, v_check_requested_ncf_type
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

  v_requested_ncf_type := coalesce(
    public.normalize_ncf_type(p_requested_ncf_type),
    v_check_requested_ncf_type
  );

  v_effective_customer_id := coalesce(p_customer_id, v_check_customer_id);
  v_effective_customer_rnc := coalesce(
    nullif(trim(coalesce(p_customer_rnc, '')), ''),
    nullif(trim(coalesce(v_check_customer_rnc, '')), '')
  );

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
    requested_ncf_type, split_sequence, created_at,
    offline_ncf
  )
  values (
    v_business_id, p_order_id, p_check_id, v_payment_method_id,
    p_amount, p_reference, coalesce(p_change_amount, 0), 'completed',
    auth.uid(), p_cashier_session_id,
    v_effective_customer_id, v_effective_customer_rnc,
    v_requested_ncf_type, coalesce(p_split_sequence, 0), v_effective_at,
    nullif(trim(coalesce(p_offline_ncf, '')), '')
  )
  returning id into v_payment_id;

  if p_check_id is not null then
    if p_close_check then
      update public.order_items
      set status = 'paid'
      where order_id = p_order_id
        and check_id = p_check_id
        and status <> 'void';

      update public.order_checks
      set is_closed = true,
          closed_at = v_effective_at
      where id = p_check_id;

      select count(*)
        into v_open_items_count
      from public.order_items
      where order_id = p_order_id
        and status not in ('paid', 'void');

      if v_open_items_count = 0 then
        perform public.fn_close_order_and_table(p_order_id, 'paid');
      end if;
    end if;
  else
    if p_close_order then
      -- ── GUARD DE COBERTURA (backstop) ─────────────────────────────────
      -- El UPDATE de abajo marca TODOS los ítems no-void como pagados. Antes
      -- de cerrar, verificamos que los pagos full-order (check_id NULL) cubran
      -- el valor de los ítems aún no pagados. Suma TODOS los pagos full-order
      -- completados (ya incluye el recién insertado) → soporta split-tender
      -- (ej. 300 + 300 = 600). Tolerancia amplia para no bloquear por
      -- redondeo/descuento; el guard exacto está en la app.
      select coalesce(sum(oi.subtotal + oi.tax), 0)
        into v_items_due
      from public.order_items oi
      where oi.order_id = p_order_id
        and oi.status not in ('paid', 'void');

      select coalesce(sum(p.amount), 0)
        into v_paid_full_order
      from public.payments p
      where p.order_id = p_order_id
        and p.check_id is null
        and p.status = 'completed';

      if v_items_due - v_paid_full_order > greatest(5.0, v_items_due * 0.03) then
        raise exception
          'ORDER_PAYMENT_UNDERCOVERED: ítems por % pero cobrado % — hay productos sin incluir en el cobro',
          round(v_items_due, 2), round(v_paid_full_order, 2)
          using errcode = 'P0001';
      end if;

      update public.order_items
      set status = 'paid'
      where order_id = p_order_id
        and status <> 'void';

      perform public.fn_close_order_and_table(p_order_id, 'paid');
    end if;
  end if;

  if v_payment_method_code = 'cash' then
    v_cash_in_drawer := greatest(
      coalesce(p_amount, 0) - coalesce(p_change_amount, 0),
      0
    );

    if v_cash_in_drawer > 0 then
      insert into public.cash_transactions(
        session_id, amount, type, description, related_order_id, created_at
      )
      values (
        p_cashier_session_id, v_cash_in_drawer, 'sale',
        'Venta ' || left(p_order_id::text, 8), p_order_id, v_effective_at
      );
    end if;
  end if;

  -- FIX 2026-05-13: refrescar v_payment para que el RETURN incluya el
  -- fiscal_document_id seteado por los triggers de cierre.
  select * into v_payment
  from public.payments
  where id = v_payment_id;

  return v_payment;
end;
$function$;
