-- Definiciones VIVAS (pg_get_functiondef en producción, 2026-10-10) de las
-- funciones de edición de cuentas y del cobro que llama fn_apply_order_edit
-- (20261010_0006). Solo para pruebas locales: no es una migración.

CREATE OR REPLACE FUNCTION public.fn_update_item_qty(p_item_id uuid, p_qty numeric)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_order_id uuid;
  v_qty numeric(10,3);
begin
  v_qty := greatest(coalesce(p_qty, 1), 1);

  update public.order_items
     set qty = v_qty,
         quantity = greatest(1, round(v_qty)::int)
   where id = p_item_id
   returning order_id into v_order_id;

  if v_order_id is null then
    raise exception 'ITEM_NOT_FOUND';
  end if;

  perform public.fn_recalc_order_totals(v_order_id);
end;
$function$;

CREATE OR REPLACE FUNCTION public.fn_update_item_notes(p_item_id uuid, p_notes text)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_order_id uuid;
begin
  update public.order_items
     set notes = nullif(trim(coalesce(p_notes, '')), '')
   where id = p_item_id
   returning order_id into v_order_id;

  if v_order_id is null then
    raise exception 'ITEM_NOT_FOUND';
  end if;

  perform public.fn_recalc_order_totals(v_order_id);
end;
$function$;

CREATE OR REPLACE FUNCTION public.fn_update_item_details(p_item_id uuid, p_product_name text, p_qty numeric, p_is_takeout boolean, p_discounts numeric, p_notes text)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_order_id uuid;
  v_check_id uuid;
  v_qty numeric(10,3);
  v_discount numeric(12,2);
  v_product_id uuid;
  v_prev_is_takeout boolean;
  v_new_is_takeout boolean;
  v_tax_mode text;
  v_tax_rate numeric := 0;
begin
  v_qty := round(greatest(coalesce(p_qty, 1), 0.001), 3);
  v_discount := round(greatest(coalesce(p_discounts, 0), 0), 2);
  v_new_is_takeout := coalesce(p_is_takeout, false);

  select product_id, coalesce(is_takeout, false)
    into v_product_id, v_prev_is_takeout
  from public.order_items
  where id = p_item_id;

  if v_product_id is null then
    raise exception 'ITEM_NOT_FOUND';
  end if;

  update public.order_items
     set product_name = coalesce(nullif(trim(coalesce(p_product_name, '')), ''), product_name),
         qty = v_qty,
         quantity = greatest(round(v_qty), 1),
         is_takeout = v_new_is_takeout,
         discounts = v_discount,
         notes = nullif(trim(coalesce(p_notes, '')), '')
   where id = p_item_id
   returning order_id, check_id into v_order_id, v_check_id;

  if v_order_id is null then
    raise exception 'ITEM_NOT_FOUND';
  end if;

  if v_prev_is_takeout is distinct from v_new_is_takeout then
    select profile.tax_mode, profile.tax_rate
      into v_tax_mode, v_tax_rate
    from public.fn_resolve_order_item_tax_profile(
      v_product_id, v_order_id, v_new_is_takeout
    ) profile;

    update public.order_items
       set tax_rate = coalesce(v_tax_rate, 0),
           original_tax_rate = coalesce(v_tax_rate, 0),
           tax_mode = coalesce(v_tax_mode, tax_mode)
     where id = p_item_id;

    perform public.fn_populate_item_tax_lines(p_item_id);
  end if;

  perform public.calculate_order_totals(v_order_id);
  if v_check_id is not null then
    perform public.calculate_check_totals(v_check_id);
  end if;
end;
$function$;

CREATE OR REPLACE FUNCTION public.fn_update_item_discount(p_item_id uuid, p_discounts numeric)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_order_id uuid;
  v_check_id uuid;
  v_discount numeric(12,2);
begin
  v_discount := round(greatest(coalesce(p_discounts, 0), 0), 2);

  update public.order_items
     set discounts = v_discount
   where id = p_item_id
   returning order_id, check_id into v_order_id, v_check_id;

  if v_order_id is null then
    raise exception 'ITEM_NOT_FOUND';
  end if;

  perform public.calculate_order_totals(v_order_id);
  if v_check_id is not null then
    perform public.calculate_check_totals(v_check_id);
  end if;
end;
$function$;

CREATE OR REPLACE FUNCTION public.fn_update_item_discount_and_notes(p_item_id uuid, p_discounts numeric, p_notes text)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_order_id uuid;
  v_check_id uuid;
  v_discount numeric(12,2);
begin
  v_discount := round(greatest(coalesce(p_discounts, 0), 0), 2);

  update public.order_items
     set discounts = v_discount,
         notes = nullif(trim(coalesce(p_notes, '')), '')
   where id = p_item_id
   returning order_id, check_id into v_order_id, v_check_id;

  if v_order_id is null then
    raise exception 'ITEM_NOT_FOUND';
  end if;

  perform public.calculate_order_totals(v_order_id);
  if v_check_id is not null then
    perform public.calculate_check_totals(v_check_id);
  end if;
end;
$function$;

CREATE OR REPLACE FUNCTION public.fn_delete_item(p_item_id uuid)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_order_id uuid;
  v_business_id uuid;
  v_allowed boolean;
  v_ncf text;
begin
  select z.business_id
    into v_business_id
    from public.order_items oi
    join public.orders o on o.id = oi.order_id
    join public.table_sessions s on s.id = o.session_id
    join public.dining_tables t on t.id = s.table_id
    join public.zones z on z.id = t.zone_id
    where oi.id = p_item_id;

  if v_business_id is null then
    raise exception 'ITEM_NOT_FOUND';
  end if;

  select coalesce(bool_or(p.allowed), false)
    into v_allowed
    from public.fn_user_effective_permissions(auth.uid(), v_business_id) p
    where p.code = 'ventas.orden.eliminar_item';

  if not v_allowed then
    raise exception 'PERMISSION_DENIED: ventas.orden.eliminar_item'
      using errcode = '42501';
  end if;

  select fd.ncf_number
    into v_ncf
    from public.order_items oi
    join public.fiscal_documents fd
      on fd.order_id = oi.order_id
     and fd.status = 'active'
     and (fd.check_id is null or fd.check_id = oi.check_id)
   where oi.id = p_item_id
   limit 1;

  if v_ncf is not null then
    raise exception
      'No se puede eliminar un producto de una cuenta ya facturada (%). '
      'Anúlalo en vez de borrarlo, o anula la factura completa.', v_ncf
      using errcode = 'MP404';
  end if;

  delete from public.order_items
   where id = p_item_id
   returning order_id into v_order_id;

  if v_order_id is null then
    raise exception 'ITEM_NOT_FOUND';
  end if;

  perform public.fn_recalc_order_totals(v_order_id);
end;
$function$;

CREATE OR REPLACE FUNCTION public.fn_move_item_to_check(p_item_id uuid, p_check_position integer)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_order uuid;
  v_check uuid;
  v_current_check uuid;
begin
  select oi.order_id, oi.check_id
    into v_order, v_current_check
  from public.order_items oi
  where oi.id = p_item_id;

  if v_order is null then
    raise exception 'ITEM_NOT_FOUND';
  end if;

  v_check := public.fn_get_or_create_check(v_order, p_check_position);

  if v_current_check is distinct from v_check then
    update public.order_items
       set check_id = v_check
     where id = p_item_id;
  end if;
end;
$function$;

CREATE OR REPLACE FUNCTION public.fn_move_items_to_check_batch(p_item_ids uuid[], p_check_position integer)
 RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_order uuid;
  v_check uuid;
  v_moved integer := 0;
begin
  if p_item_ids is null or array_length(p_item_ids, 1) is null then
    return 0;
  end if;

  select oi.order_id
    into v_order
  from public.order_items oi
  where oi.id = p_item_ids[1];

  if v_order is null then
    raise exception 'ITEM_NOT_FOUND';
  end if;

  if exists (
    select 1
    from public.order_items oi
    where oi.id = any(p_item_ids)
      and oi.order_id is distinct from v_order
  ) then
    raise exception 'ITEMS_MUST_BELONG_TO_SAME_ORDER';
  end if;

  v_check := public.fn_get_or_create_check(v_order, p_check_position);

  update public.order_items oi
     set check_id = v_check
   where oi.id = any(p_item_ids)
     and oi.check_id is distinct from v_check;

  get diagnostics v_moved = row_count;
  return v_moved;
end;
$function$;

CREATE OR REPLACE FUNCTION public.fn_toggle_item_takeout(p_item_id uuid, p_takeout boolean)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_order_id uuid;
  v_product_id uuid;
  v_tax_mode text;
  v_tax_rate numeric := 0;
BEGIN
  SELECT order_id, product_id
    INTO v_order_id, v_product_id
  FROM public.order_items
  WHERE id = p_item_id;

  IF v_order_id IS NULL THEN
    RETURN;
  END IF;

  SELECT profile.tax_mode, profile.tax_rate
    INTO v_tax_mode, v_tax_rate
  FROM public.fn_resolve_order_item_tax_profile(
    v_product_id, v_order_id, coalesce(p_takeout, false)
  ) profile;

  UPDATE public.order_items
     SET is_takeout = p_takeout,
         tax_rate = coalesce(v_tax_rate, 0),
         original_tax_rate = coalesce(v_tax_rate, 0),
         tax_mode = coalesce(v_tax_mode, tax_mode)
   WHERE id = p_item_id;

  PERFORM public.fn_populate_item_tax_lines(p_item_id);
  PERFORM public.fn_recalc_order_totals(v_order_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.fn_mark_order_takeout(p_order_id uuid, p_takeout boolean)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT id FROM public.order_items WHERE order_id = p_order_id
  LOOP
    PERFORM public.fn_toggle_item_takeout(r.id, p_takeout);
  END LOOP;
END;
$function$;

CREATE OR REPLACE FUNCTION public.fn_replace_order_item_modifiers(p_item_id uuid, p_modifiers jsonb DEFAULT '[]'::jsonb)
 RETURNS integer LANGUAGE plpgsql SET search_path TO 'public'
AS $function$
declare
  v_modifiers jsonb := coalesce(p_modifiers, '[]'::jsonb);
  v_cols text := 'item_id, name, qty, price';
  v_vals text := '$1, m->>''name'', coalesce((m->>''qty'')::numeric, 1), '
                 'coalesce((m->>''price'')::numeric, 0)';
  v_count integer;
begin
  if p_item_id is null then
    raise exception 'ITEM_ID_REQUIRED' using errcode = '22004';
  end if;
  if jsonb_typeof(v_modifiers) <> 'array' then
    raise exception 'MODIFIERS_MUST_BE_ARRAY' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('order_item_modifiers:' || p_item_id::text, 0)
  );

  if not exists (select 1 from public.order_items where id = p_item_id) then
    raise exception 'ITEM_NOT_FOUND' using errcode = 'P0002';
  end if;

  delete from public.order_item_modifiers where item_id = p_item_id;

  if exists (
    select 1 from pg_attribute
    where attrelid = 'public.order_item_modifiers'::regclass
      and attname = 'menu_item_id' and not attisdropped
  ) then
    v_cols := v_cols || ', menu_item_id';
    v_vals := v_vals || ', nullif(m->>''menu_item_id'', '''')::uuid';
  end if;
  if exists (
    select 1 from pg_attribute
    where attrelid = 'public.order_item_modifiers'::regclass
      and attname = 'modifier_id' and not attisdropped
  ) then
    v_cols := v_cols || ', modifier_id';
    v_vals := v_vals || ', nullif(m->>''modifier_id'', '''')::uuid';
  end if;

  execute format(
    'insert into public.order_item_modifiers (%s) '
    'select %s from jsonb_array_elements($2) as m',
    v_cols, v_vals
  ) using p_item_id, v_modifiers;
  get diagnostics v_count = row_count;
  return v_count;
end;
$function$;

CREATE OR REPLACE FUNCTION public.fn_set_delivery_fee(p_order_id uuid, p_amount numeric)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
  UPDATE public.orders
  SET delivery_fee = ROUND(GREATEST(COALESCE(p_amount, 0), 0), 2)
  WHERE id = p_order_id;

  PERFORM public.calculate_order_totals(p_order_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.fn_set_order_excluded_taxes(p_order_id uuid, p_tax_ids uuid[], p_employee_id uuid DEFAULT NULL::uuid)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_status text;
  v_biz_id uuid;
  v_has_fiscal boolean;
  r record;
  v_product_id uuid;
  v_is_takeout boolean;
  v_tax_mode text;
  v_tax_rate numeric := 0;
BEGIN
  SELECT o.status, ts.business_id
    INTO v_status, v_biz_id
  FROM public.orders o
  JOIN public.table_sessions ts ON ts.id = o.session_id
  WHERE o.id = p_order_id;

  IF v_biz_id IS NULL THEN
    RAISE EXCEPTION 'Orden no encontrada';
  END IF;

  IF v_status IN ('paid', 'void', 'cancelled') THEN
    RAISE EXCEPTION 'No se pueden cambiar los impuestos de una orden % ', v_status;
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.fiscal_documents fd
    WHERE fd.order_id = p_order_id
      AND coalesce(fd.status, '') NOT IN ('void', 'cancelled', 'annulled')
  ) INTO v_has_fiscal;

  IF v_has_fiscal THEN
    RAISE EXCEPTION 'La orden ya tiene un comprobante fiscal emitido';
  END IF;

  DELETE FROM public.order_excluded_taxes
   WHERE order_id = p_order_id
     AND (p_tax_ids IS NULL OR NOT (tax_id = ANY(p_tax_ids)));

  IF p_tax_ids IS NOT NULL AND array_length(p_tax_ids, 1) > 0 THEN
    INSERT INTO public.order_excluded_taxes (order_id, tax_id, excluded_by)
    SELECT p_order_id, t.id, p_employee_id
      FROM public.taxes t
     WHERE t.id = ANY(p_tax_ids)
       AND t.business_id = v_biz_id
    ON CONFLICT (order_id, tax_id) DO NOTHING;
  END IF;

  FOR r IN
    SELECT id, product_id, coalesce(is_takeout, false) AS is_takeout
      FROM public.order_items
     WHERE order_id = p_order_id
       AND status IS DISTINCT FROM 'void'
  LOOP
    v_product_id := r.product_id;
    v_is_takeout := r.is_takeout;

    IF v_product_id IS NULL THEN
      CONTINUE;
    END IF;

    SELECT profile.tax_mode, profile.tax_rate
      INTO v_tax_mode, v_tax_rate
    FROM public.fn_resolve_order_item_tax_profile(
      v_product_id, p_order_id, v_is_takeout
    ) profile;

    UPDATE public.order_items
       SET tax_rate = coalesce(v_tax_rate, 0),
           original_tax_rate = coalesce(v_tax_rate, 0),
           tax_mode = coalesce(v_tax_mode, tax_mode)
     WHERE id = r.id;

    PERFORM public.fn_populate_item_tax_lines(r.id);
  END LOOP;

  PERFORM public.fn_recalc_order_totals(p_order_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.fn_assign_customer_to_session(p_session_id uuid, p_customer_id uuid, p_customer_name text DEFAULT NULL::text)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_business_id uuid;
  v_customer_name text;
begin
  select ts.business_id
    into v_business_id
  from public.table_sessions ts
  where ts.id = p_session_id;

  if v_business_id is null then
    raise exception 'SESSION_NOT_FOUND';
  end if;

  if auth.uid() is not null
     and not public.user_has_business_access(auth.uid(), v_business_id) then
    raise exception 'ACCESS_DENIED';
  end if;

  if p_customer_id is not null then
    select c.name
      into v_customer_name
    from public.customers c
    where c.id = p_customer_id
      and c.business_id = v_business_id;

    if v_customer_name is null then
      raise exception 'CUSTOMER_NOT_FOUND';
    end if;
  end if;

  update public.table_sessions
     set customer_id = p_customer_id,
         customer_name = coalesce(
           nullif(trim(coalesce(p_customer_name, '')), ''),
           v_customer_name
         )
   where id = p_session_id;
end;
$function$;

-- Cobro (firma de 15 argumentos), tal cual en producción.
CREATE OR REPLACE FUNCTION public.fn_process_payment_v3(p_order_id uuid, p_check_id uuid, p_payment_method_id text, p_amount numeric, p_reference text, p_customer_id uuid DEFAULT NULL::uuid, p_customer_rnc text DEFAULT NULL::text, p_cashier_session_id uuid DEFAULT NULL::uuid, p_change_amount numeric DEFAULT 0, p_requested_ncf_type text DEFAULT NULL::text, p_close_order boolean DEFAULT true, p_split_sequence smallint DEFAULT 0, p_close_check boolean DEFAULT true, p_paid_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_offline_ncf text DEFAULT NULL::text)
 RETURNS payments LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
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
      select coalesce(sum(oi.subtotal + oi.tax - coalesce(oi.discounts, 0)), 0)
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

  select * into v_payment
  from public.payments
  where id = v_payment_id;

  return v_payment;
end;
$function$;
