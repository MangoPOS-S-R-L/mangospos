
\restrict sgpofWJzq38HILOe7y8wKjTOl48esCMwrFNNRaeQftu1X5vpSoZUGS6jteI2cB5


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE SCHEMA IF NOT EXISTS "public";


ALTER SCHEMA "public" OWNER TO "pg_database_owner";


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE TYPE "public"."business_status" AS ENUM (
    'active',
    'inactive',
    'suspended'
);


ALTER TYPE "public"."business_status" OWNER TO "postgres";


CREATE TYPE "public"."dietary_type" AS ENUM (
    'unspecified',
    'vegetarian',
    'non_vegetarian'
);


ALTER TYPE "public"."dietary_type" OWNER TO "postgres";


CREATE TYPE "public"."item_status" AS ENUM (
    'pending',
    'preparing',
    'ready',
    'served',
    'void',
    'draft'
);


ALTER TYPE "public"."item_status" OWNER TO "postgres";


CREATE TYPE "public"."member_role" AS ENUM (
    'owner',
    'admin',
    'manager',
    'staff',
    'viewer'
);


ALTER TYPE "public"."member_role" OWNER TO "postgres";


CREATE TYPE "public"."membership_status" AS ENUM (
    'invited',
    'accepted',
    'declined',
    'revoked',
    'expired',
    'active',
    'inactive',
    'cancelled'
);


ALTER TYPE "public"."membership_status" OWNER TO "postgres";


CREATE TYPE "public"."movement_type" AS ENUM (
    'purchase',
    'sale',
    'adjustment',
    'transfer_in',
    'transfer_out',
    'waste',
    'return'
);


ALTER TYPE "public"."movement_type" OWNER TO "postgres";


CREATE TYPE "public"."ncf_type" AS ENUM (
    'B01',
    'B02',
    'B14',
    'B15',
    'B16',
    'E31',
    'E32',
    'E33',
    'E34',
    'E44',
    'E45'
);


ALTER TYPE "public"."ncf_type" OWNER TO "postgres";


CREATE TYPE "public"."order_origin" AS ENUM (
    'dine_in',
    'manual',
    'quick',
    'delivery',
    'self_service'
);


ALTER TYPE "public"."order_origin" OWNER TO "postgres";


CREATE TYPE "public"."order_status" AS ENUM (
    'open',
    'sent_to_kitchen',
    'partially_paid',
    'paid',
    'void'
);


ALTER TYPE "public"."order_status" OWNER TO "postgres";


CREATE TYPE "public"."plan_type" AS ENUM (
    'trial',
    'basic',
    'pro',
    'enterprise'
);


ALTER TYPE "public"."plan_type" OWNER TO "postgres";


CREATE TYPE "public"."printer_type" AS ENUM (
    'network',
    'bluetooth',
    'usb'
);


ALTER TYPE "public"."printer_type" OWNER TO "postgres";


CREATE TYPE "public"."purchase_status" AS ENUM (
    'draft',
    'sent',
    'partial',
    'received',
    'cancelled'
);


ALTER TYPE "public"."purchase_status" OWNER TO "postgres";


CREATE TYPE "public"."sold_by_type" AS ENUM (
    'unit',
    'piece',
    'weight',
    'volume',
    'package'
);


ALTER TYPE "public"."sold_by_type" OWNER TO "postgres";


CREATE TYPE "public"."table_shape" AS ENUM (
    'square',
    'circle'
);


ALTER TYPE "public"."table_shape" OWNER TO "postgres";


CREATE TYPE "public"."table_state" AS ENUM (
    'available',
    'occupied',
    'reserved',
    'blocked'
);


ALTER TYPE "public"."table_state" OWNER TO "postgres";


CREATE TYPE "public"."user_role" AS ENUM (
    'admin',
    'manager',
    'cashier',
    'waiter',
    'cook',
    'delivery',
    'owner'
);


ALTER TYPE "public"."user_role" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."agent_claim_next_job"("p_agent_key" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
declare
  v_agent record;
  v_job   record;
begin
  select *
  into v_agent
  from public.agent_nodes a
  where a.is_active = true
    and crypt(p_agent_key, a.api_key_hash) = a.api_key_hash
  limit 1;

  if not found then
    raise exception 'AGENT_AUTH_FAILED';
  end if;

  update public.agent_nodes set last_seen = now() where id = v_agent.id;

  select * into v_job
  from public.discovery_jobs j
  where j.status = 'pending'
    and j.business_id = v_agent.business_id
    and (j.site_code is null or j.site_code = v_agent.site_code)
  order by j.created_at asc
  limit 1
  for update skip locked;

  if not found then
    return null;
  end if;

  update public.discovery_jobs
     set status = 'claimed', claimed_by = v_agent.id, started_at = now()
   where id = v_job.id;

  return jsonb_build_object(
    'id', v_job.id, 'business_id', v_job.business_id,
    'site_code', v_job.site_code, 'status', 'claimed'
  );
end;
$$;


ALTER FUNCTION "public"."agent_claim_next_job"("p_agent_key" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."agent_report_result"("p_agent_key" "text", "p_job_id" "uuid", "p_status" "text", "p_err" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
declare
  v_agent record; v_job record;
begin
  select * into v_agent
  from public.agent_nodes a
  where a.is_active = true
    and crypt(p_agent_key, a.api_key_hash) = a.api_key_hash
  limit 1;
  if not found then raise exception 'AGENT_AUTH_FAILED'; end if;

  select * into v_job
  from public.discovery_jobs j
  where j.id = p_job_id and j.claimed_by = v_agent.id;
  if not found then raise exception 'JOB_NOT_CLAIMED_BY_THIS_AGENT'; end if;

  update public.discovery_jobs
     set status = p_status, finished_at = now(), error = p_err
   where id = p_job_id;
end;
$$;


ALTER FUNCTION "public"."agent_report_result"("p_agent_key" "text", "p_job_id" "uuid", "p_status" "text", "p_err" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."agent_upsert_printer"("p_agent_key" "text", "p_job_id" "uuid", "p_ip" "text", "p_name" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
declare
  v_agent record; v_job record;
begin
  select * into v_agent
  from public.agent_nodes a
  where a.is_active = true
    and crypt(p_agent_key, a.api_key_hash) = a.api_key_hash
  limit 1;
  if not found then raise exception 'AGENT_AUTH_FAILED'; end if;

  select * into v_job
  from public.discovery_jobs j
  where j.id = p_job_id and j.claimed_by = v_agent.id;
  if not found then raise exception 'JOB_NOT_CLAIMED_BY_THIS_AGENT'; end if;

  insert into public.printers (business_id, name, ip, type, mac, online, created_at)
  values (v_job.business_id, p_name, p_ip, 'network', null, false, now())
  on conflict (business_id, ip) do update
    set name = excluded.name;
end;
$$;


ALTER FUNCTION "public"."agent_upsert_printer"("p_agent_key" "text", "p_job_id" "uuid", "p_ip" "text", "p_name" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."calculate_check_totals"("_check_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  UPDATE public.order_checks
  SET 
    subtotal = COALESCE((
      SELECT SUM(subtotal) FROM public.order_items WHERE check_id = _check_id
    ), 0),
    tax = COALESCE((
      SELECT SUM(tax) FROM public.order_items WHERE check_id = _check_id
    ), 0),
    discounts = COALESCE((
      SELECT SUM(discounts) FROM public.order_items WHERE check_id = _check_id
    ), 0),
    total = COALESCE((
      SELECT SUM(subtotal + tax - discounts) FROM public.order_items WHERE check_id = _check_id
    ), 0)
  WHERE id = _check_id;
END;
$$;


ALTER FUNCTION "public"."calculate_check_totals"("_check_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."calculate_order_totals"("_order_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  _subtotal numeric;
  _tax numeric;
  _discounts numeric;
  _service_fee numeric;
  _total numeric;
BEGIN
  SELECT 
    COALESCE(SUM(subtotal), 0),
    COALESCE(SUM(tax), 0),
    COALESCE(SUM(discounts), 0)
  INTO _subtotal, _tax, _discounts
  FROM public.order_items
  WHERE order_id = _order_id;
  
  -- Obtener service_fee si aplica
  SELECT COALESCE(service_fee, 0) INTO _service_fee
  FROM public.orders WHERE id = _order_id;
  
  _total := _subtotal + _tax + _service_fee - _discounts;
  
  UPDATE public.orders
  SET 
    subtotal = _subtotal,
    tax = _tax,
    discounts = _discounts,
    total = _total
  WHERE id = _order_id;
END;
$$;


ALTER FUNCTION "public"."calculate_order_totals"("_order_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."consume_inventory_from_order"("_order_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_main_warehouse_id uuid;
  v_business_id uuid;
  v_ingredient record;
  v_consumed numeric;
  v_delta numeric;
begin
  select ts.business_id
    into v_business_id
  from public.orders o
  join public.table_sessions ts on ts.id = o.session_id
  where o.id = _order_id
  limit 1;

  if v_business_id is null then
    return;
  end if;

  select w.id
    into v_main_warehouse_id
  from public.warehouses w
  where w.business_id = v_business_id
  order by w.is_main desc, w.created_at asc nulls first, w.id asc
  limit 1;

  if v_main_warehouse_id is null then
    return;
  end if;

  for v_ingredient in
    select
      i.inventory_item_id,
      sum(i.quantity * coalesce(oi.qty, oi.quantity::numeric, 0)) as expected_qty
    from public.order_items oi
    join public.recipes r on r.menu_item_id = oi.product_id
    join public.recipe_ingredients i on i.recipe_id = r.id
    where oi.order_id = _order_id
      and oi.product_id is not null
      and oi.status <> 'void'
      and coalesce(oi.qty, oi.quantity::numeric, 0) > 0
    group by i.inventory_item_id
  loop
    select coalesce(abs(sum(im.quantity)), 0)
      into v_consumed
    from public.inventory_movements im
    where im.reference_id = _order_id
      and im.reference_type = 'order'
      and im.movement_type = 'sale'
      and im.item_id = v_ingredient.inventory_item_id;

    v_delta := greatest(v_ingredient.expected_qty - v_consumed, 0);

    if v_delta > 0 then
      insert into public.inventory_movements (
        business_id,
        warehouse_id,
        item_id,
        movement_type,
        quantity,
        reference_id,
        reference_type,
        notes
      )
      values (
        v_business_id,
        v_main_warehouse_id,
        v_ingredient.inventory_item_id,
        'sale',
        -v_delta,
        _order_id,
        'order',
        'Auto-consumo por venta'
      );
    end if;
  end loop;
end;
$$;


ALTER FUNCTION "public"."consume_inventory_from_order"("_order_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_business_defaults"("_business_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $_$
BEGIN
  -- Metodos de pago por defecto
  INSERT INTO public.payment_methods (business_id, name, code, position, icon) VALUES
    (_business_id, 'Efectivo', 'cash', 1, 'banknote'),
    (_business_id, 'Tarjeta', 'card', 2, 'credit-card'),
    (_business_id, 'Transferencia', 'transfer', 3, 'building-2');
  
  -- Moneda por defecto (Peso Dominicano)
  INSERT INTO public.currencies (business_id, code, name, symbol, is_default) VALUES
    (_business_id, 'DOP', 'Peso Dominicano', 'RD$', true);
  
  -- Configuracion por defecto
  INSERT INTO public.business_settings (business_id) VALUES (_business_id);
  
  -- Impuesto ITBIS por defecto
  INSERT INTO public.taxes (business_id, name, rate) VALUES
    (_business_id, 'ITBIS', 18);
  
  -- Zona por defecto
  INSERT INTO public.zones (business_id, name, sort_index) VALUES
    (_business_id, 'Salon Principal', 1);
  
  -- Almacen principal
  INSERT INTO public.warehouses (business_id, name, is_main) VALUES
    (_business_id, 'Almacen Principal', true);
END;
$_$;


ALTER FUNCTION "public"."create_business_defaults"("_business_id" "uuid") OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."fiscal_documents" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "business_id" "uuid" NOT NULL,
    "order_id" "uuid",
    "payment_id" "uuid",
    "customer_id" "uuid",
    "ncf_type" "public"."ncf_type" NOT NULL,
    "ncf_number" "text" NOT NULL,
    "ncf_sequence_id" "uuid",
    "customer_rnc" "text",
    "customer_name" "text" NOT NULL,
    "customer_address" "text",
    "subtotal" numeric DEFAULT 0,
    "discount" numeric DEFAULT 0,
    "tax_exempt" numeric DEFAULT 0,
    "taxable_amount" numeric DEFAULT 0,
    "itbis_amount" numeric DEFAULT 0,
    "service_fee" numeric DEFAULT 0,
    "tip" numeric DEFAULT 0,
    "total" numeric DEFAULT 0,
    "is_electronic" boolean DEFAULT false,
    "ecf_tracking_number" "text",
    "ecf_security_code" "text",
    "ecf_signed_at" timestamp with time zone,
    "ecf_xml" "text",
    "ecf_status" "text" DEFAULT 'pending'::"text",
    "status" "text" DEFAULT 'active'::"text",
    "cancelled_by" "uuid",
    "cancelled_at" timestamp with time zone,
    "cancellation_reason" "text",
    "related_document_id" "uuid",
    "issued_by" "uuid",
    "issued_at" timestamp with time zone DEFAULT "now"(),
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "fiscal_documents_ecf_status_check" CHECK (("ecf_status" = ANY (ARRAY['pending'::"text", 'sent'::"text", 'accepted'::"text", 'rejected'::"text"]))),
    CONSTRAINT "fiscal_documents_status_check" CHECK (("status" = ANY (ARRAY['active'::"text", 'cancelled'::"text", 'modified'::"text"])))
);


ALTER TABLE "public"."fiscal_documents" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_fiscal_document"("p_order_id" "uuid", "p_payment_id" "uuid", "p_customer_id" "uuid", "p_customer_rnc" "text") RETURNS "public"."fiscal_documents"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_doc public.fiscal_documents;
  v_doc_id uuid;
begin
  -- Idempotencia: si ya existe documento para el pago/orden, retornarlo.
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

  -- Emisión real usando secuencia NCF.
  v_doc_id := public.issue_fiscal_document(p_order_id, p_payment_id);

  select * into v_doc
  from public.fiscal_documents
  where id = v_doc_id;

  -- Completar datos de cliente si fueron provistos.
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


ALTER FUNCTION "public"."create_fiscal_document"("p_order_id" "uuid", "p_payment_id" "uuid", "p_customer_id" "uuid", "p_customer_rnc" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."current_user_business_ids"() RETURNS SETOF "uuid"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select m.business_id from public.memberships m where m.user_id = auth.uid()
  union
  select ub.business_id from public.user_businesses ub where ub.user_id = auth.uid();
$$;


ALTER FUNCTION "public"."current_user_business_ids"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."enforce_prep_minutes"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  if NEW.has_prep = false then
    NEW.prep_minutes := 0;
  else
    NEW.prep_minutes := greatest(0, coalesce(NEW.prep_minutes,0));
  end if;
  return NEW;
end;
$$;


ALTER FUNCTION "public"."enforce_prep_minutes"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."enqueue_print_test"("p_printer_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
begin
  -- Aquí solo marcamos last_seen y online = true para la demo
  update public.printers set online = true, last_seen = now() where id = p_printer_id;
end$$;


ALTER FUNCTION "public"."enqueue_print_test"("p_printer_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_resolve_order_item_tax_profile"("p_product_id" "uuid", "p_order_id" "uuid") RETURNS TABLE("tax_mode" "text", "tax_rate" numeric)
    LANGUAGE "sql" STABLE
    AS $$
  with item as (
    select coalesce(mi.tax_mode, 'exclusive') as tax_mode
    from public.menu_items mi
    where mi.id = p_product_id
  ),
  linked_tax as (
    select coalesce(sum(t.rate), 0)::numeric as tax_rate
    from public.menu_item_taxes mit
    join public.taxes t
      on t.id = mit.tax_id
    where mit.item_id = p_product_id
      and coalesce(t.is_active, true)
  ),
  business_default as (
    select coalesce(bs.default_tax_rate, 0)::numeric as tax_rate
    from public.orders o
    join public.table_sessions ts
      on ts.id = o.session_id
    left join public.business_settings bs
      on bs.business_id = ts.business_id
    where o.id = p_order_id
    limit 1
  )
  select
    coalesce((select tax_mode from item), 'exclusive') as tax_mode,
    case
      when coalesce((select tax_rate from linked_tax), 0) > 0
        then coalesce((select tax_rate from linked_tax), 0)
      else coalesce((select tax_rate from business_default), 0)
    end as tax_rate;
$$;


ALTER FUNCTION "public"."fn_resolve_order_item_tax_profile"("p_product_id" "uuid", "p_order_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_add_item_from_menu"("p_order_id" "uuid", "p_menu_item_id" "uuid", "p_qty" numeric DEFAULT 1, "p_check_position" integer DEFAULT 1, "p_is_takeout" boolean DEFAULT false, "p_notes" "text" DEFAULT NULL::"text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_name text;
  v_price numeric(12,2);
  v_tax_mode text;
  v_tax_rate numeric := 0;
  v_check uuid;
  v_item_id uuid;
  v_qty numeric(10,3);
begin
  v_qty := greatest(coalesce(p_qty, 1), 1);

  select name, price
    into v_name, v_price
  from public.menu_items
  where id = p_menu_item_id
  limit 1;

  if v_name is null then
    raise exception 'MENU_ITEM_NOT_FOUND';
  end if;

  select profile.tax_mode, profile.tax_rate
    into v_tax_mode, v_tax_rate
  from public.fn_resolve_order_item_tax_profile(p_menu_item_id, p_order_id) profile;

  v_check := public.fn_get_or_create_check(p_order_id, p_check_position);

  insert into public.order_items(
    order_id, check_id, product_id, product_name,
    qty, quantity, unit_price, tax_mode, tax_rate, is_takeout, notes, status
  ) values (
    p_order_id, v_check, p_menu_item_id, v_name,
    v_qty, v_qty, v_price, coalesce(v_tax_mode, 'exclusive'),
    coalesce(v_tax_rate, 0), coalesce(p_is_takeout, false), p_notes, 'draft'
  )
  returning id into v_item_id;

  perform public.fn_recalc_order_totals(p_order_id);
  return v_item_id;
end;
$$;


ALTER FUNCTION "public"."fn_add_item_from_menu"("p_order_id" "uuid", "p_menu_item_id" "uuid", "p_qty" numeric, "p_check_position" integer, "p_is_takeout" boolean, "p_notes" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_after_item_change"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  perform public.fn_recalc_order_totals(coalesce(new.order_id, old.order_id));
  return null;
end $$;


ALTER FUNCTION "public"."fn_after_item_change"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_check_max_checks"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  if (select count(*) from public.order_checks where order_id=new.order_id) >= 5 then
    raise exception 'Max 5 checks per order';
  end if;
  return new;
end $$;


ALTER FUNCTION "public"."fn_check_max_checks"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_close_cash_session"("p_session_id" "uuid", "p_end_amount" numeric, "p_notes" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_start_amount NUMERIC := 0;
    v_total_sales NUMERIC := 0;
    v_total_deposits NUMERIC := 0;
    v_total_withdrawals NUMERIC := 0;
    v_total_expenses NUMERIC := 0;
    v_expected_amount NUMERIC := 0;
    v_difference NUMERIC := 0;
BEGIN
    SELECT start_amount INTO v_start_amount FROM cash_register_sessions WHERE id = p_session_id;

    IF v_start_amount IS NULL THEN
        RAISE EXCEPTION 'SESSION_NOT_FOUND';
    END IF;

    SELECT COALESCE(SUM(amount), 0)
      INTO v_total_sales
      FROM cash_transactions
     WHERE session_id = p_session_id
       AND type = 'sale';

    SELECT COALESCE(SUM(amount), 0)
      INTO v_total_deposits
      FROM cash_transactions
     WHERE session_id = p_session_id
       AND type = 'deposit';

    SELECT COALESCE(SUM(amount), 0)
      INTO v_total_withdrawals
      FROM cash_transactions
     WHERE session_id = p_session_id
       AND type = 'withdrawal';

    SELECT COALESCE(SUM(amount), 0)
      INTO v_total_expenses
      FROM cash_transactions
     WHERE session_id = p_session_id
       AND type = 'expense';

    v_expected_amount := (v_total_deposits + v_total_sales) - (v_total_withdrawals + v_total_expenses);
    
    v_difference := p_end_amount - v_expected_amount;

    UPDATE cash_register_sessions
    SET closed_at = NOW(),
        end_amount = p_end_amount,
        difference = v_difference,
        status = 'closed',
        notes = p_notes
    WHERE id = p_session_id;

    RETURN jsonb_build_object(
      'success', true,
      'difference', v_difference,
      'expected', v_expected_amount,
      'expected_amount', v_expected_amount,
      'start_amount', v_start_amount,
      'total_sales', v_total_sales,
      'total_deposits', v_total_deposits,
      'total_withdrawals', v_total_withdrawals,
      'total_expenses', v_total_expenses
    );
END;
$$;


ALTER FUNCTION "public"."fn_close_cash_session"("p_session_id" "uuid", "p_end_amount" numeric, "p_notes" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_close_order_and_table"("p_order_id" "uuid", "p_status" "public"."order_status") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_session uuid;
  v_open_count int;
  v_table_id uuid;
begin
  update public.orders
  set status_ext = p_status,
      closed_at = now()
  where id = p_order_id;

  select session_id into v_session from public.orders where id = p_order_id;
  select table_id into v_table_id from public.table_sessions where id = v_session;

  select count(*) into v_open_count
  from public.orders
  where session_id = v_session
    and closed_at is null
    and status_ext not in ('paid', 'void');

  if coalesce(v_open_count, 0) = 0 then
    update public.table_sessions
    set closed_at = now()
    where id = v_session and closed_at is null;

    if v_table_id is not null then
      update public.dining_tables
      set state = 'available'
      where id = v_table_id;
    end if;
  end if;
end;
$$;


ALTER FUNCTION "public"."fn_close_order_and_table"("p_order_id" "uuid", "p_status" "public"."order_status") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_compute_item_totals"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
declare
  mods_total numeric(12,2) := 0;
  v_line_amount numeric(12,2) := 0;
  v_tax_rate numeric := greatest(coalesce(new.tax_rate, 0), 0);
  v_tax_mode text := coalesce(new.tax_mode, 'exclusive');
  v_net_subtotal numeric(12,2) := 0;
begin
  select coalesce(sum(price*qty),0)
    into mods_total
  from public.order_item_modifiers
  where item_id = coalesce(new.id, old.id);

  v_line_amount := round(
    (coalesce(new.unit_price, 0) * coalesce(new.qty, new.quantity, 1)) +
    mods_total,
    2
  );

  if v_tax_mode = 'inclusive' and v_tax_rate > 0 then
    v_net_subtotal := round(v_line_amount / (1 + (v_tax_rate / 100.0)), 2);
    new.subtotal := v_net_subtotal;
    new.tax := round(v_line_amount - v_net_subtotal, 2);
    new.total := round(v_line_amount - coalesce(new.discounts,0), 2);
  else
    new.subtotal := v_line_amount;
    new.tax := round(new.subtotal * (v_tax_rate / 100.0), 2);
    new.total := round(
      new.subtotal - coalesce(new.discounts,0) + coalesce(new.tax,0),
      2
    );
  end if;
  return new;
end $$;


ALTER FUNCTION "public"."fn_compute_item_totals"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_confirm_order_to_kitchen"("p_order_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  update public.orders
  set status = 'sent',
      status_ext = 'sent_to_kitchen'
  where id = p_order_id;

  update public.order_items
  set status = 'pending'
  where order_id = p_order_id
    and status in ('draft', 'pending');

  perform public.consume_inventory_from_order(p_order_id);
end;
$$;


ALTER FUNCTION "public"."fn_confirm_order_to_kitchen"("p_order_id" "uuid") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."order_checks" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "order_id" "uuid" NOT NULL,
    "label" "text" DEFAULT 'C1'::"text" NOT NULL,
    "position" integer DEFAULT 1 NOT NULL,
    "is_closed" boolean DEFAULT false NOT NULL,
    "subtotal" numeric(12,2) DEFAULT 0 NOT NULL,
    "discounts" numeric(12,2) DEFAULT 0 NOT NULL,
    "tax" numeric(12,2) DEFAULT 0 NOT NULL,
    "total" numeric(12,2) DEFAULT 0 NOT NULL
);


ALTER TABLE "public"."order_checks" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_create_split_bill"("p_order_id" "uuid", "p_number_of_checks" integer) RETURNS SETOF "public"."order_checks"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_i int;
  v_check_id uuid;
begin
  -- Create checks
  for v_i in 1..p_number_of_checks loop
    insert into public.order_checks(order_id, label, position, is_closed)
    values (p_order_id, 'Cuenta ' || v_i, v_i, false)
    returning id into v_check_id;
  end loop;

  -- Return all checks for this order
  return query
  select * from public.order_checks
  where order_id = p_order_id
  order by position;
end;
$$;


ALTER FUNCTION "public"."fn_create_split_bill"("p_order_id" "uuid", "p_number_of_checks" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_get_cash_session_summary"("p_session_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_result JSONB;
BEGIN
    SELECT jsonb_build_object(
        'start_amount', s.start_amount,
        'opened_at', s.opened_at,
        'total_sales', (SELECT COALESCE(SUM(amount), 0) FROM cash_transactions WHERE session_id = s.id AND type = 'sale'),
        'total_deposits', (SELECT COALESCE(SUM(amount), 0) FROM cash_transactions WHERE session_id = s.id AND type = 'deposit'),
        'total_withdrawals', (SELECT COALESCE(SUM(amount), 0) FROM cash_transactions WHERE session_id = s.id AND type = 'withdrawal'),
        'total_expenses', (SELECT COALESCE(SUM(amount), 0) FROM cash_transactions WHERE session_id = s.id AND type = 'expense'),
        'total_income', (SELECT COALESCE(SUM(amount), 0) FROM cash_transactions WHERE session_id = s.id AND type IN ('sale', 'deposit')),
        'total_outflows', (SELECT COALESCE(SUM(amount), 0) FROM cash_transactions WHERE session_id = s.id AND type IN ('withdrawal', 'expense')),
        'expected_amount',
          (SELECT COALESCE(SUM(amount), 0) FROM cash_transactions WHERE session_id = s.id AND type IN ('sale', 'deposit'))
          -
          (SELECT COALESCE(SUM(amount), 0) FROM cash_transactions WHERE session_id = s.id AND type IN ('withdrawal', 'expense'))
    ) INTO v_result
    FROM cash_register_sessions s
    WHERE s.id = p_session_id;
    
    RETURN v_result;
END;
$$;


ALTER FUNCTION "public"."fn_get_cash_session_summary"("p_session_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_get_or_create_check"("p_order_id" "uuid", "p_position" integer DEFAULT 1) RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare v_check_id uuid;
begin
  select id into v_check_id
  from public.order_checks
  where order_id = p_order_id and position = p_position;

  if v_check_id is null then
    insert into public.order_checks(order_id, label, position)
    values (p_order_id, 'C'||p_position::text, p_position)
    returning id into v_check_id;
  end if;

  return v_check_id;
end $$;


ALTER FUNCTION "public"."fn_get_or_create_check"("p_order_id" "uuid", "p_position" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_get_or_create_virtual_table"("p_business_id" "uuid", "p_origin" "public"."order_origin") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_zone_name text :=
    case when p_origin = 'quick' then 'Ventas rapidas' else 'Ventas manuales' end;
  v_zone_sort int := case when p_origin = 'quick' then 901 else 900 end;
  v_table_code text := case when p_origin = 'quick' then 'quick' else 'manual' end;
  v_table_label text :=
    case when p_origin = 'quick' then 'Venta rapida auto' else 'Venta manual auto' end;
  v_zone_id uuid;
  v_table_id uuid;
begin
  select id
    into v_zone_id
  from public.zones
  where business_id = p_business_id
    and name = v_zone_name
  limit 1;

  if v_zone_id is null then
    begin
      insert into public.zones (business_id, name, sort_index, is_active)
      values (p_business_id, v_zone_name, v_zone_sort, true)
      returning id into v_zone_id;
    exception when unique_violation then
      select id
        into v_zone_id
      from public.zones
      where business_id = p_business_id
        and name = v_zone_name
      limit 1;
    end;
  end if;

  select id
    into v_table_id
  from public.dining_tables
  where zone_id = v_zone_id
    and code = v_table_code
  limit 1;

  if v_table_id is null then
    begin
      insert into public.dining_tables (
        zone_id, code, label, shape, state, capacity,
        pos_x, pos_y, width, height, rotation, is_active
      )
      values (
        v_zone_id,
        v_table_code,
        v_table_label,
        'square',
        'available',
        2,
        0, 0, 1, 1, 0, true
      )
      returning id into v_table_id;
    exception when unique_violation then
      select id
        into v_table_id
      from public.dining_tables
      where zone_id = v_zone_id
        and code = v_table_code
      limit 1;
    end;
  end if;

  return v_table_id;
end;
$$;


ALTER FUNCTION "public"."fn_get_or_create_virtual_table"("p_business_id" "uuid", "p_origin" "public"."order_origin") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_mark_order_ready"("p_order_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  update public.order_items
  set status = 'ready',
      ready_at = now()
  where order_id = p_order_id
    and status in ('preparing');
end;
$$;


ALTER FUNCTION "public"."fn_mark_order_ready"("p_order_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_mark_order_takeout"("p_order_id" "uuid", "p_takeout" boolean) RETURNS "void"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  update public.order_items set is_takeout = p_takeout where order_id = p_order_id;
$$;


ALTER FUNCTION "public"."fn_mark_order_takeout"("p_order_id" "uuid", "p_takeout" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_move_item_to_check"("p_item_id" "uuid", "p_check_position" integer) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_order uuid;
  v_check uuid;
begin
  select order_id into v_order
  from public.order_items
  where id = p_item_id;

  if v_order is null then
    raise exception 'ITEM_NOT_FOUND';
  end if;

  v_check := public.fn_get_or_create_check(v_order, p_check_position);

  update public.order_items
  set check_id = v_check
  where id = p_item_id;

  perform public.fn_recalc_order_totals(v_order);
end $$;


ALTER FUNCTION "public"."fn_move_item_to_check"("p_item_id" "uuid", "p_check_position" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_normalize_domain"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $_$
begin
  if new.domain is not null then
    -- quita http(s)://
    new.domain := regexp_replace(new.domain, '^https?://', '', 'i');
    -- quita todo lo que venga después de una /
    new.domain := regexp_replace(new.domain, '/.*$', '');
    -- quita espacios
    new.domain := regexp_replace(new.domain, '\s+', '', 'g');
    -- a minúsculas
    new.domain := lower(new.domain);
  end if;
  return new;
end;
$_$;


ALTER FUNCTION "public"."fn_normalize_domain"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_oi_sync_qty_quantity"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  if new.qty is null and new.quantity is null then
    new.qty := 1;
  end if;

  new.quantity := coalesce(new.quantity, new.qty, 1);
  new.qty      := coalesce(new.qty,      new.quantity, 1);

  if new.qty <= 0 then
    new.qty := 1; new.quantity := 1;
  end if;

  return new;
end $$;


ALTER FUNCTION "public"."fn_oi_sync_qty_quantity"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_open_cash_session"("p_cash_register_id" "uuid", "p_user_id" "uuid", "p_start_amount" numeric) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_session_id UUID;
    v_existing_open UUID;
BEGIN
    SELECT id INTO v_existing_open FROM cash_register_sessions
    WHERE cash_register_id = p_cash_register_id AND status = 'open';

    IF v_existing_open IS NOT NULL THEN
        RETURN jsonb_build_object('error', 'Caja ya esta abierta', 'session_id', v_existing_open);
    END IF;

    INSERT INTO cash_register_sessions (cash_register_id, user_id, start_amount, status)
    VALUES (p_cash_register_id, p_user_id, p_start_amount, 'open')
    RETURNING id INTO v_session_id;

    INSERT INTO cash_transactions (session_id, amount, type, description)
    VALUES (v_session_id, p_start_amount, 'deposit', 'Apertura de caja');

    RETURN jsonb_build_object('success', true, 'session_id', v_session_id);
END;
$$;


ALTER FUNCTION "public"."fn_open_cash_session"("p_cash_register_id" "uuid", "p_user_id" "uuid", "p_start_amount" numeric) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_open_manual_or_quick"("p_origin" "public"."order_origin", "p_user_id" "uuid", "p_people_count" integer DEFAULT 1) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_user_id uuid := coalesce(p_user_id, auth.uid());
  v_business_id uuid;
  v_table_id uuid;
  v_session_id uuid;
  v_order_id uuid;
  v_existing_session uuid;
  v_open_order_id uuid;
begin
  if v_user_id is null then
    raise exception 'fn_open_manual_or_quick: user id is required';
  end if;

  select business_id
    into v_business_id
  from public.user_businesses
  where user_id = v_user_id
  order by created_at
  limit 1;

  if v_business_id is null then
    select bid
      into v_business_id
    from public.current_user_business_ids() as bid
    limit 1;
  end if;

  if v_business_id is null then
    raise exception 'fn_open_manual_or_quick: no business found for user %', v_user_id;
  end if;

  v_table_id := public.fn_get_or_create_virtual_table(v_business_id, p_origin);

  -- Cierra cualquier sesión abierta previa en esta mesa virtual
  select id
    into v_existing_session
  from public.table_sessions
  where table_id = v_table_id
    and closed_at is null
  limit 1;

  if v_existing_session is not null then
    for v_open_order_id in
      select id
      from public.orders
      where session_id = v_existing_session
        and status_ext = 'open'
    loop
      perform public.fn_close_order_and_table(v_open_order_id, 'void');
    end loop;

    update public.table_sessions
    set closed_at = now()
    where id = v_existing_session;
  end if;

  insert into public.table_sessions (table_id, opened_by, origin, waiter_user_id, people_count)
  values (v_table_id, v_user_id, p_origin, v_user_id, greatest(1, p_people_count))
  returning id into v_session_id;

  insert into public.orders (session_id, status_ext, subtotal, discounts, tax, total, total_amount)
  values (v_session_id, 'open', 0, 0, 0, 0, 0)
  returning id into v_order_id;

  insert into public.order_checks (order_id, label, position)
  values (v_order_id, 'C1', 1);

  return jsonb_build_object('session_id', v_session_id, 'order_id', v_order_id);
end;
$$;


ALTER FUNCTION "public"."fn_open_manual_or_quick"("p_origin" "public"."order_origin", "p_user_id" "uuid", "p_people_count" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_open_table"("p_table_id" "uuid", "p_user_id" "uuid", "p_people_count" integer DEFAULT 1) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_session_id uuid;
  v_order_id uuid;
begin
  -- Si ya hay sesión abierta, reusarla
  select id into v_session_id
  from public.table_sessions
  where table_id = p_table_id and closed_at is null
  order by opened_at desc
  limit 1;

  if v_session_id is null then
    insert into public.table_sessions(table_id, opened_by, origin, waiter_user_id, people_count)
    values (p_table_id, p_user_id, 'dine_in', p_user_id, greatest(1, p_people_count))
    returning id into v_session_id;
  end if;

  -- Marcar la mesa como ocupada
  update public.dining_tables
  set state = 'occupied'
  where id = p_table_id;

  -- Orden activa (si no existe, crear una nueva)
  select id into v_order_id
  from public.orders
  where session_id = v_session_id
    and closed_at is null
    and status_ext not in ('paid', 'void')
  order by created_at desc limit 1;

  if v_order_id is null then
    insert into public.orders(session_id, status_ext, subtotal, discounts, tax, total, total_amount)
    values (v_session_id, 'open', 0, 0, 0, 0, 0)
    returning id into v_order_id;

    -- C1 por defecto
    insert into public.order_checks(order_id, label, position)
    values (v_order_id, 'C1', 1);
  end if;

  return jsonb_build_object('session_id', v_session_id, 'order_id', v_order_id);
end $$;


ALTER FUNCTION "public"."fn_open_table"("p_table_id" "uuid", "p_user_id" "uuid", "p_people_count" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_pick_member_for_table"("p_table_id" "uuid") RETURNS "uuid"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  with biz as (
    select z.business_id
    from public.dining_tables dt
    join public.zones z on z.id = dt.zone_id
    where dt.id = p_table_id
    limit 1
  ),
  pick_from_memberships as (
    select m.user_id
    from public.memberships m, biz
    where m.business_id = biz.business_id
      and coalesce(m.status, 'active') = 'active'
    order by
      case when coalesce(m.role::text,'staff') in ('owner','admin','manager') then 0 else 1 end,
      m.start_date nulls last
    limit 1
  ),
  pick_from_user_businesses as (
    select ub.user_id
    from public.user_businesses ub, biz
    where ub.business_id = biz.business_id
    order by
      case when coalesce(ub.role,'staff') in ('owner','admin','manager') then 0 else 1 end,
      ub.created_at nulls last
    limit 1
  )
  select coalesce(
    (select user_id from pick_from_memberships),
    (select user_id from pick_from_user_businesses)
  );
$$;


ALTER FUNCTION "public"."fn_pick_member_for_table"("p_table_id" "uuid") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."payments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "business_id" "uuid" NOT NULL,
    "order_id" "uuid",
    "check_id" "uuid",
    "fiscal_document_id" "uuid",
    "payment_method_id" "uuid",
    "amount" numeric NOT NULL,
    "reference" "text",
    "change_amount" numeric DEFAULT 0,
    "status" "text" DEFAULT 'completed'::"text",
    "processed_by" "uuid",
    "session_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "payments_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'completed'::"text", 'refunded'::"text", 'cancelled'::"text"])))
);


ALTER TABLE "public"."payments" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_process_payment"("p_order_id" "uuid", "p_check_id" "uuid", "p_payment_method_id" "text", "p_amount" numeric, "p_reference" "text", "p_customer_id" "uuid" DEFAULT NULL::"uuid", "p_customer_rnc" "text" DEFAULT NULL::"text") RETURNS "public"."payments"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $_$
declare
  v_payment public.payments;
  v_business_id uuid;
  v_session_id uuid;
  v_payment_method_id uuid;
begin
  select session_id into v_session_id from public.orders where id = p_order_id;
  -- Get business_id from order->session->table->zone OR current user context
  -- Simplest is to fetch from order ownership, but here let's assume we can get it from context or passed.
  -- For now, we'll try to get it from table_session
  select z.business_id into v_business_id
  from public.orders o
  join public.table_sessions ts on o.session_id = ts.id
  join public.dining_tables dt on ts.table_id = dt.id
  join public.zones z on dt.zone_id = z.id
  where o.id = p_order_id;

  -- Resolver payment_method_id (uuid o code)
  if p_payment_method_id ~* '^[0-9a-f-]{36}$' then
    v_payment_method_id := p_payment_method_id::uuid;
  else
    select pm.id into v_payment_method_id
    from public.payment_methods pm
    where pm.business_id = v_business_id
      and pm.code = p_payment_method_id
      and pm.is_active = true
    limit 1;
  end if;

  if v_payment_method_id is null then
    raise exception 'Metodo de pago no valido: %', p_payment_method_id;
  end if;

  insert into public.payments(
    business_id, order_id, check_id, payment_method_id, amount, reference, status, session_id, created_at
  )
  values (
    v_business_id, p_order_id, p_check_id, v_payment_method_id, p_amount, p_reference, 'completed', v_session_id, now()
  )
  returning * into v_payment;

  perform public.fn_close_order_and_table(p_order_id, 'paid');

  return v_payment;
end;
$_$;


ALTER FUNCTION "public"."fn_process_payment"("p_order_id" "uuid", "p_check_id" "uuid", "p_payment_method_id" "text", "p_amount" numeric, "p_reference" "text", "p_customer_id" "uuid", "p_customer_rnc" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_process_payment_v2"("p_order_id" "uuid", "p_check_id" "uuid", "p_payment_method_id" "text", "p_amount" numeric, "p_reference" "text", "p_customer_id" "uuid" DEFAULT NULL::"uuid", "p_customer_rnc" "text" DEFAULT NULL::"text", "p_cashier_session_id" "uuid" DEFAULT NULL::"uuid") RETURNS "public"."payments"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $_$
declare
  v_payment public.payments;
  v_business_id uuid;
  v_table_session_id uuid;
  v_payment_method_id uuid;
begin
  select o.session_id into v_table_session_id
  from public.orders o
  where o.id = p_order_id;

  -- Buscar business_id desde la mesa/zona (evita depender de orders.business_id)
  select z.business_id into v_business_id
  from public.table_sessions ts
  join public.dining_tables dt on dt.id = ts.table_id
  join public.zones z on z.id = dt.zone_id
  where ts.id = v_table_session_id;

  -- Fallback si no hay mesa (manual/quick) o no se pudo resolver
  if v_business_id is null then
    select bid into v_business_id
    from public.current_user_business_ids() as bid
    limit 1;
  end if;

  -- Resolver payment_method_id (uuid o code)
  if p_payment_method_id ~* '^[0-9a-f-]{36}$' then
    v_payment_method_id := p_payment_method_id::uuid;
  else
    select pm.id into v_payment_method_id
    from public.payment_methods pm
    where pm.business_id = v_business_id
      and pm.code = p_payment_method_id
      and pm.is_active = true
    limit 1;
  end if;

  if v_payment_method_id is null then
    raise exception 'Metodo de pago no valido: %', p_payment_method_id;
  end if;

  insert into public.payments(
    business_id,
    order_id,
    check_id,
    payment_method_id,
    amount,
    reference,
    change_amount,
    status,
    processed_by,
    session_id,
    created_at
  )
  values (
    v_business_id,
    p_order_id,
    p_check_id,
    v_payment_method_id,
    p_amount,
    p_reference,
    0,
    'completed',
    auth.uid(),
    coalesce(p_cashier_session_id, v_table_session_id),
    now()
  )
  returning * into v_payment;

  perform public.fn_close_order_and_table(p_order_id, 'paid');

  return v_payment;
end;
$_$;


ALTER FUNCTION "public"."fn_process_payment_v2"("p_order_id" "uuid", "p_check_id" "uuid", "p_payment_method_id" "text", "p_amount" numeric, "p_reference" "text", "p_customer_id" "uuid", "p_customer_rnc" "text", "p_cashier_session_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_process_payment_v3"("p_order_id" "uuid", "p_check_id" "uuid", "p_payment_method_id" "text", "p_amount" numeric, "p_reference" "text", "p_customer_id" "uuid" DEFAULT NULL::"uuid", "p_customer_rnc" "text" DEFAULT NULL::"text", "p_cashier_session_id" "uuid" DEFAULT NULL::"uuid", "p_change_amount" numeric DEFAULT 0) RETURNS "public"."payments"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_payment public.payments;
  v_business_id uuid;
  v_table_session_id uuid;
  v_payment_method_id uuid;
  v_payment_method_code text;
  v_open_items_count bigint := 0;
  v_cash_in_drawer numeric := 0;
begin
  select o.session_id
    into v_table_session_id
  from public.orders o
  where o.id = p_order_id;

  if v_table_session_id is null then
    raise exception 'ORDER_NOT_FOUND';
  end if;

  select ts.business_id
    into v_business_id
  from public.table_sessions ts
  where ts.id = v_table_session_id;

  if v_business_id is null then
    select bid into v_business_id
    from public.current_user_business_ids() as bid
    limit 1;
  end if;

  if v_business_id is null then
    raise exception 'BUSINESS_NOT_FOUND';
  end if;

  if p_cashier_session_id is null then
    raise exception 'CASH_SESSION_REQUIRED';
  end if;

  perform 1
  from public.cash_register_sessions s
  where s.id = p_cashier_session_id
    and s.status = 'open'
    and s.closed_at is null;

  if not found then
    raise exception 'CASH_SESSION_NOT_OPEN';
  end if;

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
    business_id,
    order_id,
    check_id,
    payment_method_id,
    amount,
    reference,
    change_amount,
    status,
    processed_by,
    session_id,
    customer_id,
    customer_rnc,
    created_at
  )
  values (
    v_business_id,
    p_order_id,
    p_check_id,
    v_payment_method_id,
    p_amount,
    p_reference,
    coalesce(p_change_amount, 0),
    'completed',
    auth.uid(),
    p_cashier_session_id,
    p_customer_id,
    p_customer_rnc,
    now()
  )
  returning * into v_payment;

  if p_check_id is not null then
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
    update public.order_items
    set status = 'paid'
    where order_id = p_order_id
      and status <> 'void';

    perform public.fn_close_order_and_table(p_order_id, 'paid');
  end if;

  if v_payment_method_code = 'cash' then
    v_cash_in_drawer := greatest(
      coalesce(p_amount, 0) - coalesce(p_change_amount, 0),
      0
    );

    if v_cash_in_drawer > 0 then
      insert into public.cash_transactions(
        session_id,
        amount,
        type,
        description,
        related_order_id
      )
      values (
        p_cashier_session_id,
        v_cash_in_drawer,
        'sale',
        'Venta ' || left(p_order_id::text, 8),
        p_order_id
      );
    end if;
  end if;

  return v_payment;
end;
$$;


ALTER FUNCTION "public"."fn_process_payment_v3"("p_order_id" "uuid", "p_check_id" "uuid", "p_payment_method_id" "text", "p_amount" numeric, "p_reference" "text", "p_customer_id" "uuid", "p_customer_rnc" "text", "p_cashier_session_id" "uuid", "p_change_amount" numeric) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_recalc_order_totals"("p_order_id" "uuid") RETURNS "void"
    LANGUAGE "sql"
    AS $$
  with sums as (
    select
      order_id,
      coalesce(sum(subtotal),0) as subtotal,
      coalesce(sum(discounts),0) as discounts,
      coalesce(sum(tax),0) as tax,
      coalesce(sum(total),0) as total
    from public.order_items
    where order_id = p_order_id
    group by order_id
  )
  update public.orders o
     set subtotal = s.subtotal,
         discounts = s.discounts,
         tax = s.tax,
         total = s.total,
         total_amount = s.total        -- mantiene compatibilidad con tu campo legacy
  from sums s
  where o.id = s.order_id;
$$;


ALTER FUNCTION "public"."fn_recalc_order_totals"("p_order_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_start_preparing_order"("p_order_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  update public.order_items
  set status = 'preparing',
      started_at = now()
  where order_id = p_order_id
    and status in ('pending');
end;
$$;


ALTER FUNCTION "public"."fn_start_preparing_order"("p_order_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_toggle_item_takeout"("p_item_id" "uuid", "p_takeout" boolean) RETURNS "void"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  update public.order_items
  set is_takeout = p_takeout
  where id = p_item_id;
$$;


ALTER FUNCTION "public"."fn_toggle_item_takeout"("p_item_id" "uuid", "p_takeout" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_user_effective_permissions"("p_user_id" "uuid", "p_business_id" "uuid") RETURNS TABLE("code" "text", "allowed" boolean)
    LANGUAGE "plpgsql" STABLE
    AS $$
begin
  return query
  with role_perms as (
    select p.code, rp.allow
    from user_roles ur
    join roles r on r.id = ur.role_id and r.business_id = ur.business_id
    join role_permissions rp on rp.role_id = r.id
    join permissions p on p.id = rp.permission_id
    where ur.user_id = p_user_id and ur.business_id = p_business_id
  ),
  base as (
    select code, bool_or(allow) as allowed
    from role_perms
    group by code
  ),
  overrides as (
    select p.code, o.allow
    from user_permission_overrides o
    join permissions p on p.id = o.permission_id
    where o.user_id = p_user_id and o.business_id = p_business_id
  )
  select coalesce(o.code, b.code) as code,
         coalesce(o.allow, b.allowed) as allowed
  from base b
  full outer join overrides o on o.code = b.code;
end;
$$;


ALTER FUNCTION "public"."fn_user_effective_permissions"("p_user_id" "uuid", "p_business_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_user_in_business"("p_business_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE
    AS $$
select exists (
  select 1 from user_businesses ub
  where ub.business_id = p_business_id and ub.user_id = auth.uid()
);
$$;


ALTER FUNCTION "public"."fn_user_in_business"("p_business_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."generate_ncf"("_business_id" "uuid", "_ncf_type" "public"."ncf_type") RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  _sequence RECORD;
  _new_number bigint;
  _ncf text;
BEGIN
  SELECT * INTO _sequence
  FROM public.ncf_sequences
  WHERE business_id = _business_id
    AND ncf_type = _ncf_type
    AND is_active = true
    AND current_number < range_end
    AND (expiration_date IS NULL OR expiration_date > CURRENT_DATE)
  FOR UPDATE;
  
  IF NOT FOUND THEN
    RAISE EXCEPTION 'No hay secuencia NCF disponible para tipo %', _ncf_type;
  END IF;
  
  _new_number := _sequence.current_number + 1;
  
  UPDATE public.ncf_sequences
  SET current_number = _new_number
  WHERE id = _sequence.id;
  
  _ncf := _sequence.prefix || LPAD(_new_number::text, 8, '0');
  
  RETURN _ncf;
END;
$$;


ALTER FUNCTION "public"."generate_ncf"("_business_id" "uuid", "_ncf_type" "public"."ncf_type") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."has_business_role"("_user_id" "uuid", "_business_id" "uuid", "_roles" "text"[]) RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  SELECT public.user_business_role(_user_id, _business_id) = ANY(_roles)
$$;


ALTER FUNCTION "public"."has_business_role"("_user_id" "uuid", "_business_id" "uuid", "_roles" "text"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_admin_of_business"("p_business" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE
    AS $$
  select
    exists(
      select 1 from public.memberships m
      where m.business_id = p_business and m.user_id = auth.uid()
        and m.role in ('owner', 'admin')
    )
    or
    exists(
      select 1 from public.user_businesses ub
      where ub.business_id = p_business and ub.user_id = auth.uid()
        and ub.role in ('owner', 'admin')
    );
$$;


ALTER FUNCTION "public"."is_admin_of_business"("p_business" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_business_owner"("biz" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE
    AS $$
  select exists(select 1 from public.businesses b
                where b.id = biz and b.owner_id = auth.uid());
$$;


ALTER FUNCTION "public"."is_business_owner"("biz" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_member_of_business"("p_business" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE
    AS $$
  select
    exists(
      select 1 from public.memberships m
      where m.business_id = p_business and m.user_id = auth.uid()
    )
    or
    exists(
      select 1 from public.user_businesses ub
      where ub.business_id = p_business and ub.user_id = auth.uid()
    );
$$;


ALTER FUNCTION "public"."is_member_of_business"("p_business" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."issue_fiscal_document"("_order_id" "uuid", "_payment_id" "uuid") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
declare
  o record;
  fs record;
  ncf text;
  doc_id uuid;
  v_business_id uuid;
  v_ncf_type public.ncf_type;
begin
  select * into o from public.orders where id = _order_id;

  -- 1) Preferir business_id del pago
  select p.business_id into v_business_id
  from public.payments p
  where p.id = _payment_id;

  -- 2) Fallback: resolver por sesion/mesa/zona
  if v_business_id is null then
    select z.business_id into v_business_id
    from public.table_sessions ts
    join public.dining_tables dt on dt.id = ts.table_id
    join public.zones z on z.id = dt.zone_id
    where ts.id = o.session_id;
  end if;

  if v_business_id is null then
    raise exception 'No se pudo resolver business_id para order %', _order_id;
  end if;

  select * into fs from public.fiscal_settings where business_id = v_business_id;

  v_ncf_type := coalesce(
    fs.default_ncf_type,
    case
      when coalesce(fs.ecf_enabled, false) then 'E32'::public.ncf_type
      else 'B02'::public.ncf_type
    end
  );

  ncf := public.generate_ncf(v_business_id, v_ncf_type);

  insert into public.fiscal_documents (
    business_id, order_id, payment_id,
    ncf_type, ncf_number,
    customer_name,
    subtotal, itbis_amount, total,
    is_electronic
  ) values (
    v_business_id, o.id, _payment_id,
    v_ncf_type, ncf,
    'Consumidor Final',
    o.subtotal, o.tax, o.total,
    coalesce(fs.ecf_enabled, false)
  )
  returning id into doc_id;

  return doc_id;
end;
$$;


ALTER FUNCTION "public"."issue_fiscal_document"("_order_id" "uuid", "_payment_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_employees_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  new.updated_at = now();
  return new;
end;
$$;


ALTER FUNCTION "public"."set_employees_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_table_session_business_id"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  NEW.business_id := (
    SELECT z.business_id 
    FROM public.dining_tables dt
    JOIN public.zones z ON dt.zone_id = z.id
    WHERE dt.id = NEW.table_id
  );
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."set_table_session_business_id"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."set_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trigger_create_business_defaults"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  PERFORM public.create_business_defaults(NEW.id);
  
  -- Agregar owner a user_businesses
  INSERT INTO public.user_businesses (user_id, business_id, role)
  VALUES (NEW.owner_id, NEW.id, 'owner');
  
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trigger_create_business_defaults"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trigger_increment_coupon_usage"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  UPDATE public.coupons
  SET times_used = times_used + 1
  WHERE id = NEW.coupon_id;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trigger_increment_coupon_usage"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trigger_inventory_on_order_sent"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  IF NEW.status_ext = 'sent_to_kitchen'
     AND OLD.status_ext IS DISTINCT FROM 'sent_to_kitchen' THEN
    PERFORM public.consume_inventory_from_order(NEW.id);
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trigger_inventory_on_order_sent"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trigger_issue_fiscal_on_payment"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  IF NEW.status = 'completed' THEN
    PERFORM public.issue_fiscal_document(NEW.order_id, NEW.id);
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trigger_issue_fiscal_on_payment"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trigger_set_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trigger_set_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trigger_update_order_totals"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    PERFORM public.calculate_order_totals(OLD.order_id);
    IF OLD.check_id IS NOT NULL THEN
      PERFORM public.calculate_check_totals(OLD.check_id);
    END IF;
    RETURN OLD;
  ELSE
    PERFORM public.calculate_order_totals(NEW.order_id);
    IF NEW.check_id IS NOT NULL THEN
      PERFORM public.calculate_check_totals(NEW.check_id);
    END IF;
    RETURN NEW;
  END IF;
END;
$$;


ALTER FUNCTION "public"."trigger_update_order_totals"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."user_business_role"("_user_id" "uuid", "_business_id" "uuid") RETURNS "text"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  SELECT COALESCE(
    (SELECT role FROM public.user_businesses 
     WHERE user_id = _user_id AND business_id = _business_id),
    (SELECT 'owner' FROM public.businesses 
     WHERE id = _business_id AND owner_id = _user_id)
  )
$$;


ALTER FUNCTION "public"."user_business_role"("_user_id" "uuid", "_business_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."user_has_business_access"("_user_id" "uuid", "_business_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.user_businesses
    WHERE user_id = _user_id 
    AND business_id = _business_id
  ) OR EXISTS (
    SELECT 1 FROM public.businesses
    WHERE id = _business_id 
    AND owner_id = _user_id
  )
$$;


ALTER FUNCTION "public"."user_has_business_access"("_user_id" "uuid", "_business_id" "uuid") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."agent_nodes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "business_id" "uuid" NOT NULL,
    "site_code" "text" NOT NULL,
    "name" "text",
    "api_key_hash" "text" NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "last_seen" timestamp with time zone
);


ALTER TABLE "public"."agent_nodes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."attendance" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "business_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "shift_id" "uuid",
    "clock_in" timestamp with time zone NOT NULL,
    "clock_out" timestamp with time zone,
    "break_minutes" integer DEFAULT 0,
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."attendance" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."audit_logs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "business_id" "uuid" NOT NULL,
    "user_id" "uuid",
    "action" "text" NOT NULL,
    "reason" "text",
    "ref_table" "text",
    "ref_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."audit_logs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."business_settings" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "business_id" "uuid" NOT NULL,
    "timezone" "text" DEFAULT 'America/Santo_Domingo'::"text",
    "language" "text" DEFAULT 'es'::"text",
    "date_format" "text" DEFAULT 'DD/MM/YYYY'::"text",
    "default_tax_rate" numeric DEFAULT 18,
    "auto_print_order" boolean DEFAULT true,
    "auto_print_receipt" boolean DEFAULT true,
    "require_customer" boolean DEFAULT false,
    "allow_negative_stock" boolean DEFAULT false,
    "service_fee_enabled" boolean DEFAULT false,
    "service_fee_rate" numeric DEFAULT 10,
    "tip_enabled" boolean DEFAULT true,
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."business_settings" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."businesses" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "owner_id" "uuid" NOT NULL,
    "business_name" "text" NOT NULL,
    "branch_name" "text",
    "business_type" "text",
    "country" "text",
    "address" "text",
    "phone" "text",
    "status" "text" DEFAULT 'active'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "domain" "text" NOT NULL,
    CONSTRAINT "businesses_business_type_check" CHECK ((("business_type" IS NULL) OR ("business_type" = ANY (ARRAY['Restaurante'::"text", 'Comida Rapida'::"text", 'Cafeteria / Panaderia'::"text", 'Bar / Lounge'::"text", 'Heladeria / Postres'::"text", 'Solo Delivery'::"text", 'Tienda de Conveniencia'::"text", 'Bar de Jugos / Comida Saludable'::"text", 'Food Truck'::"text", 'Otro'::"text"])))),
    CONSTRAINT "businesses_domain_format" CHECK (("domain" ~ '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*\.mangopos\.do$'::"text")),
    CONSTRAINT "businesses_status_check" CHECK (("status" = ANY (ARRAY['active'::"text", 'inactive'::"text"])))
);


ALTER TABLE "public"."businesses" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."cash_register_sessions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "cash_register_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "opened_at" timestamp with time zone DEFAULT "now"(),
    "closed_at" timestamp with time zone,
    "start_amount" numeric(15,2) DEFAULT 0.00,
    "end_amount" numeric(15,2),
    "difference" numeric(15,2) DEFAULT 0.00,
    "status" "text" DEFAULT 'open'::"text",
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."cash_register_sessions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."cash_registers" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "business_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "is_active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."cash_registers" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."cash_transactions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "session_id" "uuid" NOT NULL,
    "amount" numeric(15,2) NOT NULL,
    "type" "text" NOT NULL,
    "description" "text",
    "related_order_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."cash_transactions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."categories" (
    "id" "uuid" NOT NULL,
    "business_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "position" integer DEFAULT 0 NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."categories" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."coupon_usage" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "coupon_id" "uuid" NOT NULL,
    "order_id" "uuid",
    "customer_id" "uuid",
    "discount_applied" numeric NOT NULL,
    "used_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."coupon_usage" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."coupons" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "business_id" "uuid" NOT NULL,
    "code" "text" NOT NULL,
    "promotion_id" "uuid",
    "discount_type" "text",
    "discount_value" numeric,
    "usage_limit" integer,
    "times_used" integer DEFAULT 0,
    "min_purchase" numeric DEFAULT 0,
    "valid_from" timestamp with time zone,
    "valid_until" timestamp with time zone,
    "is_active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "coupons_discount_type_check" CHECK (("discount_type" = ANY (ARRAY['percentage'::"text", 'fixed'::"text"])))
);


ALTER TABLE "public"."coupons" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."credit_payments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "credit_id" "uuid" NOT NULL,
    "amount" numeric NOT NULL,
    "payment_method_id" "uuid",
    "reference" "text",
    "received_by" "uuid",
    "session_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."credit_payments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."currencies" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "business_id" "uuid" NOT NULL,
    "code" "text" NOT NULL,
    "name" "text" NOT NULL,
    "symbol" "text" NOT NULL,
    "exchange_rate" numeric DEFAULT 1,
    "is_default" boolean DEFAULT false,
    "is_active" boolean DEFAULT true
);


ALTER TABLE "public"."currencies" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."customer_credits" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "business_id" "uuid" NOT NULL,
    "customer_id" "uuid" NOT NULL,
    "order_id" "uuid",
    "fiscal_document_id" "uuid",
    "original_amount" numeric NOT NULL,
    "balance" numeric NOT NULL,
    "due_date" "date",
    "status" "text" DEFAULT 'pending'::"text",
    "notes" "text",
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "customer_credits_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'partial'::"text", 'paid'::"text", 'overdue'::"text", 'cancelled'::"text"])))
);


ALTER TABLE "public"."customer_credits" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."customer_points" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "customer_id" "uuid" NOT NULL,
    "program_id" "uuid" NOT NULL,
    "points_balance" numeric DEFAULT 0,
    "total_earned" numeric DEFAULT 0,
    "total_redeemed" numeric DEFAULT 0,
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."customer_points" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."customers" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "business_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "phone" "text",
    "email" "text",
    "address" "text",
    "tax_id" "text",
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."customers" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."dining_tables" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "zone_id" "uuid" NOT NULL,
    "code" "text" NOT NULL,
    "label" "text",
    "shape" "public"."table_shape" DEFAULT 'square'::"public"."table_shape" NOT NULL,
    "capacity" integer DEFAULT 4 NOT NULL,
    "pos_x" numeric DEFAULT 0 NOT NULL,
    "pos_y" numeric DEFAULT 0 NOT NULL,
    "width" numeric DEFAULT 1 NOT NULL,
    "height" numeric DEFAULT 1 NOT NULL,
    "rotation" numeric DEFAULT 0 NOT NULL,
    "state" "public"."table_state" DEFAULT 'available'::"public"."table_state" NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."dining_tables" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."discovery_jobs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "business_id" "uuid" NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "platform" "text",
    "requested_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "started_at" timestamp with time zone,
    "finished_at" timestamp with time zone,
    "error" "text",
    "site_code" "text",
    "claimed_by" "uuid"
);

ALTER TABLE ONLY "public"."discovery_jobs" REPLICA IDENTITY FULL;


ALTER TABLE "public"."discovery_jobs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."employee_benefits" (
    "employee_id" "uuid" NOT NULL,
    "benefit" "text" NOT NULL
);


ALTER TABLE "public"."employee_benefits" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."employee_roles" (
    "employee_id" "uuid" NOT NULL,
    "role_id" "uuid" NOT NULL
);


ALTER TABLE "public"."employee_roles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."employees" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "business_id" "uuid" NOT NULL,
    "user_id" "uuid",
    "first_name" "text" NOT NULL,
    "last_name" "text" NOT NULL,
    "email" "text" NOT NULL,
    "phone" "text" NOT NULL,
    "national_id" "text",
    "gender" "text",
    "address" "text",
    "status" "text" DEFAULT 'active'::"text" NOT NULL,
    "hire_date" "date",
    "contract_type" "text",
    "department" "text",
    "position" "text",
    "work_schedule" "text",
    "salary_base" numeric(15,2),
    "pay_frequency" "text",
    "afp" "text",
    "ars" "text",
    "bank_name" "text",
    "bank_account" "text",
    "pin" "text",
    "emergency_name" "text",
    "emergency_relation" "text",
    "emergency_phone" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "employees_status_check" CHECK (("status" = ANY (ARRAY['active'::"text", 'inactive'::"text", 'password_reset'::"text"])))
);


ALTER TABLE "public"."employees" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."fiscal_document_items" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "document_id" "uuid" NOT NULL,
    "order_item_id" "uuid",
    "product_name" "text" NOT NULL,
    "quantity" numeric NOT NULL,
    "unit_price" numeric NOT NULL,
    "discount" numeric DEFAULT 0,
    "is_tax_exempt" boolean DEFAULT false,
    "tax_rate" numeric DEFAULT 18,
    "tax_amount" numeric DEFAULT 0,
    "total" numeric NOT NULL
);


ALTER TABLE "public"."fiscal_document_items" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."fiscal_settings" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "business_id" "uuid" NOT NULL,
    "rnc" "text" NOT NULL,
    "business_legal_name" "text" NOT NULL,
    "establishment_number" "text",
    "ecf_enabled" boolean DEFAULT false,
    "ecf_certificate_path" "text",
    "ecf_certificate_password_hash" "text",
    "ecf_environment" "text" DEFAULT 'test'::"text",
    "default_ncf_type" "public"."ncf_type" DEFAULT 'B02'::"public"."ncf_type",
    "auto_print_fiscal" boolean DEFAULT true,
    "updated_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "fiscal_settings_ecf_environment_check" CHECK (("ecf_environment" = ANY (ARRAY['test'::"text", 'production'::"text"])))
);


ALTER TABLE "public"."fiscal_settings" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."gift_card_transactions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "gift_card_id" "uuid" NOT NULL,
    "order_id" "uuid",
    "amount" numeric NOT NULL,
    "balance_after" numeric NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."gift_card_transactions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."gift_cards" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "business_id" "uuid" NOT NULL,
    "code" "text" NOT NULL,
    "initial_balance" numeric NOT NULL,
    "current_balance" numeric NOT NULL,
    "customer_id" "uuid",
    "expires_at" "date",
    "is_active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."gift_cards" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."inventory_items" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "business_id" "uuid" NOT NULL,
    "sku" "text",
    "name" "text" NOT NULL,
    "description" "text",
    "unit" "text" DEFAULT 'unidad'::"text",
    "cost" numeric DEFAULT 0,
    "min_stock" numeric DEFAULT 0,
    "max_stock" numeric,
    "is_active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."inventory_items" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."inventory_movements" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "business_id" "uuid" NOT NULL,
    "warehouse_id" "uuid" NOT NULL,
    "item_id" "uuid" NOT NULL,
    "movement_type" "public"."movement_type" NOT NULL,
    "quantity" numeric NOT NULL,
    "cost_per_unit" numeric,
    "reference_id" "uuid",
    "reference_type" "text",
    "notes" "text",
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."inventory_movements" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."inventory_stock" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "warehouse_id" "uuid" NOT NULL,
    "item_id" "uuid" NOT NULL,
    "quantity" numeric DEFAULT 0,
    "last_updated" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."inventory_stock" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."order_item_modifiers" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "item_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "qty" numeric(10,3) DEFAULT 1 NOT NULL,
    "price" numeric(12,2) DEFAULT 0 NOT NULL
);


ALTER TABLE "public"."order_item_modifiers" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."order_items" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "order_id" "uuid",
    "product_id" "uuid",
    "quantity" integer DEFAULT 1 NOT NULL,
    "unit_price" numeric(10,2) NOT NULL,
    "total" numeric(10,2) GENERATED ALWAYS AS ((("quantity")::numeric * "unit_price")) STORED,
    "check_id" "uuid",
    "product_name" "text",
    "sku" "text",
    "qty" numeric(10,3) DEFAULT 1,
    "is_takeout" boolean DEFAULT false NOT NULL,
    "status" "public"."item_status" DEFAULT 'draft'::"public"."item_status",
    "notes" "text",
    "subtotal" numeric(12,2) DEFAULT 0,
    "discounts" numeric(12,2) DEFAULT 0,
    "tax" numeric(12,2) DEFAULT 0,
    "tax_mode" "text" DEFAULT 'exclusive'::"text" NOT NULL,
    "tax_rate" numeric DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "started_at" timestamp with time zone,
    "ready_at" timestamp with time zone,
    CONSTRAINT "order_items_tax_mode_check" CHECK (("tax_mode" = ANY (ARRAY['exclusive'::"text", 'inclusive'::"text"])))
);


ALTER TABLE "public"."order_items" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."orders" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "session_id" "uuid" NOT NULL,
    "status" "text" DEFAULT 'open'::"text" NOT NULL,
    "total_amount" numeric(12,2) DEFAULT 0,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "status_ext" "public"."order_status" DEFAULT 'open'::"public"."order_status" NOT NULL,
    "subtotal" numeric(12,2) DEFAULT 0 NOT NULL,
    "discounts" numeric(12,2) DEFAULT 0 NOT NULL,
    "service_fee" numeric(12,2) DEFAULT 0 NOT NULL,
    "tax" numeric(12,2) DEFAULT 0 NOT NULL,
    "total" numeric(12,2) DEFAULT 0 NOT NULL,
    "closed_at" timestamp with time zone,
    CONSTRAINT "orders_status_check" CHECK (("status" = ANY (ARRAY['open'::"text", 'sent'::"text", 'served'::"text", 'canceled'::"text", 'paid'::"text"])))
);


ALTER TABLE "public"."orders" OWNER TO "postgres";


COMMENT ON COLUMN "public"."orders"."closed_at" IS 'Timestamp when the order was closed (paid or voided)';



CREATE TABLE IF NOT EXISTS "public"."profiles" (
    "id" "uuid" NOT NULL,
    "email" "text" NOT NULL,
    "full_name" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."profiles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."table_sessions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "table_id" "uuid" NOT NULL,
    "opened_by" "uuid" NOT NULL,
    "opened_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "closed_at" timestamp with time zone,
    "customer_name" "text",
    "note" "text",
    "origin" "public"."order_origin" DEFAULT 'dine_in'::"public"."order_origin" NOT NULL,
    "waiter_user_id" "uuid",
    "people_count" integer DEFAULT 1 NOT NULL,
    "business_id" "uuid"
);


ALTER TABLE "public"."table_sessions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."zones" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "business_id" "uuid" NOT NULL,
    "branch_id" "uuid",
    "name" "text" NOT NULL,
    "sort_index" integer DEFAULT 0 NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."zones" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."kds_active_items" WITH ("security_invoker"='on') AS
 SELECT "oi"."id",
    "oi"."order_id",
    "left"(("oi"."order_id")::"text", 8) AS "order_number",
    "oi"."product_name",
    COALESCE(("oi"."quantity")::numeric, "oi"."qty", (1)::numeric) AS "quantity",
    "oi"."notes",
    "oi"."status",
    "oi"."created_at",
    "oi"."started_at",
    "oi"."ready_at",
        CASE
            WHEN ("dt"."id" IS NOT NULL) THEN COALESCE("dt"."label", "dt"."code", 'Mesa'::"text")
            WHEN ("ts"."origin" = 'manual'::"public"."order_origin") THEN 'Venta manual'::"text"
            WHEN ("ts"."origin" = 'quick'::"public"."order_origin") THEN 'Venta rapida'::"text"
            ELSE 'Venta'::"text"
        END AS "table_name",
    "p"."full_name" AS "waiter_name",
    "z"."business_id",
    NULL::"text" AS "area_code",
    COALESCE("mods"."modifiers", '[]'::json) AS "modifiers"
   FROM (((((("public"."order_items" "oi"
     JOIN "public"."orders" "o" ON (("o"."id" = "oi"."order_id")))
     JOIN "public"."table_sessions" "ts" ON (("ts"."id" = "o"."session_id")))
     LEFT JOIN "public"."dining_tables" "dt" ON (("dt"."id" = "ts"."table_id")))
     LEFT JOIN "public"."zones" "z" ON (("z"."id" = "dt"."zone_id")))
     LEFT JOIN "public"."profiles" "p" ON (("p"."id" = "ts"."waiter_user_id")))
     LEFT JOIN LATERAL ( SELECT "json_agg"("json_build_object"('id', "m"."id", 'name', "m"."name", 'quantity', "m"."qty")) AS "modifiers"
           FROM "public"."order_item_modifiers" "m"
          WHERE ("m"."item_id" = "oi"."id")) "mods" ON (true))
  WHERE ("oi"."status" = ANY (ARRAY['pending'::"public"."item_status", 'preparing'::"public"."item_status", 'ready'::"public"."item_status"]));


ALTER VIEW "public"."kds_active_items" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."loyalty_programs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "business_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "points_per_currency" numeric DEFAULT 1,
    "points_value" numeric DEFAULT 0.01,
    "is_active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."loyalty_programs" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."me_permissions" WITH ("security_invoker"='on') AS
 SELECT "code",
    "allowed"
   FROM "public"."fn_user_effective_permissions"("auth"."uid"(), ("current_setting"('app.current_business'::"text", true))::"uuid") "fn_user_effective_permissions"("code", "allowed");


ALTER VIEW "public"."me_permissions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."memberships" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "business_id" "uuid" NOT NULL,
    "plan_type" "text" DEFAULT 'trial'::"text" NOT NULL,
    "status" "text" DEFAULT 'active'::"text" NOT NULL,
    "start_date" timestamp with time zone DEFAULT "now"() NOT NULL,
    "end_date" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "role" "public"."member_role" DEFAULT 'staff'::"public"."member_role" NOT NULL,
    CONSTRAINT "memberships_plan_type_check" CHECK (("plan_type" = ANY (ARRAY['trial'::"text", 'free'::"text", 'basic'::"text", 'pro'::"text"]))),
    CONSTRAINT "memberships_status_check" CHECK (("status" = ANY (ARRAY['active'::"text", 'canceled'::"text", 'expired'::"text"])))
);


ALTER TABLE "public"."memberships" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."menu_item_groups" (
    "menu_item_id" "uuid" NOT NULL,
    "group_id" "uuid" NOT NULL
);


ALTER TABLE "public"."menu_item_groups" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."menu_item_links" (
    "menu_id" "uuid" NOT NULL,
    "item_id" "uuid" NOT NULL,
    "position" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."menu_item_links" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."menu_item_taxes" (
    "item_id" "uuid" NOT NULL,
    "tax_id" "uuid" NOT NULL
);


ALTER TABLE "public"."menu_item_taxes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."menu_items" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "business_id" "uuid" NOT NULL,
    "category_id" "uuid",
    "name" "text" NOT NULL,
    "price" numeric(12,2) DEFAULT 0 NOT NULL,
    "tax_mode" "text" DEFAULT 'exclusive'::"text" NOT NULL,
    "sku" "text",
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "description" "text",
    "prep_minutes" integer DEFAULT 0 NOT NULL,
    "image_url" "text",
    "has_variants" boolean DEFAULT false NOT NULL,
    "has_prep" boolean DEFAULT false NOT NULL,
    "image_path" "text",
    "contains_egg" boolean DEFAULT false NOT NULL,
    "is_beverage" boolean DEFAULT false NOT NULL,
    "dietary" "public"."dietary_type" DEFAULT 'unspecified'::"public"."dietary_type" NOT NULL,
    "sold_by" "public"."sold_by_type" DEFAULT 'unit'::"public"."sold_by_type" NOT NULL,
    "cost" numeric,
    "barcode" "text",
    "updated_at" timestamp with time zone,
    "position" integer DEFAULT 0,
    CONSTRAINT "menu_items_tax_mode_check" CHECK (("tax_mode" = ANY (ARRAY['exclusive'::"text", 'inclusive'::"text"])))
);


ALTER TABLE "public"."menu_items" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."menus" (
    "id" "uuid" NOT NULL,
    "business_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."menus" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."modifier_groups" (
    "id" "uuid" NOT NULL,
    "business_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "min_select" integer DEFAULT 0 NOT NULL,
    "max_select" integer DEFAULT 0 NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."modifier_groups" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."modifiers" (
    "id" "uuid" NOT NULL,
    "business_id" "uuid" NOT NULL,
    "group_id" "uuid",
    "name" "text" NOT NULL,
    "price_delta" numeric(12,2) DEFAULT 0 NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."modifiers" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ncf_sequences" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "business_id" "uuid" NOT NULL,
    "ncf_type" "public"."ncf_type" NOT NULL,
    "serie" "text" NOT NULL,
    "prefix" "text" NOT NULL,
    "range_start" bigint NOT NULL,
    "range_end" bigint NOT NULL,
    "current_number" bigint NOT NULL,
    "expiration_date" "date",
    "is_active" boolean DEFAULT true,
    "authorized_by" "text",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."ncf_sequences" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."payment_methods" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "business_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "code" "text" NOT NULL,
    "is_active" boolean DEFAULT true,
    "requires_reference" boolean DEFAULT false,
    "icon" "text",
    "position" integer DEFAULT 0,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."payment_methods" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."permissions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "code" "text" NOT NULL,
    "name" "text" NOT NULL,
    "module" "text" NOT NULL,
    "description" "text",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."permissions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."point_transactions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "customer_points_id" "uuid" NOT NULL,
    "order_id" "uuid",
    "points" numeric NOT NULL,
    "description" "text",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."point_transactions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."print_area_printers" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "business_id" "uuid" NOT NULL,
    "area_id" "uuid" NOT NULL,
    "printer_id" "uuid" NOT NULL,
    "priority" integer DEFAULT 1 NOT NULL,
    "enabled" boolean DEFAULT true NOT NULL,
    "prints_orders" boolean DEFAULT true NOT NULL,
    "prints_prebills" boolean DEFAULT false NOT NULL,
    "prints_receipts" boolean DEFAULT false NOT NULL
);


ALTER TABLE "public"."print_area_printers" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."print_areas" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "business_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "code" "text" NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."print_areas" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."print_areas_view" WITH ("security_invoker"='on') AS
 SELECT "id",
    "business_id",
    "name",
    "code",
    "is_active",
    "created_at",
    0 AS "products_count"
   FROM "public"."print_areas" "a";


ALTER VIEW "public"."print_areas_view" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."print_jobs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "business_id" "uuid" NOT NULL,
    "data_hex" "text",
    "ip" "text" NOT NULL,
    "port" integer DEFAULT 9100 NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "error" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "printed_at" timestamp with time zone
);


ALTER TABLE "public"."print_jobs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."printers" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "business_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "ip_address" "text",
    "port" integer,
    "device_path" "text",
    "ip" "inet",
    "mac" "text",
    "type" "public"."printer_type" DEFAULT 'network'::"public"."printer_type" NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "paper_width" integer DEFAULT 80,
    "encoding" "text" DEFAULT 'CP437'::"text",
    "online" boolean DEFAULT false NOT NULL,
    "last_seen" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);

ALTER TABLE ONLY "public"."printers" REPLICA IDENTITY FULL;


ALTER TABLE "public"."printers" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."promotions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "business_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "discount_type" "text",
    "discount_value" numeric,
    "min_purchase" numeric DEFAULT 0,
    "applies_to" "text" DEFAULT 'all'::"text",
    "target_ids" "uuid"[],
    "start_date" timestamp with time zone,
    "end_date" timestamp with time zone,
    "days_of_week" integer[],
    "is_active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "promotions_applies_to_check" CHECK (("applies_to" = ANY (ARRAY['all'::"text", 'category'::"text", 'product'::"text"]))),
    CONSTRAINT "promotions_discount_type_check" CHECK (("discount_type" = ANY (ARRAY['percentage'::"text", 'fixed'::"text", 'bogo'::"text"])))
);


ALTER TABLE "public"."promotions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."purchase_order_items" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "purchase_order_id" "uuid" NOT NULL,
    "inventory_item_id" "uuid",
    "description" "text",
    "quantity_ordered" numeric NOT NULL,
    "quantity_received" numeric DEFAULT 0,
    "unit_cost" numeric NOT NULL,
    "tax_rate" numeric DEFAULT 18,
    "total" numeric NOT NULL
);


ALTER TABLE "public"."purchase_order_items" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."purchase_orders" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "business_id" "uuid" NOT NULL,
    "supplier_id" "uuid",
    "warehouse_id" "uuid",
    "order_number" "text" NOT NULL,
    "status" "public"."purchase_status" DEFAULT 'draft'::"public"."purchase_status",
    "subtotal" numeric DEFAULT 0,
    "tax" numeric DEFAULT 0,
    "total" numeric DEFAULT 0,
    "notes" "text",
    "expected_date" "date",
    "received_date" "date",
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."purchase_orders" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."recipe_ingredients" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "recipe_id" "uuid" NOT NULL,
    "inventory_item_id" "uuid" NOT NULL,
    "quantity" numeric NOT NULL,
    "unit" "text" NOT NULL
);


ALTER TABLE "public"."recipe_ingredients" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."recipes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "menu_item_id" "uuid" NOT NULL,
    "yield_quantity" numeric DEFAULT 1,
    "instructions" "text",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."recipes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."role_permissions" (
    "role_id" "uuid" NOT NULL,
    "permission_id" "uuid" NOT NULL,
    "allow" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."role_permissions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."roles" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "business_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "is_system" boolean DEFAULT false,
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."roles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."shifts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "business_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "start_time" time without time zone NOT NULL,
    "end_time" time without time zone NOT NULL,
    "days_of_week" integer[] DEFAULT ARRAY[1, 2, 3, 4, 5],
    "is_active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."shifts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."suppliers" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "business_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "rnc" "text",
    "contact_name" "text",
    "phone" "text",
    "email" "text",
    "address" "text",
    "payment_terms" "text",
    "notes" "text",
    "is_active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."suppliers" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."taxes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "business_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "rate" numeric NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "taxes_rate_check" CHECK ((("rate" >= (0)::numeric) AND ("rate" <= (100)::numeric)))
);


ALTER TABLE "public"."taxes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_businesses" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "business_id" "uuid" NOT NULL,
    "role" "text" DEFAULT 'owner'::"text" NOT NULL,
    "permissions" "text"[] DEFAULT ARRAY['all'::"text"] NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "user_businesses_role_check" CHECK (("role" = ANY (ARRAY['owner'::"text", 'admin'::"text", 'manager'::"text", 'cashier'::"text", 'waiter'::"text", 'cook'::"text", 'chef'::"text", 'delivery'::"text"])))
);


ALTER TABLE "public"."user_businesses" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_permission_overrides" (
    "user_id" "uuid" NOT NULL,
    "permission_id" "uuid" NOT NULL,
    "business_id" "uuid" NOT NULL,
    "allow" boolean NOT NULL,
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."user_permission_overrides" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_roles" (
    "user_id" "uuid" NOT NULL,
    "role_id" "uuid" NOT NULL,
    "business_id" "uuid" NOT NULL,
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."user_roles" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_employees_summary" AS
SELECT
    NULL::"uuid" AS "id",
    NULL::"uuid" AS "business_id",
    NULL::"text" AS "first_name",
    NULL::"text" AS "last_name",
    NULL::"text" AS "email",
    NULL::"text" AS "phone",
    NULL::"text" AS "department",
    NULL::"text" AS "position",
    NULL::numeric(15,2) AS "salary_base",
    NULL::"text" AS "pay_frequency",
    NULL::"text" AS "status",
    NULL::"text"[] AS "roles";


ALTER VIEW "public"."v_employees_summary" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_kitchen_items" WITH ("security_invoker"='on') AS
 SELECT "oi"."id",
    "oi"."order_id",
    "oi"."product_id",
    "mi"."name" AS "product_name",
    "oi"."qty",
    "oi"."status",
    "oi"."notes",
    "oi"."created_at",
    COALESCE("z"."business_id", "mi"."business_id") AS "business_id",
    "dt"."label" AS "table_name",
    "z"."name" AS "zone_name"
   FROM ((((("public"."order_items" "oi"
     JOIN "public"."orders" "o" ON (("oi"."order_id" = "o"."id")))
     LEFT JOIN "public"."menu_items" "mi" ON (("oi"."product_id" = "mi"."id")))
     LEFT JOIN "public"."table_sessions" "ts" ON (("o"."session_id" = "ts"."id")))
     LEFT JOIN "public"."dining_tables" "dt" ON (("ts"."table_id" = "dt"."id")))
     LEFT JOIN "public"."zones" "z" ON (("dt"."zone_id" = "z"."id")));


ALTER VIEW "public"."v_kitchen_items" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_menu_items_list" WITH ("security_invoker"='on') AS
 SELECT "i"."id",
    "i"."business_id",
    "i"."name",
    "i"."description",
    "i"."category_id",
    "c"."name" AS "category_name",
    "i"."price",
    "i"."sku",
    "i"."prep_minutes",
    "i"."has_variants",
    "i"."is_active",
    "i"."image_url",
    "i"."created_at",
    "l"."menu_id",
    "m"."name" AS "menu_name",
    "l"."position",
    "i"."tax_mode",
    COALESCE(( SELECT sum("t"."rate") AS "sum"
           FROM ("public"."menu_item_taxes" "mit"
             JOIN "public"."taxes" "t" ON (("t"."id" = "mit"."tax_id")))
          WHERE (("mit"."item_id" = "i"."id") AND COALESCE("t"."is_active", true))), (0)::numeric) AS "effective_tax_rate"
   FROM ((("public"."menu_items" "i"
     LEFT JOIN LATERAL ( SELECT "l1"."menu_id",
            "l1"."position"
           FROM "public"."menu_item_links" "l1"
          WHERE ("l1"."item_id" = "i"."id")
          ORDER BY "l1"."position"
         LIMIT 1) "l" ON (true))
     LEFT JOIN "public"."menus" "m" ON (("m"."id" = "l"."menu_id")))
     LEFT JOIN "public"."categories" "c" ON (("c"."id" = "i"."category_id")));


ALTER VIEW "public"."v_menu_items_list" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_menus_with_counts" WITH ("security_invoker"='on') AS
 SELECT "id",
    "business_id",
    "name",
    "is_active",
    "created_at",
    ( SELECT ("count"(*))::integer AS "count"
           FROM ("public"."menu_item_links" "mil"
             JOIN "public"."menu_items" "mi" ON (("mi"."id" = "mil"."item_id")))
          WHERE ("mil"."menu_id" = "m"."id")) AS "items_count"
   FROM "public"."menus" "m";


ALTER VIEW "public"."v_menus_with_counts" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_order_detail" WITH ("security_invoker"='on') AS
 SELECT "o"."id" AS "order_id",
    "oc"."id" AS "check_id",
    "oc"."position" AS "check_pos",
    "oc"."label" AS "check_label",
    "oi"."id" AS "item_id",
    "oi"."product_id",
    "oi"."product_name",
    "oi"."qty",
    "oi"."unit_price",
    "oi"."is_takeout",
    "oi"."status",
    "oi"."notes",
    "oi"."subtotal",
    "oi"."discounts",
    "oi"."tax",
    "oi"."total",
    "o"."subtotal" AS "order_subtotal",
    "o"."discounts" AS "order_discounts",
    "o"."tax" AS "order_tax",
    "o"."total" AS "order_total",
    "o"."status_ext"
   FROM (("public"."orders" "o"
     LEFT JOIN "public"."order_checks" "oc" ON (("oc"."order_id" = "o"."id")))
     LEFT JOIN "public"."order_items" "oi" ON ((("oi"."order_id" = "o"."id") AND ("oi"."check_id" = "oc"."id"))));


ALTER VIEW "public"."v_order_detail" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_zone_table_status" WITH ("security_invoker"='on') AS
 SELECT "t"."id" AS "table_id",
    "z"."id" AS "zone_id",
    "z"."name" AS "zone_name",
    "z"."business_id",
    "t"."code",
    "t"."label",
    "t"."shape",
    "t"."capacity",
    "t"."state",
    "s"."id" AS "session_id",
    "s"."opened_by",
    "s"."opened_at",
        CASE
            WHEN (("s"."opened_at" IS NOT NULL) AND ("s"."closed_at" IS NULL)) THEN ((EXTRACT(epoch FROM ("now"() - "s"."opened_at")))::integer / 60)
            ELSE NULL::integer
        END AS "minutes_open",
    COALESCE(( SELECT "count"(*) AS "count"
           FROM "public"."orders" "o"
          WHERE (("o"."session_id" = "s"."id") AND ("o"."closed_at" IS NULL) AND ("o"."status_ext" <> ALL (ARRAY['paid'::"public"."order_status", 'void'::"public"."order_status"])))), (0)::bigint) AS "orders_count",
    "s"."people_count",
    COALESCE(( SELECT "sum"("o"."total") AS "sum"
           FROM "public"."orders" "o"
          WHERE (("o"."session_id" = "s"."id") AND ("o"."closed_at" IS NULL) AND ("o"."status_ext" <> ALL (ARRAY['paid'::"public"."order_status", 'void'::"public"."order_status"])))), (0)::numeric) AS "total",
    COALESCE(( SELECT "count"(*) AS "count"
           FROM "public"."order_items" "oi"
          WHERE ("oi"."order_id" IN ( SELECT "o2"."id"
                   FROM "public"."orders" "o2"
                  WHERE (("o2"."session_id" = "s"."id") AND ("o2"."closed_at" IS NULL) AND ("o2"."status_ext" <> ALL (ARRAY['paid'::"public"."order_status", 'void'::"public"."order_status"])))))), (0)::bigint) AS "items_count"
   FROM (("public"."dining_tables" "t"
     JOIN "public"."zones" "z" ON (("z"."id" = "t"."zone_id")))
     LEFT JOIN LATERAL ( SELECT "s2"."id",
            "s2"."table_id",
            "s2"."opened_by",
            "s2"."opened_at",
            "s2"."closed_at",
            "s2"."customer_name",
            "s2"."note",
            "s2"."origin",
            "s2"."waiter_user_id",
            "s2"."people_count",
            "s2"."business_id"
           FROM "public"."table_sessions" "s2"
          WHERE (("s2"."table_id" = "t"."id") AND ("s2"."closed_at" IS NULL))
          ORDER BY "s2"."opened_at" DESC
         LIMIT 1) "s" ON (true));


ALTER VIEW "public"."v_zone_table_status" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_zone_table_status2" WITH ("security_invoker"='on') AS
 SELECT "t"."id" AS "table_id",
    "z"."id" AS "zone_id",
    "z"."name" AS "zone_name",
    "t"."code",
    "t"."label",
    "t"."state",
    "s"."id" AS "session_id",
    "s"."waiter_user_id",
    "s"."opened_at",
        CASE
            WHEN ("s"."closed_at" IS NULL) THEN ((EXTRACT(epoch FROM ("now"() - "s"."opened_at")))::integer / 60)
            ELSE NULL::integer
        END AS "minutes_open",
    ( SELECT "count"(*) AS "count"
           FROM "public"."orders" "o"
          WHERE (("o"."session_id" = "s"."id") AND ("o"."status_ext" = 'open'::"public"."order_status"))) AS "open_orders"
   FROM (("public"."dining_tables" "t"
     JOIN "public"."zones" "z" ON (("z"."id" = "t"."zone_id")))
     LEFT JOIN LATERAL ( SELECT "s2"."id",
            "s2"."table_id",
            "s2"."opened_by",
            "s2"."opened_at",
            "s2"."closed_at",
            "s2"."customer_name",
            "s2"."note",
            "s2"."origin",
            "s2"."waiter_user_id",
            "s2"."people_count"
           FROM "public"."table_sessions" "s2"
          WHERE (("s2"."table_id" = "t"."id") AND ("s2"."closed_at" IS NULL))
          ORDER BY "s2"."opened_at" DESC
         LIMIT 1) "s" ON (true));


ALTER VIEW "public"."v_zone_table_status2" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."warehouses" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "business_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "address" "text",
    "is_main" boolean DEFAULT false,
    "is_active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."warehouses" OWNER TO "postgres";


ALTER TABLE ONLY "public"."agent_nodes"
    ADD CONSTRAINT "agent_nodes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."attendance"
    ADD CONSTRAINT "attendance_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."audit_logs"
    ADD CONSTRAINT "audit_logs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."business_settings"
    ADD CONSTRAINT "business_settings_business_id_key" UNIQUE ("business_id");



ALTER TABLE ONLY "public"."business_settings"
    ADD CONSTRAINT "business_settings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."businesses"
    ADD CONSTRAINT "businesses_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."cash_register_sessions"
    ADD CONSTRAINT "cash_register_sessions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."cash_registers"
    ADD CONSTRAINT "cash_registers_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."cash_transactions"
    ADD CONSTRAINT "cash_transactions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."categories"
    ADD CONSTRAINT "categories_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."coupon_usage"
    ADD CONSTRAINT "coupon_usage_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."coupons"
    ADD CONSTRAINT "coupons_business_id_code_key" UNIQUE ("business_id", "code");



ALTER TABLE ONLY "public"."coupons"
    ADD CONSTRAINT "coupons_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."credit_payments"
    ADD CONSTRAINT "credit_payments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."currencies"
    ADD CONSTRAINT "currencies_business_id_code_key" UNIQUE ("business_id", "code");



ALTER TABLE ONLY "public"."currencies"
    ADD CONSTRAINT "currencies_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."customer_credits"
    ADD CONSTRAINT "customer_credits_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."customer_points"
    ADD CONSTRAINT "customer_points_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."customers"
    ADD CONSTRAINT "customers_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."dining_tables"
    ADD CONSTRAINT "dining_tables_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."dining_tables"
    ADD CONSTRAINT "dining_tables_zone_id_code_key" UNIQUE ("zone_id", "code");



ALTER TABLE ONLY "public"."discovery_jobs"
    ADD CONSTRAINT "discovery_jobs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."employee_benefits"
    ADD CONSTRAINT "employee_benefits_pkey" PRIMARY KEY ("employee_id", "benefit");



ALTER TABLE ONLY "public"."employee_roles"
    ADD CONSTRAINT "employee_roles_pkey" PRIMARY KEY ("employee_id", "role_id");



ALTER TABLE ONLY "public"."employees"
    ADD CONSTRAINT "employees_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."fiscal_document_items"
    ADD CONSTRAINT "fiscal_document_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."fiscal_documents"
    ADD CONSTRAINT "fiscal_documents_ncf_number_key" UNIQUE ("ncf_number");



ALTER TABLE ONLY "public"."fiscal_documents"
    ADD CONSTRAINT "fiscal_documents_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."fiscal_settings"
    ADD CONSTRAINT "fiscal_settings_business_id_key" UNIQUE ("business_id");



ALTER TABLE ONLY "public"."fiscal_settings"
    ADD CONSTRAINT "fiscal_settings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."gift_card_transactions"
    ADD CONSTRAINT "gift_card_transactions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."gift_cards"
    ADD CONSTRAINT "gift_cards_code_key" UNIQUE ("code");



ALTER TABLE ONLY "public"."gift_cards"
    ADD CONSTRAINT "gift_cards_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."inventory_items"
    ADD CONSTRAINT "inventory_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."inventory_movements"
    ADD CONSTRAINT "inventory_movements_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."inventory_stock"
    ADD CONSTRAINT "inventory_stock_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."inventory_stock"
    ADD CONSTRAINT "inventory_stock_warehouse_id_item_id_key" UNIQUE ("warehouse_id", "item_id");



ALTER TABLE ONLY "public"."loyalty_programs"
    ADD CONSTRAINT "loyalty_programs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."memberships"
    ADD CONSTRAINT "memberships_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."menu_item_groups"
    ADD CONSTRAINT "menu_item_groups_pkey" PRIMARY KEY ("menu_item_id", "group_id");



ALTER TABLE ONLY "public"."menu_item_links"
    ADD CONSTRAINT "menu_item_links_pkey" PRIMARY KEY ("menu_id", "item_id");



ALTER TABLE ONLY "public"."menu_item_taxes"
    ADD CONSTRAINT "menu_item_taxes_pkey" PRIMARY KEY ("item_id", "tax_id");



ALTER TABLE ONLY "public"."menu_items"
    ADD CONSTRAINT "menu_items_pkey" PRIMARY KEY ("id");



ALTER TABLE "public"."menu_items"
    ADD CONSTRAINT "menu_items_prep_minutes_ck" CHECK (((("has_prep" = false) AND ("prep_minutes" = 0)) OR (("has_prep" = true) AND ("prep_minutes" >= 0)))) NOT VALID;



ALTER TABLE ONLY "public"."menus"
    ADD CONSTRAINT "menus_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."modifier_groups"
    ADD CONSTRAINT "modifier_groups_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."modifiers"
    ADD CONSTRAINT "modifiers_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ncf_sequences"
    ADD CONSTRAINT "ncf_sequences_business_id_ncf_type_serie_key" UNIQUE ("business_id", "ncf_type", "serie");



ALTER TABLE ONLY "public"."ncf_sequences"
    ADD CONSTRAINT "ncf_sequences_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."order_checks"
    ADD CONSTRAINT "order_checks_order_id_position_key" UNIQUE ("order_id", "position");



ALTER TABLE ONLY "public"."order_checks"
    ADD CONSTRAINT "order_checks_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."order_item_modifiers"
    ADD CONSTRAINT "order_item_modifiers_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."order_items"
    ADD CONSTRAINT "order_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."orders"
    ADD CONSTRAINT "orders_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."payment_methods"
    ADD CONSTRAINT "payment_methods_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."payments"
    ADD CONSTRAINT "payments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."permissions"
    ADD CONSTRAINT "permissions_code_key" UNIQUE ("code");



ALTER TABLE ONLY "public"."permissions"
    ADD CONSTRAINT "permissions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."point_transactions"
    ADD CONSTRAINT "point_transactions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."print_area_printers"
    ADD CONSTRAINT "print_area_printers_area_id_printer_id_key" UNIQUE ("area_id", "printer_id");



ALTER TABLE ONLY "public"."print_area_printers"
    ADD CONSTRAINT "print_area_printers_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."print_areas"
    ADD CONSTRAINT "print_areas_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."print_areas"
    ADD CONSTRAINT "print_areas_business_id_code_key" UNIQUE ("business_id", "code");



ALTER TABLE ONLY "public"."print_jobs"
    ADD CONSTRAINT "print_jobs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."printers"
    ADD CONSTRAINT "printers_business_ip_unique" UNIQUE ("business_id", "ip");



ALTER TABLE ONLY "public"."printers"
    ADD CONSTRAINT "printers_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_email_key" UNIQUE ("email");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."promotions"
    ADD CONSTRAINT "promotions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."purchase_order_items"
    ADD CONSTRAINT "purchase_order_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."purchase_orders"
    ADD CONSTRAINT "purchase_orders_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."recipe_ingredients"
    ADD CONSTRAINT "recipe_ingredients_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."recipes"
    ADD CONSTRAINT "recipes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."role_permissions"
    ADD CONSTRAINT "role_permissions_pkey" PRIMARY KEY ("role_id", "permission_id");



ALTER TABLE ONLY "public"."roles"
    ADD CONSTRAINT "roles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."shifts"
    ADD CONSTRAINT "shifts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."suppliers"
    ADD CONSTRAINT "suppliers_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."table_sessions"
    ADD CONSTRAINT "table_sessions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."taxes"
    ADD CONSTRAINT "taxes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_businesses"
    ADD CONSTRAINT "user_businesses_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_businesses"
    ADD CONSTRAINT "user_businesses_user_id_business_id_key" UNIQUE ("user_id", "business_id");



ALTER TABLE ONLY "public"."user_permission_overrides"
    ADD CONSTRAINT "user_permission_overrides_pkey" PRIMARY KEY ("user_id", "permission_id", "business_id");



ALTER TABLE ONLY "public"."user_roles"
    ADD CONSTRAINT "user_roles_pkey" PRIMARY KEY ("user_id", "role_id", "business_id");



ALTER TABLE ONLY "public"."warehouses"
    ADD CONSTRAINT "warehouses_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."zones"
    ADD CONSTRAINT "zones_pkey" PRIMARY KEY ("id");



CREATE UNIQUE INDEX "agent_nodes_business_id_site_code_idx" ON "public"."agent_nodes" USING "btree" ("business_id", "site_code");



CREATE INDEX "discovery_jobs_business_id_status_idx" ON "public"."discovery_jobs" USING "btree" ("business_id", "status");



CREATE INDEX "discovery_jobs_created_at_idx" ON "public"."discovery_jobs" USING "btree" ("created_at");



CREATE INDEX "idx_discovery_jobs_business_site" ON "public"."discovery_jobs" USING "btree" ("business_id", "site_code");



CREATE INDEX "idx_discovery_jobs_business_status_created" ON "public"."discovery_jobs" USING "btree" ("business_id", "status", "created_at");



CREATE INDEX "idx_discovery_jobs_claimed_by" ON "public"."discovery_jobs" USING "btree" ("claimed_by");



CREATE INDEX "idx_discovery_jobs_site_status_created" ON "public"."discovery_jobs" USING "btree" ("site_code", "status", "created_at");



CREATE INDEX "idx_discovery_jobs_status" ON "public"."discovery_jobs" USING "btree" ("status");



CREATE INDEX "idx_item_mods_item" ON "public"."order_item_modifiers" USING "btree" ("item_id");



CREATE INDEX "idx_items_check" ON "public"."order_items" USING "btree" ("check_id");



CREATE INDEX "idx_items_order" ON "public"."order_items" USING "btree" ("order_id");



CREATE INDEX "idx_links_item" ON "public"."menu_item_links" USING "btree" ("item_id");



CREATE INDEX "idx_links_menu" ON "public"."menu_item_links" USING "btree" ("menu_id", "position");



CREATE INDEX "idx_menu_item_links_menu" ON "public"."menu_item_links" USING "btree" ("menu_id", "position");



CREATE INDEX "idx_order_checks_order" ON "public"."order_checks" USING "btree" ("order_id");



CREATE INDEX "idx_orders_closed_at" ON "public"."orders" USING "btree" ("closed_at");



CREATE INDEX "idx_orders_session" ON "public"."orders" USING "btree" ("session_id", "created_at");



CREATE INDEX "idx_orders_session_status" ON "public"."orders" USING "btree" ("session_id", "status_ext");



CREATE INDEX "idx_sessions_table_open" ON "public"."table_sessions" USING "btree" ("table_id", "opened_at") WHERE ("closed_at" IS NULL);



CREATE INDEX "idx_tables_zone" ON "public"."dining_tables" USING "btree" ("zone_id", "code");



CREATE INDEX "idx_user_businesses_business" ON "public"."user_businesses" USING "btree" ("business_id");



CREATE INDEX "idx_user_businesses_user" ON "public"."user_businesses" USING "btree" ("user_id");



CREATE INDEX "idx_zones_business" ON "public"."zones" USING "btree" ("business_id", "sort_index");



CREATE UNIQUE INDEX "uniq_open_session_per_table" ON "public"."table_sessions" USING "btree" ("table_id") WHERE ("closed_at" IS NULL);



CREATE UNIQUE INDEX "uq_businesses_domain_lower" ON "public"."businesses" USING "btree" ("lower"("domain"));



CREATE OR REPLACE VIEW "public"."v_employees_summary" WITH ("security_invoker"='on') AS
 SELECT "e"."id",
    "e"."business_id",
    "e"."first_name",
    "e"."last_name",
    "e"."email",
    "e"."phone",
    "e"."department",
    "e"."position",
    "e"."salary_base",
    "e"."pay_frequency",
    "e"."status",
    "array_remove"("array_agg"("r"."name" ORDER BY "r"."name"), NULL::"text") AS "roles"
   FROM (("public"."employees" "e"
     LEFT JOIN "public"."employee_roles" "er" ON (("er"."employee_id" = "e"."id")))
     LEFT JOIN "public"."roles" "r" ON (("r"."id" = "er"."role_id")))
  GROUP BY "e"."id";



CREATE OR REPLACE TRIGGER "create_business_defaults" AFTER INSERT ON "public"."businesses" FOR EACH ROW EXECUTE FUNCTION "public"."trigger_create_business_defaults"();



CREATE OR REPLACE TRIGGER "increment_coupon_usage" AFTER INSERT ON "public"."coupon_usage" FOR EACH ROW EXECUTE FUNCTION "public"."trigger_increment_coupon_usage"();



CREATE OR REPLACE TRIGGER "order_items_totals_trigger" AFTER INSERT OR DELETE OR UPDATE ON "public"."order_items" FOR EACH ROW EXECUTE FUNCTION "public"."trigger_update_order_totals"();



CREATE OR REPLACE TRIGGER "set_business_id_on_table_session" BEFORE INSERT ON "public"."table_sessions" FOR EACH ROW EXECUTE FUNCTION "public"."set_table_session_business_id"();



CREATE OR REPLACE TRIGGER "set_business_settings_updated_at" BEFORE UPDATE ON "public"."business_settings" FOR EACH ROW EXECUTE FUNCTION "public"."trigger_set_updated_at"();



CREATE OR REPLACE TRIGGER "set_businesses_updated_at" BEFORE UPDATE ON "public"."businesses" FOR EACH ROW EXECUTE FUNCTION "public"."trigger_set_updated_at"();



CREATE OR REPLACE TRIGGER "set_customers_updated_at" BEFORE UPDATE ON "public"."customers" FOR EACH ROW EXECUTE FUNCTION "public"."trigger_set_updated_at"();



CREATE OR REPLACE TRIGGER "set_fiscal_settings_updated_at" BEFORE UPDATE ON "public"."fiscal_settings" FOR EACH ROW EXECUTE FUNCTION "public"."trigger_set_updated_at"();



CREATE OR REPLACE TRIGGER "set_menu_items_updated_at" BEFORE UPDATE ON "public"."menu_items" FOR EACH ROW EXECUTE FUNCTION "public"."trigger_set_updated_at"();



CREATE OR REPLACE TRIGGER "set_profiles_updated_at" BEFORE UPDATE ON "public"."profiles" FOR EACH ROW EXECUTE FUNCTION "public"."trigger_set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_businesses_domain_normalize" BEFORE INSERT OR UPDATE OF "domain" ON "public"."businesses" FOR EACH ROW EXECUTE FUNCTION "public"."fn_normalize_domain"();



CREATE OR REPLACE TRIGGER "trg_check_max_checks" BEFORE INSERT ON "public"."order_checks" FOR EACH ROW EXECUTE FUNCTION "public"."fn_check_max_checks"();



CREATE OR REPLACE TRIGGER "trg_employees_updated_at" BEFORE UPDATE ON "public"."employees" FOR EACH ROW EXECUTE FUNCTION "public"."set_employees_updated_at"();



CREATE OR REPLACE TRIGGER "trg_inventory_on_sent" AFTER UPDATE ON "public"."orders" FOR EACH ROW EXECUTE FUNCTION "public"."trigger_inventory_on_order_sent"();



CREATE OR REPLACE TRIGGER "trg_issue_fiscal" AFTER INSERT ON "public"."payments" FOR EACH ROW EXECUTE FUNCTION "public"."trigger_issue_fiscal_on_payment"();



CREATE OR REPLACE TRIGGER "trg_item_totals_ins" BEFORE INSERT ON "public"."order_items" FOR EACH ROW EXECUTE FUNCTION "public"."fn_compute_item_totals"();



CREATE OR REPLACE TRIGGER "trg_item_totals_upd" BEFORE UPDATE ON "public"."order_items" FOR EACH ROW EXECUTE FUNCTION "public"."fn_compute_item_totals"();



CREATE OR REPLACE TRIGGER "trg_menu_items_prep" BEFORE INSERT OR UPDATE ON "public"."menu_items" FOR EACH ROW EXECUTE FUNCTION "public"."enforce_prep_minutes"();



CREATE OR REPLACE TRIGGER "trg_menu_items_set_updated_at" BEFORE UPDATE ON "public"."menu_items" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_oi_sync_qty_quantity" BEFORE INSERT OR UPDATE ON "public"."order_items" FOR EACH ROW EXECUTE FUNCTION "public"."fn_oi_sync_qty_quantity"();



CREATE OR REPLACE TRIGGER "trg_recalc_after_item_del" AFTER DELETE ON "public"."order_items" FOR EACH ROW EXECUTE FUNCTION "public"."fn_after_item_change"();



CREATE OR REPLACE TRIGGER "trg_recalc_after_item_ins" AFTER INSERT ON "public"."order_items" FOR EACH ROW EXECUTE FUNCTION "public"."fn_after_item_change"();



CREATE OR REPLACE TRIGGER "trg_recalc_after_item_upd" AFTER UPDATE ON "public"."order_items" FOR EACH ROW EXECUTE FUNCTION "public"."fn_after_item_change"();



ALTER TABLE ONLY "public"."attendance"
    ADD CONSTRAINT "attendance_business_id_fkey" FOREIGN KEY ("business_id") REFERENCES "public"."businesses"("id");



ALTER TABLE ONLY "public"."attendance"
    ADD CONSTRAINT "attendance_shift_id_fkey" FOREIGN KEY ("shift_id") REFERENCES "public"."shifts"("id");



ALTER TABLE ONLY "public"."attendance"
    ADD CONSTRAINT "attendance_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."audit_logs"
    ADD CONSTRAINT "audit_logs_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."business_settings"
    ADD CONSTRAINT "business_settings_business_id_fkey" FOREIGN KEY ("business_id") REFERENCES "public"."businesses"("id");



ALTER TABLE ONLY "public"."businesses"
    ADD CONSTRAINT "businesses_owner_id_fkey" FOREIGN KEY ("owner_id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."cash_register_sessions"
    ADD CONSTRAINT "cash_register_sessions_cash_register_id_fkey" FOREIGN KEY ("cash_register_id") REFERENCES "public"."cash_registers"("id");



ALTER TABLE ONLY "public"."cash_register_sessions"
    ADD CONSTRAINT "cash_register_sessions_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."cash_transactions"
    ADD CONSTRAINT "cash_transactions_session_id_fkey" FOREIGN KEY ("session_id") REFERENCES "public"."cash_register_sessions"("id");



ALTER TABLE ONLY "public"."categories"
    ADD CONSTRAINT "categories_business_id_fkey" FOREIGN KEY ("business_id") REFERENCES "public"."businesses"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."coupon_usage"
    ADD CONSTRAINT "coupon_usage_coupon_id_fkey" FOREIGN KEY ("coupon_id") REFERENCES "public"."coupons"("id");



ALTER TABLE ONLY "public"."coupon_usage"
    ADD CONSTRAINT "coupon_usage_customer_id_fkey" FOREIGN KEY ("customer_id") REFERENCES "public"."customers"("id");



ALTER TABLE ONLY "public"."coupon_usage"
    ADD CONSTRAINT "coupon_usage_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."orders"("id");



ALTER TABLE ONLY "public"."coupons"
    ADD CONSTRAINT "coupons_business_id_fkey" FOREIGN KEY ("business_id") REFERENCES "public"."businesses"("id");



ALTER TABLE ONLY "public"."coupons"
    ADD CONSTRAINT "coupons_promotion_id_fkey" FOREIGN KEY ("promotion_id") REFERENCES "public"."promotions"("id");



ALTER TABLE ONLY "public"."credit_payments"
    ADD CONSTRAINT "credit_payments_credit_id_fkey" FOREIGN KEY ("credit_id") REFERENCES "public"."customer_credits"("id");



ALTER TABLE ONLY "public"."credit_payments"
    ADD CONSTRAINT "credit_payments_payment_method_id_fkey" FOREIGN KEY ("payment_method_id") REFERENCES "public"."payment_methods"("id");



ALTER TABLE ONLY "public"."credit_payments"
    ADD CONSTRAINT "credit_payments_received_by_fkey" FOREIGN KEY ("received_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."credit_payments"
    ADD CONSTRAINT "credit_payments_session_id_fkey" FOREIGN KEY ("session_id") REFERENCES "public"."cash_register_sessions"("id");



ALTER TABLE ONLY "public"."currencies"
    ADD CONSTRAINT "currencies_business_id_fkey" FOREIGN KEY ("business_id") REFERENCES "public"."businesses"("id");



ALTER TABLE ONLY "public"."customer_credits"
    ADD CONSTRAINT "customer_credits_business_id_fkey" FOREIGN KEY ("business_id") REFERENCES "public"."businesses"("id");



ALTER TABLE ONLY "public"."customer_credits"
    ADD CONSTRAINT "customer_credits_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."customer_credits"
    ADD CONSTRAINT "customer_credits_customer_id_fkey" FOREIGN KEY ("customer_id") REFERENCES "public"."customers"("id");



ALTER TABLE ONLY "public"."customer_credits"
    ADD CONSTRAINT "customer_credits_fiscal_document_id_fkey" FOREIGN KEY ("fiscal_document_id") REFERENCES "public"."fiscal_documents"("id");



ALTER TABLE ONLY "public"."customer_credits"
    ADD CONSTRAINT "customer_credits_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."orders"("id");



ALTER TABLE ONLY "public"."customer_points"
    ADD CONSTRAINT "customer_points_customer_id_fkey" FOREIGN KEY ("customer_id") REFERENCES "public"."customers"("id");



ALTER TABLE ONLY "public"."customer_points"
    ADD CONSTRAINT "customer_points_program_id_fkey" FOREIGN KEY ("program_id") REFERENCES "public"."loyalty_programs"("id");



ALTER TABLE ONLY "public"."customers"
    ADD CONSTRAINT "customers_business_id_fkey" FOREIGN KEY ("business_id") REFERENCES "public"."businesses"("id");



ALTER TABLE ONLY "public"."dining_tables"
    ADD CONSTRAINT "dining_tables_zone_id_fkey" FOREIGN KEY ("zone_id") REFERENCES "public"."zones"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."discovery_jobs"
    ADD CONSTRAINT "discovery_jobs_claimed_by_fkey" FOREIGN KEY ("claimed_by") REFERENCES "public"."agent_nodes"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."discovery_jobs"
    ADD CONSTRAINT "discovery_jobs_requested_by_fkey" FOREIGN KEY ("requested_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."employee_benefits"
    ADD CONSTRAINT "employee_benefits_employee_id_fkey" FOREIGN KEY ("employee_id") REFERENCES "public"."employees"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."employee_roles"
    ADD CONSTRAINT "employee_roles_employee_id_fkey" FOREIGN KEY ("employee_id") REFERENCES "public"."employees"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."employee_roles"
    ADD CONSTRAINT "employee_roles_role_id_fkey" FOREIGN KEY ("role_id") REFERENCES "public"."roles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."employees"
    ADD CONSTRAINT "employees_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."fiscal_document_items"
    ADD CONSTRAINT "fiscal_document_items_document_id_fkey" FOREIGN KEY ("document_id") REFERENCES "public"."fiscal_documents"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."fiscal_document_items"
    ADD CONSTRAINT "fiscal_document_items_order_item_id_fkey" FOREIGN KEY ("order_item_id") REFERENCES "public"."order_items"("id");



ALTER TABLE ONLY "public"."fiscal_documents"
    ADD CONSTRAINT "fiscal_documents_business_id_fkey" FOREIGN KEY ("business_id") REFERENCES "public"."businesses"("id");



ALTER TABLE ONLY "public"."fiscal_documents"
    ADD CONSTRAINT "fiscal_documents_cancelled_by_fkey" FOREIGN KEY ("cancelled_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."fiscal_documents"
    ADD CONSTRAINT "fiscal_documents_customer_id_fkey" FOREIGN KEY ("customer_id") REFERENCES "public"."customers"("id");



ALTER TABLE ONLY "public"."fiscal_documents"
    ADD CONSTRAINT "fiscal_documents_issued_by_fkey" FOREIGN KEY ("issued_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."fiscal_documents"
    ADD CONSTRAINT "fiscal_documents_ncf_sequence_id_fkey" FOREIGN KEY ("ncf_sequence_id") REFERENCES "public"."ncf_sequences"("id");



ALTER TABLE ONLY "public"."fiscal_documents"
    ADD CONSTRAINT "fiscal_documents_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."orders"("id");



ALTER TABLE ONLY "public"."fiscal_documents"
    ADD CONSTRAINT "fiscal_documents_payment_id_fkey" FOREIGN KEY ("payment_id") REFERENCES "public"."payments"("id");



ALTER TABLE ONLY "public"."fiscal_documents"
    ADD CONSTRAINT "fiscal_documents_related_document_id_fkey" FOREIGN KEY ("related_document_id") REFERENCES "public"."fiscal_documents"("id");



ALTER TABLE ONLY "public"."fiscal_settings"
    ADD CONSTRAINT "fiscal_settings_business_id_fkey" FOREIGN KEY ("business_id") REFERENCES "public"."businesses"("id");



ALTER TABLE ONLY "public"."gift_card_transactions"
    ADD CONSTRAINT "gift_card_transactions_gift_card_id_fkey" FOREIGN KEY ("gift_card_id") REFERENCES "public"."gift_cards"("id");



ALTER TABLE ONLY "public"."gift_card_transactions"
    ADD CONSTRAINT "gift_card_transactions_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."orders"("id");



ALTER TABLE ONLY "public"."gift_cards"
    ADD CONSTRAINT "gift_cards_business_id_fkey" FOREIGN KEY ("business_id") REFERENCES "public"."businesses"("id");



ALTER TABLE ONLY "public"."gift_cards"
    ADD CONSTRAINT "gift_cards_customer_id_fkey" FOREIGN KEY ("customer_id") REFERENCES "public"."customers"("id");



ALTER TABLE ONLY "public"."inventory_items"
    ADD CONSTRAINT "inventory_items_business_id_fkey" FOREIGN KEY ("business_id") REFERENCES "public"."businesses"("id");



ALTER TABLE ONLY "public"."inventory_movements"
    ADD CONSTRAINT "inventory_movements_business_id_fkey" FOREIGN KEY ("business_id") REFERENCES "public"."businesses"("id");



ALTER TABLE ONLY "public"."inventory_movements"
    ADD CONSTRAINT "inventory_movements_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."inventory_movements"
    ADD CONSTRAINT "inventory_movements_item_id_fkey" FOREIGN KEY ("item_id") REFERENCES "public"."inventory_items"("id");



ALTER TABLE ONLY "public"."inventory_movements"
    ADD CONSTRAINT "inventory_movements_warehouse_id_fkey" FOREIGN KEY ("warehouse_id") REFERENCES "public"."warehouses"("id");



ALTER TABLE ONLY "public"."inventory_stock"
    ADD CONSTRAINT "inventory_stock_item_id_fkey" FOREIGN KEY ("item_id") REFERENCES "public"."inventory_items"("id");



ALTER TABLE ONLY "public"."inventory_stock"
    ADD CONSTRAINT "inventory_stock_warehouse_id_fkey" FOREIGN KEY ("warehouse_id") REFERENCES "public"."warehouses"("id");



ALTER TABLE ONLY "public"."loyalty_programs"
    ADD CONSTRAINT "loyalty_programs_business_id_fkey" FOREIGN KEY ("business_id") REFERENCES "public"."businesses"("id");



ALTER TABLE ONLY "public"."memberships"
    ADD CONSTRAINT "memberships_business_id_fkey" FOREIGN KEY ("business_id") REFERENCES "public"."businesses"("id");



ALTER TABLE ONLY "public"."memberships"
    ADD CONSTRAINT "memberships_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."menu_item_groups"
    ADD CONSTRAINT "menu_item_groups_group_id_fkey" FOREIGN KEY ("group_id") REFERENCES "public"."modifier_groups"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."menu_item_groups"
    ADD CONSTRAINT "menu_item_groups_menu_item_id_fkey" FOREIGN KEY ("menu_item_id") REFERENCES "public"."menu_items"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."menu_item_links"
    ADD CONSTRAINT "menu_item_links_item_id_fkey" FOREIGN KEY ("item_id") REFERENCES "public"."menu_items"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."menu_item_links"
    ADD CONSTRAINT "menu_item_links_menu_id_fkey" FOREIGN KEY ("menu_id") REFERENCES "public"."menus"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."menu_item_taxes"
    ADD CONSTRAINT "menu_item_taxes_item_id_fkey" FOREIGN KEY ("item_id") REFERENCES "public"."menu_items"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."menu_item_taxes"
    ADD CONSTRAINT "menu_item_taxes_tax_id_fkey" FOREIGN KEY ("tax_id") REFERENCES "public"."taxes"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."menu_items"
    ADD CONSTRAINT "menu_items_business_id_fkey" FOREIGN KEY ("business_id") REFERENCES "public"."businesses"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."menu_items"
    ADD CONSTRAINT "menu_items_category_id_fkey" FOREIGN KEY ("category_id") REFERENCES "public"."categories"("id");



ALTER TABLE ONLY "public"."menus"
    ADD CONSTRAINT "menus_business_id_fkey" FOREIGN KEY ("business_id") REFERENCES "public"."businesses"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."modifier_groups"
    ADD CONSTRAINT "modifier_groups_business_id_fkey" FOREIGN KEY ("business_id") REFERENCES "public"."businesses"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."modifiers"
    ADD CONSTRAINT "modifiers_business_id_fkey" FOREIGN KEY ("business_id") REFERENCES "public"."businesses"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."modifiers"
    ADD CONSTRAINT "modifiers_group_id_fkey" FOREIGN KEY ("group_id") REFERENCES "public"."modifier_groups"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."ncf_sequences"
    ADD CONSTRAINT "ncf_sequences_business_id_fkey" FOREIGN KEY ("business_id") REFERENCES "public"."businesses"("id");



ALTER TABLE ONLY "public"."order_checks"
    ADD CONSTRAINT "order_checks_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."orders"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."order_item_modifiers"
    ADD CONSTRAINT "order_item_modifiers_item_id_fkey" FOREIGN KEY ("item_id") REFERENCES "public"."order_items"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."order_items"
    ADD CONSTRAINT "order_items_check_id_fkey" FOREIGN KEY ("check_id") REFERENCES "public"."order_checks"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."order_items"
    ADD CONSTRAINT "order_items_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."orders"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."orders"
    ADD CONSTRAINT "orders_session_id_fkey" FOREIGN KEY ("session_id") REFERENCES "public"."table_sessions"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."payment_methods"
    ADD CONSTRAINT "payment_methods_business_id_fkey" FOREIGN KEY ("business_id") REFERENCES "public"."businesses"("id");



ALTER TABLE ONLY "public"."payments"
    ADD CONSTRAINT "payments_business_id_fkey" FOREIGN KEY ("business_id") REFERENCES "public"."businesses"("id");



ALTER TABLE ONLY "public"."payments"
    ADD CONSTRAINT "payments_check_id_fkey" FOREIGN KEY ("check_id") REFERENCES "public"."order_checks"("id");



ALTER TABLE ONLY "public"."payments"
    ADD CONSTRAINT "payments_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."orders"("id");



ALTER TABLE ONLY "public"."payments"
    ADD CONSTRAINT "payments_payment_method_id_fkey" FOREIGN KEY ("payment_method_id") REFERENCES "public"."payment_methods"("id");



ALTER TABLE ONLY "public"."payments"
    ADD CONSTRAINT "payments_processed_by_fkey" FOREIGN KEY ("processed_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."payments"
    ADD CONSTRAINT "payments_session_id_fkey" FOREIGN KEY ("session_id") REFERENCES "public"."cash_register_sessions"("id");



ALTER TABLE ONLY "public"."point_transactions"
    ADD CONSTRAINT "point_transactions_customer_points_id_fkey" FOREIGN KEY ("customer_points_id") REFERENCES "public"."customer_points"("id");



ALTER TABLE ONLY "public"."point_transactions"
    ADD CONSTRAINT "point_transactions_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."orders"("id");



ALTER TABLE ONLY "public"."print_area_printers"
    ADD CONSTRAINT "print_area_printers_area_id_fkey" FOREIGN KEY ("area_id") REFERENCES "public"."print_areas"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."print_area_printers"
    ADD CONSTRAINT "print_area_printers_business_id_fkey" FOREIGN KEY ("business_id") REFERENCES "public"."businesses"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."print_area_printers"
    ADD CONSTRAINT "print_area_printers_printer_id_fkey" FOREIGN KEY ("printer_id") REFERENCES "public"."printers"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."print_areas"
    ADD CONSTRAINT "print_areas_business_id_fkey" FOREIGN KEY ("business_id") REFERENCES "public"."businesses"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."print_jobs"
    ADD CONSTRAINT "print_jobs_business_id_fkey" FOREIGN KEY ("business_id") REFERENCES "public"."businesses"("id");



ALTER TABLE ONLY "public"."printers"
    ADD CONSTRAINT "printers_business_id_fkey" FOREIGN KEY ("business_id") REFERENCES "public"."businesses"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."promotions"
    ADD CONSTRAINT "promotions_business_id_fkey" FOREIGN KEY ("business_id") REFERENCES "public"."businesses"("id");



ALTER TABLE ONLY "public"."purchase_order_items"
    ADD CONSTRAINT "purchase_order_items_inventory_item_id_fkey" FOREIGN KEY ("inventory_item_id") REFERENCES "public"."inventory_items"("id");



ALTER TABLE ONLY "public"."purchase_order_items"
    ADD CONSTRAINT "purchase_order_items_purchase_order_id_fkey" FOREIGN KEY ("purchase_order_id") REFERENCES "public"."purchase_orders"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."purchase_orders"
    ADD CONSTRAINT "purchase_orders_business_id_fkey" FOREIGN KEY ("business_id") REFERENCES "public"."businesses"("id");



ALTER TABLE ONLY "public"."purchase_orders"
    ADD CONSTRAINT "purchase_orders_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."purchase_orders"
    ADD CONSTRAINT "purchase_orders_supplier_id_fkey" FOREIGN KEY ("supplier_id") REFERENCES "public"."suppliers"("id");



ALTER TABLE ONLY "public"."purchase_orders"
    ADD CONSTRAINT "purchase_orders_warehouse_id_fkey" FOREIGN KEY ("warehouse_id") REFERENCES "public"."warehouses"("id");



ALTER TABLE ONLY "public"."recipe_ingredients"
    ADD CONSTRAINT "recipe_ingredients_inventory_item_id_fkey" FOREIGN KEY ("inventory_item_id") REFERENCES "public"."inventory_items"("id");



ALTER TABLE ONLY "public"."recipe_ingredients"
    ADD CONSTRAINT "recipe_ingredients_recipe_id_fkey" FOREIGN KEY ("recipe_id") REFERENCES "public"."recipes"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."recipes"
    ADD CONSTRAINT "recipes_menu_item_id_fkey" FOREIGN KEY ("menu_item_id") REFERENCES "public"."menu_items"("id");



ALTER TABLE ONLY "public"."role_permissions"
    ADD CONSTRAINT "role_permissions_permission_id_fkey" FOREIGN KEY ("permission_id") REFERENCES "public"."permissions"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."role_permissions"
    ADD CONSTRAINT "role_permissions_role_id_fkey" FOREIGN KEY ("role_id") REFERENCES "public"."roles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."roles"
    ADD CONSTRAINT "roles_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."shifts"
    ADD CONSTRAINT "shifts_business_id_fkey" FOREIGN KEY ("business_id") REFERENCES "public"."businesses"("id");



ALTER TABLE ONLY "public"."suppliers"
    ADD CONSTRAINT "suppliers_business_id_fkey" FOREIGN KEY ("business_id") REFERENCES "public"."businesses"("id");



ALTER TABLE ONLY "public"."table_sessions"
    ADD CONSTRAINT "table_sessions_business_id_fkey" FOREIGN KEY ("business_id") REFERENCES "public"."businesses"("id");



ALTER TABLE ONLY "public"."table_sessions"
    ADD CONSTRAINT "table_sessions_opened_by_fkey" FOREIGN KEY ("opened_by") REFERENCES "auth"."users"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."table_sessions"
    ADD CONSTRAINT "table_sessions_table_id_fkey" FOREIGN KEY ("table_id") REFERENCES "public"."dining_tables"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."taxes"
    ADD CONSTRAINT "taxes_business_id_fkey" FOREIGN KEY ("business_id") REFERENCES "public"."businesses"("id");



ALTER TABLE ONLY "public"."user_businesses"
    ADD CONSTRAINT "user_businesses_business_id_fkey" FOREIGN KEY ("business_id") REFERENCES "public"."businesses"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_businesses"
    ADD CONSTRAINT "user_businesses_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_permission_overrides"
    ADD CONSTRAINT "user_permission_overrides_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."user_permission_overrides"
    ADD CONSTRAINT "user_permission_overrides_permission_id_fkey" FOREIGN KEY ("permission_id") REFERENCES "public"."permissions"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_permission_overrides"
    ADD CONSTRAINT "user_permission_overrides_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_roles"
    ADD CONSTRAINT "user_roles_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."user_roles"
    ADD CONSTRAINT "user_roles_role_id_fkey" FOREIGN KEY ("role_id") REFERENCES "public"."roles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_roles"
    ADD CONSTRAINT "user_roles_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."warehouses"
    ADD CONSTRAINT "warehouses_business_id_fkey" FOREIGN KEY ("business_id") REFERENCES "public"."businesses"("id");



ALTER TABLE ONLY "public"."zones"
    ADD CONSTRAINT "zones_business_id_fkey" FOREIGN KEY ("business_id") REFERENCES "public"."businesses"("id") ON DELETE CASCADE;



CREATE POLICY "Access cash_registers based on business_id" ON "public"."cash_registers" USING (("auth"."uid"() IN ( SELECT "user_businesses"."user_id"
   FROM "public"."user_businesses"
  WHERE ("user_businesses"."business_id" = "cash_registers"."business_id"))));



CREATE POLICY "Access sessions based on cash_register business" ON "public"."cash_register_sessions" USING (("cash_register_id" IN ( SELECT "cash_registers"."id"
   FROM "public"."cash_registers"
  WHERE ("cash_registers"."business_id" IN ( SELECT "user_businesses"."business_id"
           FROM "public"."user_businesses"
          WHERE ("user_businesses"."user_id" = "auth"."uid"()))))));



CREATE POLICY "Access transactions via sessions" ON "public"."cash_transactions" USING (("session_id" IN ( SELECT "cash_register_sessions"."id"
   FROM "public"."cash_register_sessions"
  WHERE ("cash_register_sessions"."cash_register_id" IN ( SELECT "cash_registers"."id"
           FROM "public"."cash_registers"
          WHERE ("cash_registers"."business_id" IN ( SELECT "user_businesses"."business_id"
                   FROM "public"."user_businesses"
                  WHERE ("user_businesses"."user_id" = "auth"."uid"()))))))));



CREATE POLICY "Admins can manage zones" ON "public"."zones" TO "authenticated" USING ("public"."has_business_role"("auth"."uid"(), "business_id", ARRAY['owner'::"text", 'admin'::"text"])) WITH CHECK ("public"."has_business_role"("auth"."uid"(), "business_id", ARRAY['owner'::"text", 'admin'::"text"]));



CREATE POLICY "Enable all access for authenticated users with matching busines" ON "public"."customers" USING (("auth"."uid"() IN ( SELECT "user_businesses"."user_id"
   FROM "public"."user_businesses"
  WHERE ("user_businesses"."business_id" = "customers"."business_id"))));



CREATE POLICY "Staff can manage orders" ON "public"."orders" TO "authenticated" USING ("public"."has_business_role"("auth"."uid"(), ( SELECT "table_sessions"."business_id"
   FROM "public"."table_sessions"
  WHERE ("table_sessions"."id" = "orders"."session_id")), ARRAY['owner'::"text", 'admin'::"text", 'cashier'::"text", 'waiter'::"text"]));



CREATE POLICY "Users can view business orders" ON "public"."orders" FOR SELECT TO "authenticated" USING ("public"."user_has_business_access"("auth"."uid"(), ( SELECT "table_sessions"."business_id"
   FROM "public"."table_sessions"
  WHERE ("table_sessions"."id" = "orders"."session_id"))));



CREATE POLICY "Users can view order items" ON "public"."order_items" FOR SELECT TO "authenticated" USING ("public"."user_has_business_access"("auth"."uid"(), ( SELECT "ts"."business_id"
   FROM ("public"."orders" "o"
     JOIN "public"."table_sessions" "ts" ON (("o"."session_id" = "ts"."id")))
  WHERE ("o"."id" = "order_items"."order_id"))));



CREATE POLICY "Users can view own business data" ON "public"."categories" FOR SELECT TO "authenticated" USING ("public"."user_has_business_access"("auth"."uid"(), "business_id"));



CREATE POLICY "Users can view own business data" ON "public"."menu_items" FOR SELECT TO "authenticated" USING ("public"."user_has_business_access"("auth"."uid"(), "business_id"));



CREATE POLICY "Users can view own business data" ON "public"."zones" FOR SELECT TO "authenticated" USING ("public"."user_has_business_access"("auth"."uid"(), "business_id"));



CREATE POLICY "Users can view tables" ON "public"."dining_tables" FOR SELECT TO "authenticated" USING ("public"."user_has_business_access"("auth"."uid"(), ( SELECT "zones"."business_id"
   FROM "public"."zones"
  WHERE ("zones"."id" = "dining_tables"."zone_id"))));



ALTER TABLE "public"."agent_nodes" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."attendance" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "audit by business" ON "public"."audit_logs" USING ("public"."fn_user_in_business"("business_id"));



ALTER TABLE "public"."audit_logs" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "bs_admin" ON "public"."business_settings" TO "authenticated" USING (("public"."user_business_role"("auth"."uid"(), "business_id") = ANY (ARRAY['owner'::"text", 'admin'::"text"]))) WITH CHECK (("public"."user_business_role"("auth"."uid"(), "business_id") = ANY (ARRAY['owner'::"text", 'admin'::"text"])));



CREATE POLICY "bs_select" ON "public"."business_settings" FOR SELECT TO "authenticated" USING ("public"."user_has_business_access"("auth"."uid"(), "business_id"));



ALTER TABLE "public"."business_settings" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."businesses" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "businesses_owner_insert" ON "public"."businesses" FOR INSERT TO "authenticated" WITH CHECK (("owner_id" = "auth"."uid"()));



CREATE POLICY "businesses_owner_select" ON "public"."businesses" FOR SELECT TO "authenticated" USING ((("owner_id" = "auth"."uid"()) OR ("id" IN ( SELECT "current_user_business_ids"."current_user_business_ids"
   FROM "public"."current_user_business_ids"() "current_user_business_ids"("current_user_business_ids")))));



CREATE POLICY "businesses_owner_update" ON "public"."businesses" FOR UPDATE TO "authenticated" USING (("owner_id" = "auth"."uid"())) WITH CHECK (("owner_id" = "auth"."uid"()));



ALTER TABLE "public"."cash_register_sessions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."cash_registers" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."cash_transactions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."categories" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "categories_read" ON "public"."categories" FOR SELECT TO "authenticated" USING (("business_id" IN ( SELECT "public"."current_user_business_ids"() AS "current_user_business_ids")));



CREATE POLICY "categories_write" ON "public"."categories" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."user_businesses" "ub"
  WHERE (("ub"."business_id" = "categories"."business_id") AND ("ub"."user_id" = "auth"."uid"()) AND ("ub"."role" = ANY (ARRAY['owner'::"text", 'admin'::"text"])))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."user_businesses" "ub"
  WHERE (("ub"."business_id" = "categories"."business_id") AND ("ub"."user_id" = "auth"."uid"()) AND ("ub"."role" = ANY (ARRAY['owner'::"text", 'admin'::"text"]))))));



CREATE POLICY "cc_select" ON "public"."customer_credits" FOR SELECT TO "authenticated" USING ("public"."user_has_business_access"("auth"."uid"(), "business_id"));



CREATE POLICY "checks_rw" ON "public"."order_checks" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM ((("public"."orders" "o"
     JOIN "public"."table_sessions" "s" ON (("s"."id" = "o"."session_id")))
     JOIN "public"."dining_tables" "t" ON (("t"."id" = "s"."table_id")))
     JOIN "public"."zones" "z" ON (("z"."id" = "t"."zone_id")))
  WHERE (("o"."id" = "order_checks"."order_id") AND ("z"."business_id" IN ( SELECT "public"."current_user_business_ids"() AS "current_user_business_ids")))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM ((("public"."orders" "o"
     JOIN "public"."table_sessions" "s" ON (("s"."id" = "o"."session_id")))
     JOIN "public"."dining_tables" "t" ON (("t"."id" = "s"."table_id")))
     JOIN "public"."zones" "z" ON (("z"."id" = "t"."zone_id")))
  WHERE (("o"."id" = "order_checks"."order_id") AND ("z"."business_id" IN ( SELECT "public"."current_user_business_ids"() AS "current_user_business_ids"))))));



ALTER TABLE "public"."coupon_usage" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."coupons" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "cp_select" ON "public"."customer_points" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."customers" "c"
  WHERE (("c"."id" = "customer_points"."customer_id") AND "public"."user_has_business_access"("auth"."uid"(), "c"."business_id")))));



CREATE POLICY "cpay_select" ON "public"."credit_payments" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."customer_credits" "cc"
  WHERE (("cc"."id" = "credit_payments"."credit_id") AND "public"."user_has_business_access"("auth"."uid"(), "cc"."business_id")))));



ALTER TABLE "public"."credit_payments" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "cur_admin" ON "public"."currencies" TO "authenticated" USING (("public"."user_business_role"("auth"."uid"(), "business_id") = ANY (ARRAY['owner'::"text", 'admin'::"text"]))) WITH CHECK (("public"."user_business_role"("auth"."uid"(), "business_id") = ANY (ARRAY['owner'::"text", 'admin'::"text"])));



CREATE POLICY "cur_select" ON "public"."currencies" FOR SELECT TO "authenticated" USING ("public"."user_has_business_access"("auth"."uid"(), "business_id"));



ALTER TABLE "public"."currencies" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."customer_credits" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."customer_points" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."customers" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "delete areas admins" ON "public"."print_areas" FOR DELETE USING ("public"."is_admin_of_business"("business_id"));



CREATE POLICY "delete printers admins" ON "public"."printers" FOR DELETE USING ("public"."is_admin_of_business"("business_id"));



ALTER TABLE "public"."dining_tables" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "dining_tables_delete" ON "public"."dining_tables" FOR DELETE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."zones" "z"
  WHERE (("z"."id" = "dining_tables"."zone_id") AND ("z"."business_id" IN ( SELECT "public"."current_user_business_ids"() AS "current_user_business_ids"))))));



CREATE POLICY "dining_tables_insert" ON "public"."dining_tables" FOR INSERT TO "authenticated" WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."zones" "z"
  WHERE (("z"."id" = "dining_tables"."zone_id") AND ("z"."business_id" IN ( SELECT "public"."current_user_business_ids"() AS "current_user_business_ids"))))));



CREATE POLICY "dining_tables_select" ON "public"."dining_tables" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."zones" "z"
  WHERE (("z"."id" = "dining_tables"."zone_id") AND ("z"."business_id" IN ( SELECT "public"."current_user_business_ids"() AS "current_user_business_ids"))))));



CREATE POLICY "dining_tables_update" ON "public"."dining_tables" FOR UPDATE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."zones" "z"
  WHERE (("z"."id" = "dining_tables"."zone_id") AND ("z"."business_id" IN ( SELECT "public"."current_user_business_ids"() AS "current_user_business_ids")))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."zones" "z"
  WHERE (("z"."id" = "dining_tables"."zone_id") AND ("z"."business_id" IN ( SELECT "public"."current_user_business_ids"() AS "current_user_business_ids"))))));



ALTER TABLE "public"."discovery_jobs" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "discovery_jobs_insert" ON "public"."discovery_jobs" FOR INSERT WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."memberships" "m"
  WHERE (("m"."user_id" = "auth"."uid"()) AND ("m"."business_id" = "discovery_jobs"."business_id")))));



CREATE POLICY "discovery_jobs_select" ON "public"."discovery_jobs" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."memberships" "m"
  WHERE (("m"."user_id" = "auth"."uid"()) AND ("m"."business_id" = "discovery_jobs"."business_id")))));



CREATE POLICY "discovery_jobs_update" ON "public"."discovery_jobs" FOR UPDATE USING (("auth"."role"() = 'service_role'::"text"));



ALTER TABLE "public"."employee_benefits" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "employee_benefits by business" ON "public"."employee_benefits" USING ((EXISTS ( SELECT 1
   FROM "public"."employees" "e"
  WHERE (("e"."id" = "employee_benefits"."employee_id") AND "public"."fn_user_in_business"("e"."business_id")))));



ALTER TABLE "public"."employee_roles" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "employee_roles by business" ON "public"."employee_roles" USING ((EXISTS ( SELECT 1
   FROM "public"."employees" "e"
  WHERE (("e"."id" = "employee_roles"."employee_id") AND "public"."fn_user_in_business"("e"."business_id")))));



ALTER TABLE "public"."employees" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "employees by business" ON "public"."employees" USING ("public"."fn_user_in_business"("business_id"));



CREATE POLICY "fd_insert" ON "public"."fiscal_documents" FOR INSERT TO "authenticated" WITH CHECK ("public"."user_has_business_access"("auth"."uid"(), "business_id"));



CREATE POLICY "fd_select" ON "public"."fiscal_documents" FOR SELECT TO "authenticated" USING ("public"."user_has_business_access"("auth"."uid"(), "business_id"));



CREATE POLICY "fdi_select" ON "public"."fiscal_document_items" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."fiscal_documents" "fd"
  WHERE (("fd"."id" = "fiscal_document_items"."document_id") AND "public"."user_has_business_access"("auth"."uid"(), "fd"."business_id")))));



ALTER TABLE "public"."fiscal_document_items" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."fiscal_documents" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."fiscal_settings" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "fs_admin" ON "public"."fiscal_settings" TO "authenticated" USING (("public"."user_business_role"("auth"."uid"(), "business_id") = ANY (ARRAY['owner'::"text", 'admin'::"text"]))) WITH CHECK (("public"."user_business_role"("auth"."uid"(), "business_id") = ANY (ARRAY['owner'::"text", 'admin'::"text"])));



CREATE POLICY "fs_select" ON "public"."fiscal_settings" FOR SELECT TO "authenticated" USING ("public"."user_has_business_access"("auth"."uid"(), "business_id"));



ALTER TABLE "public"."gift_card_transactions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."gift_cards" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "ii_admin" ON "public"."inventory_items" TO "authenticated" USING (("public"."user_business_role"("auth"."uid"(), "business_id") = ANY (ARRAY['owner'::"text", 'admin'::"text"]))) WITH CHECK (("public"."user_business_role"("auth"."uid"(), "business_id") = ANY (ARRAY['owner'::"text", 'admin'::"text"])));



CREATE POLICY "ii_select" ON "public"."inventory_items" FOR SELECT TO "authenticated" USING ("public"."user_has_business_access"("auth"."uid"(), "business_id"));



CREATE POLICY "im_select" ON "public"."inventory_movements" FOR SELECT TO "authenticated" USING ("public"."user_has_business_access"("auth"."uid"(), "business_id"));



CREATE POLICY "insert areas admins" ON "public"."print_areas" FOR INSERT WITH CHECK ("public"."is_admin_of_business"("business_id"));



CREATE POLICY "insert printers admins" ON "public"."printers" FOR INSERT WITH CHECK ("public"."is_admin_of_business"("business_id"));



ALTER TABLE "public"."inventory_items" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."inventory_movements" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."inventory_stock" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "is_select" ON "public"."inventory_stock" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."warehouses" "w"
  WHERE (("w"."id" = "inventory_stock"."warehouse_id") AND "public"."user_has_business_access"("auth"."uid"(), "w"."business_id")))));



CREATE POLICY "item_mods_rw" ON "public"."order_item_modifiers" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM (((("public"."order_items" "oi"
     JOIN "public"."orders" "o" ON (("o"."id" = "oi"."order_id")))
     JOIN "public"."table_sessions" "s" ON (("s"."id" = "o"."session_id")))
     JOIN "public"."dining_tables" "t" ON (("t"."id" = "s"."table_id")))
     JOIN "public"."zones" "z" ON (("z"."id" = "t"."zone_id")))
  WHERE (("oi"."id" = "order_item_modifiers"."item_id") AND ("z"."business_id" IN ( SELECT "public"."current_user_business_ids"() AS "current_user_business_ids")))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM (((("public"."order_items" "oi"
     JOIN "public"."orders" "o" ON (("o"."id" = "oi"."order_id")))
     JOIN "public"."table_sessions" "s" ON (("s"."id" = "o"."session_id")))
     JOIN "public"."dining_tables" "t" ON (("t"."id" = "s"."table_id")))
     JOIN "public"."zones" "z" ON (("z"."id" = "t"."zone_id")))
  WHERE (("oi"."id" = "order_item_modifiers"."item_id") AND ("z"."business_id" IN ( SELECT "public"."current_user_business_ids"() AS "current_user_business_ids"))))));



CREATE POLICY "items_rw" ON "public"."order_items" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM ((("public"."orders" "o"
     JOIN "public"."table_sessions" "s" ON (("s"."id" = "o"."session_id")))
     JOIN "public"."dining_tables" "t" ON (("t"."id" = "s"."table_id")))
     JOIN "public"."zones" "z" ON (("z"."id" = "t"."zone_id")))
  WHERE (("o"."id" = "order_items"."order_id") AND ("z"."business_id" IN ( SELECT "public"."current_user_business_ids"() AS "current_user_business_ids")))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM ((("public"."orders" "o"
     JOIN "public"."table_sessions" "s" ON (("s"."id" = "o"."session_id")))
     JOIN "public"."dining_tables" "t" ON (("t"."id" = "s"."table_id")))
     JOIN "public"."zones" "z" ON (("z"."id" = "t"."zone_id")))
  WHERE (("o"."id" = "order_items"."order_id") AND ("z"."business_id" IN ( SELECT "public"."current_user_business_ids"() AS "current_user_business_ids"))))));



CREATE POLICY "jobs_insert_by_member" ON "public"."discovery_jobs" FOR INSERT TO "authenticated" WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."memberships" "m"
  WHERE (("m"."user_id" = "auth"."uid"()) AND ("m"."business_id" = "discovery_jobs"."business_id")))));



CREATE POLICY "jobs_insert_own_business" ON "public"."discovery_jobs" FOR INSERT WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."memberships" "m"
  WHERE (("m"."user_id" = "auth"."uid"()) AND ("m"."business_id" = "discovery_jobs"."business_id")))));



CREATE POLICY "jobs_select_own_business" ON "public"."discovery_jobs" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."memberships" "m"
  WHERE (("m"."user_id" = "auth"."uid"()) AND ("m"."business_id" = "discovery_jobs"."business_id")))));



CREATE POLICY "links_select" ON "public"."menu_item_links" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."menus" "mm"
  WHERE (("mm"."id" = "menu_item_links"."menu_id") AND ("mm"."business_id" IN ( SELECT "public"."current_user_business_ids"() AS "current_user_business_ids"))))));



CREATE POLICY "links_write" ON "public"."menu_item_links" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."menus" "mm"
  WHERE (("mm"."id" = "menu_item_links"."menu_id") AND ("mm"."business_id" IN ( SELECT "public"."current_user_business_ids"() AS "current_user_business_ids")))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."menus" "mm"
  WHERE (("mm"."id" = "menu_item_links"."menu_id") AND ("mm"."business_id" IN ( SELECT "public"."current_user_business_ids"() AS "current_user_business_ids"))))));



ALTER TABLE "public"."loyalty_programs" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "lp_admin" ON "public"."loyalty_programs" TO "authenticated" USING (("public"."user_business_role"("auth"."uid"(), "business_id") = ANY (ARRAY['owner'::"text", 'admin'::"text"]))) WITH CHECK (("public"."user_business_role"("auth"."uid"(), "business_id") = ANY (ARRAY['owner'::"text", 'admin'::"text"])));



CREATE POLICY "lp_select" ON "public"."loyalty_programs" FOR SELECT TO "authenticated" USING ("public"."user_has_business_access"("auth"."uid"(), "business_id"));



ALTER TABLE "public"."memberships" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "memberships_insert_own" ON "public"."memberships" FOR INSERT TO "authenticated" WITH CHECK (("user_id" = "auth"."uid"()));



CREATE POLICY "memberships_select_own" ON "public"."memberships" FOR SELECT TO "authenticated" USING (("user_id" = "auth"."uid"()));



ALTER TABLE "public"."menu_item_groups" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "menu_item_groups_read" ON "public"."menu_item_groups" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."menu_items" "mi"
  WHERE (("mi"."id" = "menu_item_groups"."menu_item_id") AND ("mi"."business_id" IN ( SELECT "public"."current_user_business_ids"() AS "current_user_business_ids"))))));



CREATE POLICY "menu_item_groups_write" ON "public"."menu_item_groups" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."menu_items" "mi"
  WHERE (("mi"."id" = "menu_item_groups"."menu_item_id") AND (EXISTS ( SELECT 1
           FROM "public"."user_businesses" "ub"
          WHERE (("ub"."business_id" = "mi"."business_id") AND ("ub"."user_id" = "auth"."uid"()) AND ("ub"."role" = ANY (ARRAY['owner'::"text", 'admin'::"text"]))))))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."menu_items" "mi"
  WHERE (("mi"."id" = "menu_item_groups"."menu_item_id") AND (EXISTS ( SELECT 1
           FROM "public"."user_businesses" "ub"
          WHERE (("ub"."business_id" = "mi"."business_id") AND ("ub"."user_id" = "auth"."uid"()) AND ("ub"."role" = ANY (ARRAY['owner'::"text", 'admin'::"text"])))))))));



ALTER TABLE "public"."menu_item_links" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "menu_item_links_read" ON "public"."menu_item_links" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."menus" "m"
  WHERE (("m"."id" = "menu_item_links"."menu_id") AND ("m"."business_id" IN ( SELECT "public"."current_user_business_ids"() AS "current_user_business_ids"))))));



CREATE POLICY "menu_item_links_write" ON "public"."menu_item_links" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."menus" "m"
  WHERE (("m"."id" = "menu_item_links"."menu_id") AND (EXISTS ( SELECT 1
           FROM "public"."user_businesses" "ub"
          WHERE (("ub"."business_id" = "m"."business_id") AND ("ub"."user_id" = "auth"."uid"()) AND ("ub"."role" = ANY (ARRAY['owner'::"text", 'admin'::"text"]))))))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."menus" "m"
  WHERE (("m"."id" = "menu_item_links"."menu_id") AND (EXISTS ( SELECT 1
           FROM "public"."user_businesses" "ub"
          WHERE (("ub"."business_id" = "m"."business_id") AND ("ub"."user_id" = "auth"."uid"()) AND ("ub"."role" = ANY (ARRAY['owner'::"text", 'admin'::"text"])))))))));



ALTER TABLE "public"."menu_item_taxes" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."menu_items" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "menu_items_read" ON "public"."menu_items" FOR SELECT TO "authenticated" USING (("business_id" IN ( SELECT "public"."current_user_business_ids"() AS "current_user_business_ids")));



CREATE POLICY "menu_items_write" ON "public"."menu_items" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."user_businesses" "ub"
  WHERE (("ub"."business_id" = "menu_items"."business_id") AND ("ub"."user_id" = "auth"."uid"()) AND ("ub"."role" = ANY (ARRAY['owner'::"text", 'admin'::"text"])))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."user_businesses" "ub"
  WHERE (("ub"."business_id" = "menu_items"."business_id") AND ("ub"."user_id" = "auth"."uid"()) AND ("ub"."role" = ANY (ARRAY['owner'::"text", 'admin'::"text"]))))));



ALTER TABLE "public"."menus" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "menus_read" ON "public"."menus" FOR SELECT TO "authenticated" USING (("business_id" IN ( SELECT "public"."current_user_business_ids"() AS "current_user_business_ids")));



CREATE POLICY "menus_write" ON "public"."menus" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."user_businesses" "ub"
  WHERE (("ub"."business_id" = "menus"."business_id") AND ("ub"."user_id" = "auth"."uid"()) AND ("ub"."role" = ANY (ARRAY['owner'::"text", 'admin'::"text"])))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."user_businesses" "ub"
  WHERE (("ub"."business_id" = "menus"."business_id") AND ("ub"."user_id" = "auth"."uid"()) AND ("ub"."role" = ANY (ARRAY['owner'::"text", 'admin'::"text"]))))));



ALTER TABLE "public"."modifier_groups" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "modifier_groups_read" ON "public"."modifier_groups" FOR SELECT TO "authenticated" USING (("business_id" IN ( SELECT "public"."current_user_business_ids"() AS "current_user_business_ids")));



CREATE POLICY "modifier_groups_write" ON "public"."modifier_groups" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."user_businesses" "ub"
  WHERE (("ub"."business_id" = "modifier_groups"."business_id") AND ("ub"."user_id" = "auth"."uid"()) AND ("ub"."role" = ANY (ARRAY['owner'::"text", 'admin'::"text"])))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."user_businesses" "ub"
  WHERE (("ub"."business_id" = "modifier_groups"."business_id") AND ("ub"."user_id" = "auth"."uid"()) AND ("ub"."role" = ANY (ARRAY['owner'::"text", 'admin'::"text"]))))));



ALTER TABLE "public"."modifiers" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "modifiers_read" ON "public"."modifiers" FOR SELECT TO "authenticated" USING (("business_id" IN ( SELECT "public"."current_user_business_ids"() AS "current_user_business_ids")));



CREATE POLICY "modifiers_write" ON "public"."modifiers" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."user_businesses" "ub"
  WHERE (("ub"."business_id" = "modifiers"."business_id") AND ("ub"."user_id" = "auth"."uid"()) AND ("ub"."role" = ANY (ARRAY['owner'::"text", 'admin'::"text"])))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."user_businesses" "ub"
  WHERE (("ub"."business_id" = "modifiers"."business_id") AND ("ub"."user_id" = "auth"."uid"()) AND ("ub"."role" = ANY (ARRAY['owner'::"text", 'admin'::"text"]))))));



CREATE POLICY "ncf_seq_admin" ON "public"."ncf_sequences" TO "authenticated" USING (("public"."user_business_role"("auth"."uid"(), "business_id") = ANY (ARRAY['owner'::"text", 'admin'::"text"]))) WITH CHECK (("public"."user_business_role"("auth"."uid"(), "business_id") = ANY (ARRAY['owner'::"text", 'admin'::"text"])));



CREATE POLICY "ncf_seq_select" ON "public"."ncf_sequences" FOR SELECT TO "authenticated" USING ("public"."user_has_business_access"("auth"."uid"(), "business_id"));



ALTER TABLE "public"."ncf_sequences" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."order_checks" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."order_item_modifiers" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."order_items" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."orders" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "orders_all" ON "public"."orders" USING (("session_id" IN ( SELECT "s"."id"
   FROM (("public"."table_sessions" "s"
     JOIN "public"."dining_tables" "t" ON (("t"."id" = "s"."table_id")))
     JOIN "public"."zones" "z" ON (("z"."id" = "t"."zone_id")))
  WHERE ("z"."business_id" IN ( SELECT "public"."current_user_business_ids"() AS "current_user_business_ids"))))) WITH CHECK (("session_id" IN ( SELECT "s"."id"
   FROM (("public"."table_sessions" "s"
     JOIN "public"."dining_tables" "t" ON (("t"."id" = "s"."table_id")))
     JOIN "public"."zones" "z" ON (("z"."id" = "t"."zone_id")))
  WHERE ("z"."business_id" IN ( SELECT "public"."current_user_business_ids"() AS "current_user_business_ids")))));



CREATE POLICY "overrides by business" ON "public"."user_permission_overrides" USING ("public"."fn_user_in_business"("business_id"));



CREATE POLICY "pay_insert" ON "public"."payments" FOR INSERT TO "authenticated" WITH CHECK ("public"."user_has_business_access"("auth"."uid"(), "business_id"));



CREATE POLICY "pay_select" ON "public"."payments" FOR SELECT TO "authenticated" USING ("public"."user_has_business_access"("auth"."uid"(), "business_id"));



ALTER TABLE "public"."payment_methods" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."payments" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."permissions" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "pm_select" ON "public"."payment_methods" FOR SELECT TO "authenticated" USING ("public"."user_has_business_access"("auth"."uid"(), "business_id"));



CREATE POLICY "pm_write" ON "public"."payment_methods" TO "authenticated" USING (("public"."user_business_role"("auth"."uid"(), "business_id") = ANY (ARRAY['owner'::"text", 'admin'::"text"]))) WITH CHECK (("public"."user_business_role"("auth"."uid"(), "business_id") = ANY (ARRAY['owner'::"text", 'admin'::"text"])));



CREATE POLICY "po_select" ON "public"."purchase_orders" FOR SELECT TO "authenticated" USING ("public"."user_has_business_access"("auth"."uid"(), "business_id"));



CREATE POLICY "po_write" ON "public"."purchase_orders" TO "authenticated" USING (("public"."user_business_role"("auth"."uid"(), "business_id") = ANY (ARRAY['owner'::"text", 'admin'::"text"]))) WITH CHECK (("public"."user_business_role"("auth"."uid"(), "business_id") = ANY (ARRAY['owner'::"text", 'admin'::"text"])));



CREATE POLICY "poi_select" ON "public"."purchase_order_items" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."purchase_orders" "po"
  WHERE (("po"."id" = "purchase_order_items"."purchase_order_id") AND "public"."user_has_business_access"("auth"."uid"(), "po"."business_id")))));



ALTER TABLE "public"."point_transactions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."print_area_printers" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."print_areas" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."print_jobs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."printers" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "printers_delete_own_business" ON "public"."printers" FOR DELETE USING ((EXISTS ( SELECT 1
   FROM "public"."memberships" "m"
  WHERE (("m"."user_id" = "auth"."uid"()) AND ("m"."business_id" = "printers"."business_id")))));



CREATE POLICY "printers_insert_own_business" ON "public"."printers" FOR INSERT WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."memberships" "m"
  WHERE (("m"."user_id" = "auth"."uid"()) AND ("m"."business_id" = "printers"."business_id")))));



CREATE POLICY "printers_select_by_member" ON "public"."printers" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."memberships" "m"
  WHERE (("m"."user_id" = "auth"."uid"()) AND ("m"."business_id" = "printers"."business_id")))));



CREATE POLICY "printers_select_own_business" ON "public"."printers" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."memberships" "m"
  WHERE (("m"."user_id" = "auth"."uid"()) AND ("m"."business_id" = "printers"."business_id")))));



CREATE POLICY "printers_update_own_business" ON "public"."printers" FOR UPDATE USING ((EXISTS ( SELECT 1
   FROM "public"."memberships" "m"
  WHERE (("m"."user_id" = "auth"."uid"()) AND ("m"."business_id" = "printers"."business_id")))));



ALTER TABLE "public"."profiles" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "profiles_insert_own" ON "public"."profiles" FOR INSERT TO "authenticated" WITH CHECK (("id" = "auth"."uid"()));



CREATE POLICY "profiles_select_own" ON "public"."profiles" FOR SELECT TO "authenticated" USING (("id" = "auth"."uid"()));



CREATE POLICY "profiles_update_own" ON "public"."profiles" FOR UPDATE TO "authenticated" USING (("id" = "auth"."uid"())) WITH CHECK (("id" = "auth"."uid"()));



ALTER TABLE "public"."promotions" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "pt_select" ON "public"."point_transactions" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM ("public"."customer_points" "cp"
     JOIN "public"."customers" "c" ON (("c"."id" = "cp"."customer_id")))
  WHERE (("cp"."id" = "point_transactions"."customer_points_id") AND "public"."user_has_business_access"("auth"."uid"(), "c"."business_id")))));



ALTER TABLE "public"."purchase_order_items" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."purchase_orders" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "read area_printers members" ON "public"."print_area_printers" FOR SELECT USING ("public"."is_member_of_business"("business_id"));



CREATE POLICY "read areas members" ON "public"."print_areas" FOR SELECT USING ("public"."is_member_of_business"("business_id"));



CREATE POLICY "menu_item_taxes_read" ON "public"."menu_item_taxes" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM ("public"."menu_items" "mi"
     JOIN "public"."taxes" "t" ON (("t"."id" = "menu_item_taxes"."tax_id")))
  WHERE (("mi"."id" = "menu_item_taxes"."item_id") AND ("mi"."business_id" = "t"."business_id") AND "public"."user_has_business_access"("auth"."uid"(), "mi"."business_id")))));



CREATE POLICY "read printers members" ON "public"."printers" FOR SELECT USING ("public"."is_member_of_business"("business_id"));



CREATE POLICY "taxes_read" ON "public"."taxes" FOR SELECT TO "authenticated" USING ("public"."user_has_business_access"("auth"."uid"(), "business_id"));



CREATE POLICY "rec_select" ON "public"."recipes" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."menu_items" "mi"
  WHERE (("mi"."id" = "recipes"."menu_item_id") AND "public"."user_has_business_access"("auth"."uid"(), "mi"."business_id")))));



CREATE POLICY "rec_write" ON "public"."recipes" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."menu_items" "mi"
  WHERE (("mi"."id" = "recipes"."menu_item_id") AND ("public"."user_business_role"("auth"."uid"(), "mi"."business_id") = ANY (ARRAY['owner'::"text", 'admin'::"text"])))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."menu_items" "mi"
  WHERE (("mi"."id" = "recipes"."menu_item_id") AND ("public"."user_business_role"("auth"."uid"(), "mi"."business_id") = ANY (ARRAY['owner'::"text", 'admin'::"text"]))))));



ALTER TABLE "public"."recipe_ingredients" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."recipes" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "ri_select" ON "public"."recipe_ingredients" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM ("public"."recipes" "r"
     JOIN "public"."menu_items" "mi" ON (("mi"."id" = "r"."menu_item_id")))
  WHERE (("r"."id" = "recipe_ingredients"."recipe_id") AND "public"."user_has_business_access"("auth"."uid"(), "mi"."business_id")))));



CREATE POLICY "ri_write" ON "public"."recipe_ingredients" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM ("public"."recipes" "r"
     JOIN "public"."menu_items" "mi" ON (("mi"."id" = "r"."menu_item_id")))
  WHERE (("r"."id" = "recipe_ingredients"."recipe_id") AND ("public"."user_business_role"("auth"."uid"(), "mi"."business_id") = ANY (ARRAY['owner'::"text", 'admin'::"text"])))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM (("public"."recipes" "r"
     JOIN "public"."menu_items" "mi" ON (("mi"."id" = "r"."menu_item_id")))
     JOIN "public"."inventory_items" "ii" ON (("ii"."id" = "recipe_ingredients"."inventory_item_id")))
  WHERE (("r"."id" = "recipe_ingredients"."recipe_id") AND ("ii"."business_id" = "mi"."business_id") AND ("public"."user_business_role"("auth"."uid"(), "mi"."business_id") = ANY (ARRAY['owner'::"text", 'admin'::"text"]))))));



ALTER TABLE "public"."role_permissions" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "role_permissions by business" ON "public"."role_permissions" USING ((EXISTS ( SELECT 1
   FROM "public"."roles" "r"
  WHERE (("r"."id" = "role_permissions"."role_id") AND "public"."fn_user_in_business"("r"."business_id")))));



ALTER TABLE "public"."roles" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "roles by business" ON "public"."roles" USING ("public"."fn_user_in_business"("business_id"));



CREATE POLICY "select_own_business" ON "public"."print_jobs" FOR SELECT USING (("business_id" = (("auth"."jwt"() ->> 'business_id'::"text"))::"uuid"));



CREATE POLICY "sessions_all" ON "public"."table_sessions" USING (("table_id" IN ( SELECT "t"."id"
   FROM ("public"."dining_tables" "t"
     JOIN "public"."zones" "z" ON (("z"."id" = "t"."zone_id")))
  WHERE ("z"."business_id" IN ( SELECT "public"."current_user_business_ids"() AS "current_user_business_ids"))))) WITH CHECK (("table_id" IN ( SELECT "t"."id"
   FROM ("public"."dining_tables" "t"
     JOIN "public"."zones" "z" ON (("z"."id" = "t"."zone_id")))
  WHERE ("z"."business_id" IN ( SELECT "public"."current_user_business_ids"() AS "current_user_business_ids")))));



ALTER TABLE "public"."shifts" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "sup_admin" ON "public"."suppliers" TO "authenticated" USING (("public"."user_business_role"("auth"."uid"(), "business_id") = ANY (ARRAY['owner'::"text", 'admin'::"text"]))) WITH CHECK (("public"."user_business_role"("auth"."uid"(), "business_id") = ANY (ARRAY['owner'::"text", 'admin'::"text"])));



CREATE POLICY "sup_select" ON "public"."suppliers" FOR SELECT TO "authenticated" USING ("public"."user_has_business_access"("auth"."uid"(), "business_id"));



ALTER TABLE "public"."suppliers" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."table_sessions" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "tables_modify" ON "public"."dining_tables" USING (("zone_id" IN ( SELECT "zones"."id"
   FROM "public"."zones"
  WHERE ("zones"."business_id" IN ( SELECT "public"."current_user_business_ids"() AS "current_user_business_ids"))))) WITH CHECK (("zone_id" IN ( SELECT "zones"."id"
   FROM "public"."zones"
  WHERE ("zones"."business_id" IN ( SELECT "public"."current_user_business_ids"() AS "current_user_business_ids")))));



CREATE POLICY "tables_select" ON "public"."dining_tables" FOR SELECT USING (("zone_id" IN ( SELECT "zones"."id"
   FROM "public"."zones"
  WHERE ("zones"."business_id" IN ( SELECT "public"."current_user_business_ids"() AS "current_user_business_ids")))));



ALTER TABLE "public"."taxes" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "tenant_read" ON "public"."menus" FOR SELECT TO "authenticated" USING (("business_id" IN ( SELECT "public"."current_user_business_ids"() AS "current_user_business_ids")));



CREATE POLICY "tenant_write" ON "public"."menus" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."user_businesses" "ub"
  WHERE (("ub"."business_id" = "menus"."business_id") AND ("ub"."user_id" = "auth"."uid"()) AND ("ub"."role" = ANY (ARRAY['owner'::"text", 'admin'::"text"])))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."user_businesses" "ub"
  WHERE (("ub"."business_id" = "menus"."business_id") AND ("ub"."user_id" = "auth"."uid"()) AND ("ub"."role" = ANY (ARRAY['owner'::"text", 'admin'::"text"]))))));



CREATE POLICY "update areas admins" ON "public"."print_areas" FOR UPDATE USING ("public"."is_admin_of_business"("business_id"));



CREATE POLICY "update printers admins" ON "public"."printers" FOR UPDATE USING ("public"."is_admin_of_business"("business_id"));



CREATE POLICY "upsert area_printers admins" ON "public"."print_area_printers" USING ("public"."is_admin_of_business"("business_id")) WITH CHECK ("public"."is_admin_of_business"("business_id"));



ALTER TABLE "public"."user_businesses" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "user_businesses_insert_self" ON "public"."user_businesses" FOR INSERT TO "authenticated" WITH CHECK (("user_id" = "auth"."uid"()));



CREATE POLICY "user_businesses_select_own" ON "public"."user_businesses" FOR SELECT TO "authenticated" USING (("user_id" = "auth"."uid"()));



ALTER TABLE "public"."user_permission_overrides" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."user_roles" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "user_roles by business" ON "public"."user_roles" USING ("public"."fn_user_in_business"("business_id"));



ALTER TABLE "public"."warehouses" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "wh_admin" ON "public"."warehouses" TO "authenticated" USING (("public"."user_business_role"("auth"."uid"(), "business_id") = ANY (ARRAY['owner'::"text", 'admin'::"text"]))) WITH CHECK (("public"."user_business_role"("auth"."uid"(), "business_id") = ANY (ARRAY['owner'::"text", 'admin'::"text"])));



CREATE POLICY "wh_select" ON "public"."warehouses" FOR SELECT TO "authenticated" USING ("public"."user_has_business_access"("auth"."uid"(), "business_id"));



CREATE POLICY "menu_item_taxes_write" ON "public"."menu_item_taxes" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM ("public"."menu_items" "mi"
     JOIN "public"."taxes" "t" ON (("t"."id" = "menu_item_taxes"."tax_id")))
  WHERE (("mi"."id" = "menu_item_taxes"."item_id") AND ("mi"."business_id" = "t"."business_id") AND ("public"."user_business_role"("auth"."uid"(), "mi"."business_id") = ANY (ARRAY['owner'::"text", 'admin'::"text"])))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM ("public"."menu_items" "mi"
     JOIN "public"."taxes" "t" ON (("t"."id" = "menu_item_taxes"."tax_id")))
  WHERE (("mi"."id" = "menu_item_taxes"."item_id") AND ("mi"."business_id" = "t"."business_id") AND ("public"."user_business_role"("auth"."uid"(), "mi"."business_id") = ANY (ARRAY['owner'::"text", 'admin'::"text"]))))));



CREATE POLICY "taxes_write" ON "public"."taxes" TO "authenticated" USING (("public"."user_business_role"("auth"."uid"(), "business_id") = ANY (ARRAY['owner'::"text", 'admin'::"text"]))) WITH CHECK (("public"."user_business_role"("auth"."uid"(), "business_id") = ANY (ARRAY['owner'::"text", 'admin'::"text"])));



ALTER TABLE "public"."zones" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "zones_delete" ON "public"."zones" FOR DELETE TO "authenticated" USING (("business_id" IN ( SELECT "public"."current_user_business_ids"() AS "current_user_business_ids")));



CREATE POLICY "zones_insert" ON "public"."zones" FOR INSERT TO "authenticated" WITH CHECK (("business_id" IN ( SELECT "public"."current_user_business_ids"() AS "current_user_business_ids")));



CREATE POLICY "zones_modify" ON "public"."zones" USING (("business_id" IN ( SELECT "public"."current_user_business_ids"() AS "current_user_business_ids"))) WITH CHECK (("business_id" IN ( SELECT "public"."current_user_business_ids"() AS "current_user_business_ids")));



CREATE POLICY "zones_select" ON "public"."zones" FOR SELECT TO "authenticated" USING (("business_id" IN ( SELECT "public"."current_user_business_ids"() AS "current_user_business_ids")));



CREATE POLICY "zones_update" ON "public"."zones" FOR UPDATE TO "authenticated" USING (("business_id" IN ( SELECT "public"."current_user_business_ids"() AS "current_user_business_ids"))) WITH CHECK (("business_id" IN ( SELECT "public"."current_user_business_ids"() AS "current_user_business_ids")));



GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";



GRANT ALL ON FUNCTION "public"."agent_claim_next_job"("p_agent_key" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."agent_claim_next_job"("p_agent_key" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."agent_claim_next_job"("p_agent_key" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."agent_report_result"("p_agent_key" "text", "p_job_id" "uuid", "p_status" "text", "p_err" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."agent_report_result"("p_agent_key" "text", "p_job_id" "uuid", "p_status" "text", "p_err" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."agent_report_result"("p_agent_key" "text", "p_job_id" "uuid", "p_status" "text", "p_err" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."agent_upsert_printer"("p_agent_key" "text", "p_job_id" "uuid", "p_ip" "text", "p_name" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."agent_upsert_printer"("p_agent_key" "text", "p_job_id" "uuid", "p_ip" "text", "p_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."agent_upsert_printer"("p_agent_key" "text", "p_job_id" "uuid", "p_ip" "text", "p_name" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."calculate_check_totals"("_check_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."calculate_check_totals"("_check_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."calculate_check_totals"("_check_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."calculate_order_totals"("_order_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."calculate_order_totals"("_order_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."calculate_order_totals"("_order_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."consume_inventory_from_order"("_order_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."consume_inventory_from_order"("_order_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."consume_inventory_from_order"("_order_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."create_business_defaults"("_business_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."create_business_defaults"("_business_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_business_defaults"("_business_id" "uuid") TO "service_role";



GRANT ALL ON TABLE "public"."fiscal_documents" TO "anon";
GRANT ALL ON TABLE "public"."fiscal_documents" TO "authenticated";
GRANT ALL ON TABLE "public"."fiscal_documents" TO "service_role";



GRANT ALL ON FUNCTION "public"."create_fiscal_document"("p_order_id" "uuid", "p_payment_id" "uuid", "p_customer_id" "uuid", "p_customer_rnc" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."create_fiscal_document"("p_order_id" "uuid", "p_payment_id" "uuid", "p_customer_id" "uuid", "p_customer_rnc" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_fiscal_document"("p_order_id" "uuid", "p_payment_id" "uuid", "p_customer_id" "uuid", "p_customer_rnc" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."current_user_business_ids"() TO "anon";
GRANT ALL ON FUNCTION "public"."current_user_business_ids"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."current_user_business_ids"() TO "service_role";



GRANT ALL ON FUNCTION "public"."enforce_prep_minutes"() TO "anon";
GRANT ALL ON FUNCTION "public"."enforce_prep_minutes"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."enforce_prep_minutes"() TO "service_role";



GRANT ALL ON FUNCTION "public"."enqueue_print_test"("p_printer_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."enqueue_print_test"("p_printer_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."enqueue_print_test"("p_printer_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_add_item_from_menu"("p_order_id" "uuid", "p_menu_item_id" "uuid", "p_qty" numeric, "p_check_position" integer, "p_is_takeout" boolean, "p_notes" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."fn_add_item_from_menu"("p_order_id" "uuid", "p_menu_item_id" "uuid", "p_qty" numeric, "p_check_position" integer, "p_is_takeout" boolean, "p_notes" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_add_item_from_menu"("p_order_id" "uuid", "p_menu_item_id" "uuid", "p_qty" numeric, "p_check_position" integer, "p_is_takeout" boolean, "p_notes" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_after_item_change"() TO "anon";
GRANT ALL ON FUNCTION "public"."fn_after_item_change"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_after_item_change"() TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_check_max_checks"() TO "anon";
GRANT ALL ON FUNCTION "public"."fn_check_max_checks"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_check_max_checks"() TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_close_cash_session"("p_session_id" "uuid", "p_end_amount" numeric, "p_notes" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."fn_close_cash_session"("p_session_id" "uuid", "p_end_amount" numeric, "p_notes" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_close_cash_session"("p_session_id" "uuid", "p_end_amount" numeric, "p_notes" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_close_order_and_table"("p_order_id" "uuid", "p_status" "public"."order_status") TO "anon";
GRANT ALL ON FUNCTION "public"."fn_close_order_and_table"("p_order_id" "uuid", "p_status" "public"."order_status") TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_close_order_and_table"("p_order_id" "uuid", "p_status" "public"."order_status") TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_compute_item_totals"() TO "anon";
GRANT ALL ON FUNCTION "public"."fn_compute_item_totals"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_compute_item_totals"() TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_confirm_order_to_kitchen"("p_order_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."fn_confirm_order_to_kitchen"("p_order_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_confirm_order_to_kitchen"("p_order_id" "uuid") TO "service_role";



GRANT ALL ON TABLE "public"."order_checks" TO "anon";
GRANT ALL ON TABLE "public"."order_checks" TO "authenticated";
GRANT ALL ON TABLE "public"."order_checks" TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_create_split_bill"("p_order_id" "uuid", "p_number_of_checks" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."fn_create_split_bill"("p_order_id" "uuid", "p_number_of_checks" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_create_split_bill"("p_order_id" "uuid", "p_number_of_checks" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_get_cash_session_summary"("p_session_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."fn_get_cash_session_summary"("p_session_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_get_cash_session_summary"("p_session_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_get_or_create_check"("p_order_id" "uuid", "p_position" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."fn_get_or_create_check"("p_order_id" "uuid", "p_position" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_get_or_create_check"("p_order_id" "uuid", "p_position" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_get_or_create_virtual_table"("p_business_id" "uuid", "p_origin" "public"."order_origin") TO "anon";
GRANT ALL ON FUNCTION "public"."fn_get_or_create_virtual_table"("p_business_id" "uuid", "p_origin" "public"."order_origin") TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_get_or_create_virtual_table"("p_business_id" "uuid", "p_origin" "public"."order_origin") TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_mark_order_ready"("p_order_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."fn_mark_order_ready"("p_order_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_mark_order_ready"("p_order_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_mark_order_takeout"("p_order_id" "uuid", "p_takeout" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."fn_mark_order_takeout"("p_order_id" "uuid", "p_takeout" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_mark_order_takeout"("p_order_id" "uuid", "p_takeout" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_move_item_to_check"("p_item_id" "uuid", "p_check_position" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."fn_move_item_to_check"("p_item_id" "uuid", "p_check_position" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_move_item_to_check"("p_item_id" "uuid", "p_check_position" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_normalize_domain"() TO "anon";
GRANT ALL ON FUNCTION "public"."fn_normalize_domain"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_normalize_domain"() TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_oi_sync_qty_quantity"() TO "anon";
GRANT ALL ON FUNCTION "public"."fn_oi_sync_qty_quantity"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_oi_sync_qty_quantity"() TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_open_cash_session"("p_cash_register_id" "uuid", "p_user_id" "uuid", "p_start_amount" numeric) TO "anon";
GRANT ALL ON FUNCTION "public"."fn_open_cash_session"("p_cash_register_id" "uuid", "p_user_id" "uuid", "p_start_amount" numeric) TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_open_cash_session"("p_cash_register_id" "uuid", "p_user_id" "uuid", "p_start_amount" numeric) TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_open_manual_or_quick"("p_origin" "public"."order_origin", "p_user_id" "uuid", "p_people_count" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."fn_open_manual_or_quick"("p_origin" "public"."order_origin", "p_user_id" "uuid", "p_people_count" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_open_manual_or_quick"("p_origin" "public"."order_origin", "p_user_id" "uuid", "p_people_count" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_open_table"("p_table_id" "uuid", "p_user_id" "uuid", "p_people_count" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."fn_open_table"("p_table_id" "uuid", "p_user_id" "uuid", "p_people_count" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_open_table"("p_table_id" "uuid", "p_user_id" "uuid", "p_people_count" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_pick_member_for_table"("p_table_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."fn_pick_member_for_table"("p_table_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_pick_member_for_table"("p_table_id" "uuid") TO "service_role";



GRANT ALL ON TABLE "public"."payments" TO "anon";
GRANT ALL ON TABLE "public"."payments" TO "authenticated";
GRANT ALL ON TABLE "public"."payments" TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_process_payment"("p_order_id" "uuid", "p_check_id" "uuid", "p_payment_method_id" "text", "p_amount" numeric, "p_reference" "text", "p_customer_id" "uuid", "p_customer_rnc" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."fn_process_payment"("p_order_id" "uuid", "p_check_id" "uuid", "p_payment_method_id" "text", "p_amount" numeric, "p_reference" "text", "p_customer_id" "uuid", "p_customer_rnc" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_process_payment"("p_order_id" "uuid", "p_check_id" "uuid", "p_payment_method_id" "text", "p_amount" numeric, "p_reference" "text", "p_customer_id" "uuid", "p_customer_rnc" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_process_payment_v2"("p_order_id" "uuid", "p_check_id" "uuid", "p_payment_method_id" "text", "p_amount" numeric, "p_reference" "text", "p_customer_id" "uuid", "p_customer_rnc" "text", "p_cashier_session_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."fn_process_payment_v2"("p_order_id" "uuid", "p_check_id" "uuid", "p_payment_method_id" "text", "p_amount" numeric, "p_reference" "text", "p_customer_id" "uuid", "p_customer_rnc" "text", "p_cashier_session_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_process_payment_v2"("p_order_id" "uuid", "p_check_id" "uuid", "p_payment_method_id" "text", "p_amount" numeric, "p_reference" "text", "p_customer_id" "uuid", "p_customer_rnc" "text", "p_cashier_session_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."fn_process_payment_v3"("p_order_id" "uuid", "p_check_id" "uuid", "p_payment_method_id" "text", "p_amount" numeric, "p_reference" "text", "p_customer_id" "uuid", "p_customer_rnc" "text", "p_cashier_session_id" "uuid", "p_change_amount" numeric) TO "anon";
GRANT ALL ON FUNCTION "public"."fn_process_payment_v3"("p_order_id" "uuid", "p_check_id" "uuid", "p_payment_method_id" "text", "p_amount" numeric, "p_reference" "text", "p_customer_id" "uuid", "p_customer_rnc" "text", "p_cashier_session_id" "uuid", "p_change_amount" numeric) TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_process_payment_v3"("p_order_id" "uuid", "p_check_id" "uuid", "p_payment_method_id" "text", "p_amount" numeric, "p_reference" "text", "p_customer_id" "uuid", "p_customer_rnc" "text", "p_cashier_session_id" "uuid", "p_change_amount" numeric) TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_recalc_order_totals"("p_order_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."fn_recalc_order_totals"("p_order_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_recalc_order_totals"("p_order_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_start_preparing_order"("p_order_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."fn_start_preparing_order"("p_order_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_start_preparing_order"("p_order_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_toggle_item_takeout"("p_item_id" "uuid", "p_takeout" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."fn_toggle_item_takeout"("p_item_id" "uuid", "p_takeout" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_toggle_item_takeout"("p_item_id" "uuid", "p_takeout" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_user_effective_permissions"("p_user_id" "uuid", "p_business_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."fn_user_effective_permissions"("p_user_id" "uuid", "p_business_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_user_effective_permissions"("p_user_id" "uuid", "p_business_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_user_in_business"("p_business_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."fn_user_in_business"("p_business_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_user_in_business"("p_business_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."generate_ncf"("_business_id" "uuid", "_ncf_type" "public"."ncf_type") TO "anon";
GRANT ALL ON FUNCTION "public"."generate_ncf"("_business_id" "uuid", "_ncf_type" "public"."ncf_type") TO "authenticated";
GRANT ALL ON FUNCTION "public"."generate_ncf"("_business_id" "uuid", "_ncf_type" "public"."ncf_type") TO "service_role";



GRANT ALL ON FUNCTION "public"."has_business_role"("_user_id" "uuid", "_business_id" "uuid", "_roles" "text"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."has_business_role"("_user_id" "uuid", "_business_id" "uuid", "_roles" "text"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."has_business_role"("_user_id" "uuid", "_business_id" "uuid", "_roles" "text"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."is_admin_of_business"("p_business" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."is_admin_of_business"("p_business" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_admin_of_business"("p_business" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."is_business_owner"("biz" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."is_business_owner"("biz" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_business_owner"("biz" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."is_member_of_business"("p_business" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."is_member_of_business"("p_business" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_member_of_business"("p_business" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."issue_fiscal_document"("_order_id" "uuid", "_payment_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."issue_fiscal_document"("_order_id" "uuid", "_payment_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."issue_fiscal_document"("_order_id" "uuid", "_payment_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."set_employees_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."set_employees_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_employees_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."set_table_session_business_id"() TO "anon";
GRANT ALL ON FUNCTION "public"."set_table_session_business_id"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_table_session_business_id"() TO "service_role";



GRANT ALL ON FUNCTION "public"."set_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."set_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trigger_create_business_defaults"() TO "anon";
GRANT ALL ON FUNCTION "public"."trigger_create_business_defaults"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trigger_create_business_defaults"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trigger_increment_coupon_usage"() TO "anon";
GRANT ALL ON FUNCTION "public"."trigger_increment_coupon_usage"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trigger_increment_coupon_usage"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trigger_inventory_on_order_sent"() TO "anon";
GRANT ALL ON FUNCTION "public"."trigger_inventory_on_order_sent"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trigger_inventory_on_order_sent"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trigger_issue_fiscal_on_payment"() TO "anon";
GRANT ALL ON FUNCTION "public"."trigger_issue_fiscal_on_payment"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trigger_issue_fiscal_on_payment"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trigger_set_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."trigger_set_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trigger_set_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trigger_update_order_totals"() TO "anon";
GRANT ALL ON FUNCTION "public"."trigger_update_order_totals"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trigger_update_order_totals"() TO "service_role";



GRANT ALL ON FUNCTION "public"."user_business_role"("_user_id" "uuid", "_business_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."user_business_role"("_user_id" "uuid", "_business_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."user_business_role"("_user_id" "uuid", "_business_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."user_has_business_access"("_user_id" "uuid", "_business_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."user_has_business_access"("_user_id" "uuid", "_business_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."user_has_business_access"("_user_id" "uuid", "_business_id" "uuid") TO "service_role";



GRANT ALL ON TABLE "public"."agent_nodes" TO "anon";
GRANT ALL ON TABLE "public"."agent_nodes" TO "authenticated";
GRANT ALL ON TABLE "public"."agent_nodes" TO "service_role";



GRANT ALL ON TABLE "public"."attendance" TO "anon";
GRANT ALL ON TABLE "public"."attendance" TO "authenticated";
GRANT ALL ON TABLE "public"."attendance" TO "service_role";



GRANT ALL ON TABLE "public"."audit_logs" TO "anon";
GRANT ALL ON TABLE "public"."audit_logs" TO "authenticated";
GRANT ALL ON TABLE "public"."audit_logs" TO "service_role";



GRANT ALL ON TABLE "public"."business_settings" TO "anon";
GRANT ALL ON TABLE "public"."business_settings" TO "authenticated";
GRANT ALL ON TABLE "public"."business_settings" TO "service_role";



GRANT ALL ON TABLE "public"."businesses" TO "anon";
GRANT ALL ON TABLE "public"."businesses" TO "authenticated";
GRANT ALL ON TABLE "public"."businesses" TO "service_role";



GRANT ALL ON TABLE "public"."cash_register_sessions" TO "anon";
GRANT ALL ON TABLE "public"."cash_register_sessions" TO "authenticated";
GRANT ALL ON TABLE "public"."cash_register_sessions" TO "service_role";



GRANT ALL ON TABLE "public"."cash_registers" TO "anon";
GRANT ALL ON TABLE "public"."cash_registers" TO "authenticated";
GRANT ALL ON TABLE "public"."cash_registers" TO "service_role";



GRANT ALL ON TABLE "public"."cash_transactions" TO "anon";
GRANT ALL ON TABLE "public"."cash_transactions" TO "authenticated";
GRANT ALL ON TABLE "public"."cash_transactions" TO "service_role";



GRANT ALL ON TABLE "public"."categories" TO "anon";
GRANT ALL ON TABLE "public"."categories" TO "authenticated";
GRANT ALL ON TABLE "public"."categories" TO "service_role";



GRANT ALL ON TABLE "public"."coupon_usage" TO "anon";
GRANT ALL ON TABLE "public"."coupon_usage" TO "authenticated";
GRANT ALL ON TABLE "public"."coupon_usage" TO "service_role";



GRANT ALL ON TABLE "public"."coupons" TO "anon";
GRANT ALL ON TABLE "public"."coupons" TO "authenticated";
GRANT ALL ON TABLE "public"."coupons" TO "service_role";



GRANT ALL ON TABLE "public"."credit_payments" TO "anon";
GRANT ALL ON TABLE "public"."credit_payments" TO "authenticated";
GRANT ALL ON TABLE "public"."credit_payments" TO "service_role";



GRANT ALL ON TABLE "public"."currencies" TO "anon";
GRANT ALL ON TABLE "public"."currencies" TO "authenticated";
GRANT ALL ON TABLE "public"."currencies" TO "service_role";



GRANT ALL ON TABLE "public"."customer_credits" TO "anon";
GRANT ALL ON TABLE "public"."customer_credits" TO "authenticated";
GRANT ALL ON TABLE "public"."customer_credits" TO "service_role";



GRANT ALL ON TABLE "public"."customer_points" TO "anon";
GRANT ALL ON TABLE "public"."customer_points" TO "authenticated";
GRANT ALL ON TABLE "public"."customer_points" TO "service_role";



GRANT ALL ON TABLE "public"."customers" TO "anon";
GRANT ALL ON TABLE "public"."customers" TO "authenticated";
GRANT ALL ON TABLE "public"."customers" TO "service_role";



GRANT ALL ON TABLE "public"."dining_tables" TO "anon";
GRANT ALL ON TABLE "public"."dining_tables" TO "authenticated";
GRANT ALL ON TABLE "public"."dining_tables" TO "service_role";



GRANT ALL ON TABLE "public"."discovery_jobs" TO "anon";
GRANT ALL ON TABLE "public"."discovery_jobs" TO "authenticated";
GRANT ALL ON TABLE "public"."discovery_jobs" TO "service_role";



GRANT ALL ON TABLE "public"."employee_benefits" TO "anon";
GRANT ALL ON TABLE "public"."employee_benefits" TO "authenticated";
GRANT ALL ON TABLE "public"."employee_benefits" TO "service_role";



GRANT ALL ON TABLE "public"."employee_roles" TO "anon";
GRANT ALL ON TABLE "public"."employee_roles" TO "authenticated";
GRANT ALL ON TABLE "public"."employee_roles" TO "service_role";



GRANT ALL ON TABLE "public"."employees" TO "anon";
GRANT ALL ON TABLE "public"."employees" TO "authenticated";
GRANT ALL ON TABLE "public"."employees" TO "service_role";



GRANT ALL ON TABLE "public"."fiscal_document_items" TO "anon";
GRANT ALL ON TABLE "public"."fiscal_document_items" TO "authenticated";
GRANT ALL ON TABLE "public"."fiscal_document_items" TO "service_role";



GRANT ALL ON TABLE "public"."fiscal_settings" TO "anon";
GRANT ALL ON TABLE "public"."fiscal_settings" TO "authenticated";
GRANT ALL ON TABLE "public"."fiscal_settings" TO "service_role";



GRANT ALL ON TABLE "public"."gift_card_transactions" TO "anon";
GRANT ALL ON TABLE "public"."gift_card_transactions" TO "authenticated";
GRANT ALL ON TABLE "public"."gift_card_transactions" TO "service_role";



GRANT ALL ON TABLE "public"."gift_cards" TO "anon";
GRANT ALL ON TABLE "public"."gift_cards" TO "authenticated";
GRANT ALL ON TABLE "public"."gift_cards" TO "service_role";



GRANT ALL ON TABLE "public"."inventory_items" TO "anon";
GRANT ALL ON TABLE "public"."inventory_items" TO "authenticated";
GRANT ALL ON TABLE "public"."inventory_items" TO "service_role";



GRANT ALL ON TABLE "public"."inventory_movements" TO "anon";
GRANT ALL ON TABLE "public"."inventory_movements" TO "authenticated";
GRANT ALL ON TABLE "public"."inventory_movements" TO "service_role";



GRANT ALL ON TABLE "public"."inventory_stock" TO "anon";
GRANT ALL ON TABLE "public"."inventory_stock" TO "authenticated";
GRANT ALL ON TABLE "public"."inventory_stock" TO "service_role";



GRANT ALL ON TABLE "public"."order_item_modifiers" TO "anon";
GRANT ALL ON TABLE "public"."order_item_modifiers" TO "authenticated";
GRANT ALL ON TABLE "public"."order_item_modifiers" TO "service_role";



GRANT ALL ON TABLE "public"."order_items" TO "anon";
GRANT ALL ON TABLE "public"."order_items" TO "authenticated";
GRANT ALL ON TABLE "public"."order_items" TO "service_role";



GRANT ALL ON TABLE "public"."orders" TO "anon";
GRANT ALL ON TABLE "public"."orders" TO "authenticated";
GRANT ALL ON TABLE "public"."orders" TO "service_role";



GRANT ALL ON TABLE "public"."profiles" TO "anon";
GRANT ALL ON TABLE "public"."profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."profiles" TO "service_role";



GRANT ALL ON TABLE "public"."table_sessions" TO "anon";
GRANT ALL ON TABLE "public"."table_sessions" TO "authenticated";
GRANT ALL ON TABLE "public"."table_sessions" TO "service_role";



GRANT ALL ON TABLE "public"."zones" TO "anon";
GRANT ALL ON TABLE "public"."zones" TO "authenticated";
GRANT ALL ON TABLE "public"."zones" TO "service_role";



GRANT ALL ON TABLE "public"."kds_active_items" TO "anon";
GRANT ALL ON TABLE "public"."kds_active_items" TO "authenticated";
GRANT ALL ON TABLE "public"."kds_active_items" TO "service_role";



GRANT ALL ON TABLE "public"."loyalty_programs" TO "anon";
GRANT ALL ON TABLE "public"."loyalty_programs" TO "authenticated";
GRANT ALL ON TABLE "public"."loyalty_programs" TO "service_role";



GRANT ALL ON TABLE "public"."me_permissions" TO "anon";
GRANT ALL ON TABLE "public"."me_permissions" TO "authenticated";
GRANT ALL ON TABLE "public"."me_permissions" TO "service_role";



GRANT ALL ON TABLE "public"."memberships" TO "anon";
GRANT ALL ON TABLE "public"."memberships" TO "authenticated";
GRANT ALL ON TABLE "public"."memberships" TO "service_role";



GRANT ALL ON TABLE "public"."menu_item_groups" TO "anon";
GRANT ALL ON TABLE "public"."menu_item_groups" TO "authenticated";
GRANT ALL ON TABLE "public"."menu_item_groups" TO "service_role";



GRANT ALL ON TABLE "public"."menu_item_links" TO "anon";
GRANT ALL ON TABLE "public"."menu_item_links" TO "authenticated";
GRANT ALL ON TABLE "public"."menu_item_links" TO "service_role";



GRANT ALL ON TABLE "public"."menu_item_taxes" TO "anon";
GRANT ALL ON TABLE "public"."menu_item_taxes" TO "authenticated";
GRANT ALL ON TABLE "public"."menu_item_taxes" TO "service_role";



GRANT ALL ON TABLE "public"."menu_items" TO "anon";
GRANT ALL ON TABLE "public"."menu_items" TO "authenticated";
GRANT ALL ON TABLE "public"."menu_items" TO "service_role";



GRANT ALL ON TABLE "public"."menus" TO "anon";
GRANT ALL ON TABLE "public"."menus" TO "authenticated";
GRANT ALL ON TABLE "public"."menus" TO "service_role";



GRANT ALL ON TABLE "public"."modifier_groups" TO "anon";
GRANT ALL ON TABLE "public"."modifier_groups" TO "authenticated";
GRANT ALL ON TABLE "public"."modifier_groups" TO "service_role";



GRANT ALL ON TABLE "public"."modifiers" TO "anon";
GRANT ALL ON TABLE "public"."modifiers" TO "authenticated";
GRANT ALL ON TABLE "public"."modifiers" TO "service_role";



GRANT ALL ON TABLE "public"."ncf_sequences" TO "anon";
GRANT ALL ON TABLE "public"."ncf_sequences" TO "authenticated";
GRANT ALL ON TABLE "public"."ncf_sequences" TO "service_role";



GRANT ALL ON TABLE "public"."payment_methods" TO "anon";
GRANT ALL ON TABLE "public"."payment_methods" TO "authenticated";
GRANT ALL ON TABLE "public"."payment_methods" TO "service_role";



GRANT ALL ON TABLE "public"."permissions" TO "anon";
GRANT ALL ON TABLE "public"."permissions" TO "authenticated";
GRANT ALL ON TABLE "public"."permissions" TO "service_role";



GRANT ALL ON TABLE "public"."point_transactions" TO "anon";
GRANT ALL ON TABLE "public"."point_transactions" TO "authenticated";
GRANT ALL ON TABLE "public"."point_transactions" TO "service_role";



GRANT ALL ON TABLE "public"."print_area_printers" TO "anon";
GRANT ALL ON TABLE "public"."print_area_printers" TO "authenticated";
GRANT ALL ON TABLE "public"."print_area_printers" TO "service_role";



GRANT ALL ON TABLE "public"."print_areas" TO "anon";
GRANT ALL ON TABLE "public"."print_areas" TO "authenticated";
GRANT ALL ON TABLE "public"."print_areas" TO "service_role";



GRANT ALL ON TABLE "public"."print_areas_view" TO "anon";
GRANT ALL ON TABLE "public"."print_areas_view" TO "authenticated";
GRANT ALL ON TABLE "public"."print_areas_view" TO "service_role";



GRANT ALL ON TABLE "public"."print_jobs" TO "anon";
GRANT ALL ON TABLE "public"."print_jobs" TO "authenticated";
GRANT ALL ON TABLE "public"."print_jobs" TO "service_role";



GRANT ALL ON TABLE "public"."printers" TO "anon";
GRANT ALL ON TABLE "public"."printers" TO "authenticated";
GRANT ALL ON TABLE "public"."printers" TO "service_role";



GRANT ALL ON TABLE "public"."promotions" TO "anon";
GRANT ALL ON TABLE "public"."promotions" TO "authenticated";
GRANT ALL ON TABLE "public"."promotions" TO "service_role";



GRANT ALL ON TABLE "public"."purchase_order_items" TO "anon";
GRANT ALL ON TABLE "public"."purchase_order_items" TO "authenticated";
GRANT ALL ON TABLE "public"."purchase_order_items" TO "service_role";



GRANT ALL ON TABLE "public"."purchase_orders" TO "anon";
GRANT ALL ON TABLE "public"."purchase_orders" TO "authenticated";
GRANT ALL ON TABLE "public"."purchase_orders" TO "service_role";



GRANT ALL ON TABLE "public"."recipe_ingredients" TO "anon";
GRANT ALL ON TABLE "public"."recipe_ingredients" TO "authenticated";
GRANT ALL ON TABLE "public"."recipe_ingredients" TO "service_role";



GRANT ALL ON TABLE "public"."recipes" TO "anon";
GRANT ALL ON TABLE "public"."recipes" TO "authenticated";
GRANT ALL ON TABLE "public"."recipes" TO "service_role";



GRANT ALL ON TABLE "public"."role_permissions" TO "anon";
GRANT ALL ON TABLE "public"."role_permissions" TO "authenticated";
GRANT ALL ON TABLE "public"."role_permissions" TO "service_role";



GRANT ALL ON TABLE "public"."roles" TO "anon";
GRANT ALL ON TABLE "public"."roles" TO "authenticated";
GRANT ALL ON TABLE "public"."roles" TO "service_role";



GRANT ALL ON TABLE "public"."shifts" TO "anon";
GRANT ALL ON TABLE "public"."shifts" TO "authenticated";
GRANT ALL ON TABLE "public"."shifts" TO "service_role";



GRANT ALL ON TABLE "public"."suppliers" TO "anon";
GRANT ALL ON TABLE "public"."suppliers" TO "authenticated";
GRANT ALL ON TABLE "public"."suppliers" TO "service_role";



GRANT ALL ON TABLE "public"."taxes" TO "anon";
GRANT ALL ON TABLE "public"."taxes" TO "authenticated";
GRANT ALL ON TABLE "public"."taxes" TO "service_role";



GRANT ALL ON TABLE "public"."user_businesses" TO "anon";
GRANT ALL ON TABLE "public"."user_businesses" TO "authenticated";
GRANT ALL ON TABLE "public"."user_businesses" TO "service_role";



GRANT ALL ON TABLE "public"."user_permission_overrides" TO "anon";
GRANT ALL ON TABLE "public"."user_permission_overrides" TO "authenticated";
GRANT ALL ON TABLE "public"."user_permission_overrides" TO "service_role";



GRANT ALL ON TABLE "public"."user_roles" TO "anon";
GRANT ALL ON TABLE "public"."user_roles" TO "authenticated";
GRANT ALL ON TABLE "public"."user_roles" TO "service_role";



GRANT ALL ON TABLE "public"."v_employees_summary" TO "anon";
GRANT ALL ON TABLE "public"."v_employees_summary" TO "authenticated";
GRANT ALL ON TABLE "public"."v_employees_summary" TO "service_role";



GRANT ALL ON TABLE "public"."v_kitchen_items" TO "anon";
GRANT ALL ON TABLE "public"."v_kitchen_items" TO "authenticated";
GRANT ALL ON TABLE "public"."v_kitchen_items" TO "service_role";



GRANT ALL ON TABLE "public"."v_menu_items_list" TO "anon";
GRANT ALL ON TABLE "public"."v_menu_items_list" TO "authenticated";
GRANT ALL ON TABLE "public"."v_menu_items_list" TO "service_role";



GRANT ALL ON TABLE "public"."v_menus_with_counts" TO "anon";
GRANT ALL ON TABLE "public"."v_menus_with_counts" TO "authenticated";
GRANT ALL ON TABLE "public"."v_menus_with_counts" TO "service_role";



GRANT ALL ON TABLE "public"."v_order_detail" TO "anon";
GRANT ALL ON TABLE "public"."v_order_detail" TO "authenticated";
GRANT ALL ON TABLE "public"."v_order_detail" TO "service_role";



GRANT ALL ON TABLE "public"."v_zone_table_status" TO "anon";
GRANT ALL ON TABLE "public"."v_zone_table_status" TO "authenticated";
GRANT ALL ON TABLE "public"."v_zone_table_status" TO "service_role";



GRANT ALL ON TABLE "public"."v_zone_table_status2" TO "anon";
GRANT ALL ON TABLE "public"."v_zone_table_status2" TO "authenticated";
GRANT ALL ON TABLE "public"."v_zone_table_status2" TO "service_role";



GRANT ALL ON TABLE "public"."warehouses" TO "anon";
GRANT ALL ON TABLE "public"."warehouses" TO "authenticated";
GRANT ALL ON TABLE "public"."warehouses" TO "service_role";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";






\unrestrict sgpofWJzq38HILOe7y8wKjTOl48esCMwrFNNRaeQftu1X5vpSoZUGS6jteI2cB5

RESET ALL;
