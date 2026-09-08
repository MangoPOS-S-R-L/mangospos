-- =============================================================================
-- F1a — Ingesta de pedidos externos (Pincer)
--
-- Ver docs/PRD_INTEGRACION_PINCER.md (R3). Depende de 20260907_0005.
--
-- CONVIERTE el payload de un canal externo en una orden de delivery real del
-- POS: mesa DEL-NNN, lineas con su ITBIS, comanda a cocina, pago registrado.
--
-- DECISIONES QUE VALE LA PENA ENTENDER
--
--   1. NO usa `fn_open_delivery_order`. Esa funcion resuelve el negocio desde
--      `user_businesses` del usuario (`order by created_at limit 1`). Un dueno
--      con VARIAS sucursales tiene varias filas: el pedido de Tropella podria
--      abrirse en otra sucursal. Aca el business_id llega EXPLICITO desde la
--      API key, asi que se replica la apertura con el negocio correcto.
--
--   2. Las lineas entran por `fn_add_item_from_menu`, la MISMA puerta que usa
--      la app. Es lo que resuelve precio, `menu_item_taxes`, modo de impuesto
--      y area de impresion. Un INSERT crudo en `order_items` entraria sin
--      ITBIS ([[project_menu_item_taxes_is_only_source]]).
--
--   3. NO llama `fn_confirm_order_to_kitchen`: esa funcion no tiene guard y
--      resucita ordenes ya pagadas ([[project_kitchen_confirm_overwrites_paid]]).
--      Los items se marcan aqui, acotados a esta orden y solo desde 'draft'.
--
--   4. El pago va en un bloque que ATRAPA el error. Si el cobro falla (sin
--      secuencia NCF, RNC malo, lo que sea) el pedido igual entra y la comanda
--      igual sale; el fallo queda en `payment_state='failed'` + `payment_error`
--      para reconciliar. Perder el pedido porque no se pudo registrar un cobro
--      que YA ocurrio afuera seria lo peor de los dos mundos.
--
--   5. Una orden pagada SIGUE en el KDS: la vista `kds_open_orders` filtra por
--      `orders.kitchen_done_at IS NULL`, no por orden abierta. Asi que cobrar
--      en la ingesta NO le quita la comanda al cocinero (mismo comportamiento
--      que la venta rapida).
--
-- SEGURIDAD MULTI-TENANT: cada `menu_item_id` y cada `modifier_id` se valida
--   contra el business_id de la credencial. Un id de otro negocio se rechaza.
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Estado del cobro en el vinculo
-- ---------------------------------------------------------------------------
alter table public.external_orders
  add column if not exists payment_state text not null default 'none'
    check (payment_state in ('none', 'pending', 'recorded', 'failed')),
  add column if not exists payment_error text,
  add column if not exists needs_review boolean not null default false,
  add column if not exists environment text not null default 'production'
    check (environment in ('sandbox', 'production'));

comment on column public.external_orders.environment is
  'De que credencial vino. Un pedido de sandbox NO debe imprimir comanda ni '
  'contar en reportes: la estacion de recepcion lo ignora y la seccion Ordenes '
  'lo pinta como prueba. Ojo: si la credencial sandbox apunta al negocio REAL, '
  'el pedido entra al negocio real — esta marca es lo unico que lo distingue.';

comment on column public.external_orders.payment_state is
  'none = no venia pagada | pending = se cobra al entregar (efectivo) | '
  'recorded = registrado en el POS | failed = fallo el registro, ver payment_error. '
  'El pedido entra igual: la comida no se detiene por un cobro que ya ocurrio afuera.';

-- ---------------------------------------------------------------------------
-- 2. Resolver la credencial (la usa la edge function)
-- ---------------------------------------------------------------------------
create or replace function public.fn_resolve_external_api_key(p_api_key text)
returns table (
  business_id    uuid,
  channel        text,
  environment    text,
  hmac_secret    text,
  rate_limit_rpm int,
  scopes         text[]
)
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_hash text;
begin
  if p_api_key is null or length(btrim(p_api_key)) = 0 then
    return;
  end if;

  v_hash := encode(sha256(convert_to(p_api_key, 'utf8')), 'hex');

  update public.external_api_keys k
     set last_used_at = now()
   where k.key_hash = v_hash
     and k.is_active = true
     and k.revoked_at is null;

  return query
  select k.business_id, k.channel, k.environment,
         k.hmac_secret, k.rate_limit_rpm, k.scopes
    from public.external_api_keys k
   where k.key_hash = v_hash
     and k.is_active = true
     and k.revoked_at is null;
end;
$$;

revoke all on function public.fn_resolve_external_api_key(text) from public;
grant execute on function public.fn_resolve_external_api_key(text) to service_role;

-- ---------------------------------------------------------------------------
-- 3. La ingesta
-- ---------------------------------------------------------------------------
create or replace function public.fn_ingest_external_order(
  p_business_id uuid,
  p_channel     text,
  p_payload     jsonb,
  p_environment text default 'production'
) returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_ext_id       text := nullif(btrim(p_payload->>'external_order_id'), '');
  v_ext_number   text := nullif(btrim(p_payload->>'external_number'), '');
  v_service      text := coalesce(nullif(p_payload->>'service_type', ''), 'delivery');
  v_lines        jsonb := p_payload->'lines';
  v_payment      jsonb := coalesce(p_payload->'payment', '{}'::jsonb);
  v_customer     jsonb := coalesce(p_payload->'customer', '{}'::jsonb);
  v_tip          numeric := coalesce((v_payment->>'tip_amount')::numeric, 0);
  v_total        numeric := nullif(v_payment->>'total', '')::numeric;
  v_paid         boolean := lower(coalesce(v_payment->>'status', 'pending')) = 'paid';
  v_rnc          text := nullif(btrim(v_customer->>'rnc'), '');
  v_existing     public.external_orders;
  v_user_id      uuid;
  v_zone_id      uuid;
  v_table_id     uuid;
  v_session_id   uuid;
  v_order_id     uuid;
  v_seq          int;
  v_table_code   text;
  v_label        text;
  v_line         jsonb;
  v_mod          jsonb;
  v_menu_item_id uuid;
  v_item_id      uuid;
  v_qty          numeric;
  v_items_added  int := 0;
  v_needs_review boolean := false;
  v_pay_state    text := 'none';
  v_pay_error    text;
  v_cash_session uuid;
  v_pos_total    numeric;
  v_ext_row_id   uuid;
begin
  -- ── Validacion del payload ────────────────────────────────────────────
  if v_ext_id is null then
    raise exception 'EXT_INVALID_PAYLOAD: falta external_order_id'
      using errcode = 'P0001';
  end if;

  if v_lines is null or jsonb_typeof(v_lines) <> 'array' or jsonb_array_length(v_lines) = 0 then
    raise exception 'EXT_INVALID_PAYLOAD: el pedido no trae lineas'
      using errcode = 'P0001';
  end if;

  if v_service not in ('delivery', 'pickup') then
    raise exception 'EXT_INVALID_PAYLOAD: service_type invalido (%)', v_service
      using errcode = 'P0001';
  end if;

  -- ── Idempotencia ──────────────────────────────────────────────────────
  -- Advisory lock: dos reintentos simultaneos por timeout de red no pueden
  -- crear dos ordenes ni imprimir dos comandas.
  perform pg_advisory_xact_lock(
    hashtextextended(p_business_id::text || ':' || p_channel || ':' || v_ext_id, 0));

  select * into v_existing
    from public.external_orders
   where business_id = p_business_id
     and external_order_id = v_ext_id;

  if found then
    return jsonb_build_object(
      'duplicate',        true,
      'order_id',         v_existing.order_id,
      'external_number',  v_existing.external_number,
      'status',           'accepted',
      'payment_state',    v_existing.payment_state,
      'environment',      v_existing.environment,
      'created_at',       v_existing.created_at
    );
  end if;

  -- ── Usuario del negocio (table_sessions.opened_by es NOT NULL) ─────────
  select ub.user_id into v_user_id
    from public.user_businesses ub
   where ub.business_id = p_business_id
   order by case when ub.role = 'owner' then 0 else 1 end, ub.created_at
   limit 1;

  if v_user_id is null then
    select b.owner_id into v_user_id
      from public.businesses b where b.id = p_business_id;
  end if;

  if v_user_id is null then
    raise exception 'EXT_NO_USER: el negocio % no tiene usuario para abrir la orden', p_business_id
      using errcode = 'P0001';
  end if;

  -- ── Apertura: zona / mesa / sesion / orden ────────────────────────────
  select id into v_zone_id
    from public.zones
   where business_id = p_business_id and name = 'Delivery'
   limit 1;

  if v_zone_id is null then
    insert into public.zones (business_id, name, sort_index, is_active)
    values (p_business_id, 'Delivery', 902, true)
    returning id into v_zone_id;
  end if;

  select coalesce(max(case when code ~ '^DEL-[0-9]+$'
                           then cast(replace(code, 'DEL-', '') as int) else 0 end), 0) + 1
    into v_seq
    from public.dining_tables where zone_id = v_zone_id;

  v_table_code := 'DEL-' || lpad(v_seq::text, 3, '0');
  v_label := case p_channel
               when 'pincer'     then 'Pincer'
               when 'uber_eats'  then 'Uber Eats'
               when 'pedidos_ya' then 'Pedidos Ya'
               else initcap(p_channel)
             end
             || case when v_ext_number is not null then ' #' || v_ext_number else '' end
             || case when p_environment = 'sandbox' then ' (PRUEBA)' else '' end;

  insert into public.dining_tables (
    zone_id, code, label, shape, state, capacity,
    pos_x, pos_y, width, height, rotation, is_active
  ) values (
    v_zone_id, v_table_code, v_label, 'square', 'occupied', 1, 0, 0, 1, 1, 0, true
  ) returning id into v_table_id;

  insert into public.table_sessions (
    table_id, opened_by, origin, waiter_user_id, people_count,
    delivery_type, business_id, customer_name, note
  ) values (
    v_table_id, v_user_id, 'delivery', v_user_id, 1,
    p_channel, p_business_id,
    nullif(btrim(v_customer->>'name'), ''),
    nullif(btrim(v_customer->>'address'), '')
  ) returning id into v_session_id;

  insert into public.orders (session_id, business_id, status_ext, subtotal, discounts, tax, total, total_amount)
  values (v_session_id, p_business_id, 'open', 0, 0, 0, 0, 0)
  returning id into v_order_id;

  insert into public.order_checks (order_id, label, position)
  values (v_order_id, 'C1', 1);

  -- ── Lineas ────────────────────────────────────────────────────────────
  for v_line in select * from jsonb_array_elements(v_lines)
  loop
    v_menu_item_id := nullif(btrim(v_line->>'menu_item_id'), '')::uuid;

    -- Si mandan un id propio, se traduce por el mapeo.
    if v_menu_item_id is null then
      select m.menu_item_id into v_menu_item_id
        from public.external_item_map m
       where m.business_id = p_business_id
         and m.channel = p_channel
         and m.external_item_id = nullif(btrim(v_line->>'external_item_id'), '');
    end if;

    -- Candado multi-tenant: el producto tiene que ser DE ESTE negocio.
    if v_menu_item_id is null
       or not exists (select 1 from public.menu_items mi
                       where mi.id = v_menu_item_id
                         and mi.business_id = p_business_id) then
      raise exception 'EXT_UNKNOWN_MENU_ITEM: %',
        coalesce(v_line->>'menu_item_id', v_line->>'external_item_id', '(sin id)')
        using errcode = 'P0001';
    end if;

    v_qty := greatest(coalesce((v_line->>'quantity')::numeric, 1), 1);

    -- MISMA puerta que la app: resuelve precio, impuesto y area de impresion.
    v_item_id := public.fn_add_item_from_menu(
      v_order_id,
      v_menu_item_id,
      v_qty,
      1,                                    -- check C1
      (v_service = 'pickup'),                -- para llevar: exime Ley 10% si aplica
      nullif(btrim(v_line->>'notes'), '')
    );
    v_items_added := v_items_added + 1;

    -- Modificadores
    if jsonb_typeof(v_line->'modifiers') = 'array' then
      for v_mod in select * from jsonb_array_elements(v_line->'modifiers')
      loop
        insert into public.order_item_modifiers (item_id, name, qty, price)
        select v_item_id,
               coalesce(md.name, nullif(btrim(v_mod->>'name'), ''), 'Extra'),
               greatest(coalesce((v_mod->>'quantity')::numeric, 1), 1),
               coalesce(md.price_delta, 0)
          from (select 1) dummy
          left join public.modifiers md
            on md.id = nullif(btrim(v_mod->>'modifier_id'), '')::uuid
           and md.business_id = p_business_id;

        -- Modificador que no resolvio: entra con el nombre que mandaron y
        -- precio 0, pero la orden queda marcada para revisar.
        if not exists (select 1 from public.modifiers md
                        where md.id = nullif(btrim(v_mod->>'modifier_id'), '')::uuid
                          and md.business_id = p_business_id) then
          v_needs_review := true;
        end if;
      end loop;
    end if;
  end loop;

  -- ── A cocina ──────────────────────────────────────────────────────────
  -- Acotado a ESTA orden y solo desde 'draft'. No se toca ninguna otra.
  update public.order_items
     set status = 'pending',
         kitchen_sent_at = coalesce(kitchen_sent_at, now())
   where order_id = v_order_id
     and status = 'draft';

  update public.orders
     set status = 'sent',
         status_ext = 'sent_to_kitchen',
         tip = v_tip
   where id = v_order_id;

  -- ── Pago ──────────────────────────────────────────────────────────────
  -- El total se lee ANTES de cobrar: al cerrar la orden, `orders.total` queda
  -- en 0 (el recalculo solo cuenta items no pagados). Si lo leyeramos despues
  -- le reportariamos `pos_total: 0` al canal y les romperiamos la conciliacion.
  select o.total into v_pos_total from public.orders o where o.id = v_order_id;

  if v_paid then
    -- `fn_process_payment_v3` exige sesion de caja SIEMPRE, aun para metodos que
    -- no tocan el cajon (corta antes de mirar el metodo). Ver 20260907_0007.
    v_cash_session := public.fn_external_open_cash_session(p_business_id);

    if v_cash_session is null then
      v_pay_state := 'failed';
      v_pay_error := 'SIN_CAJA_ABIERTA: el pedido entro y la comanda salio, pero '
                     || 'el cobro no se pudo registrar porque no hay una caja '
                     || 'abierta. Registralo al abrir la proxima caja.';
    else
      begin
        perform public.fn_process_payment_v3(
          p_order_id           => v_order_id,
          p_check_id           => null,
          p_payment_method_id  => p_channel,
          p_amount             => coalesce(v_total, 0),
          p_reference          => nullif(btrim(v_payment->>'reference'), ''),
          p_customer_id        => null,
          p_customer_rnc       => v_rnc,
          p_cashier_session_id => v_cash_session,
          p_change_amount      => 0,
          p_requested_ncf_type => case when v_rnc is not null then 'B01' else null end,
          p_close_order        => true
        );
        v_pay_state := 'recorded';
      exception when others then
        -- El pedido NO se cae por esto: la comida ya se pago afuera.
        v_pay_state := 'failed';
        v_pay_error := left(sqlerrm, 500);
      end;
    end if;
  else
    v_pay_state := 'pending';   -- efectivo contra entrega: cobra el POS
  end if;

  -- ── Vinculo ───────────────────────────────────────────────────────────
  insert into public.external_orders (
    business_id, channel, external_order_id, external_number,
    order_id, session_id, service_type, paid_externally,
    external_total, tip_amount, payment_reference,
    customer_name, customer_phone, customer_rnc, delivery_address,
    placed_at, accepted_at, accepted_by,
    payment_state, payment_error, needs_review, environment, raw_order
  ) values (
    p_business_id, p_channel, v_ext_id, v_ext_number,
    v_order_id, v_session_id, v_service, v_paid,
    v_total, v_tip, nullif(btrim(v_payment->>'reference'), ''),
    nullif(btrim(v_customer->>'name'), ''),
    nullif(btrim(v_customer->>'phone'), ''),
    v_rnc,
    nullif(btrim(v_customer->>'address'), ''),
    nullif(p_payload->>'placed_at', '')::timestamptz,
    nullif(p_payload->>'accepted_at', '')::timestamptz,
    nullif(btrim(p_payload->>'accepted_by'), ''),
    v_pay_state, v_pay_error, v_needs_review,
    case when p_environment = 'sandbox' then 'sandbox' else 'production' end,
    p_payload
  ) returning id into v_ext_row_id;

  return jsonb_build_object(
    'duplicate',        false,
    'external_order_row', v_ext_row_id,
    'order_id',         v_order_id,
    'session_id',       v_session_id,
    'order_number',     v_table_code,
    'external_number',  v_ext_number,
    'status',           'accepted',
    'items',            v_items_added,
    'payment_state',    v_pay_state,
    'payment_error',    v_pay_error,
    'environment',      case when p_environment = 'sandbox' then 'sandbox' else 'production' end,
    'needs_review',     v_needs_review,
    'pos_total',        v_pos_total,
    'tip_amount',       v_tip
  );
end;
$$;

revoke all on function public.fn_ingest_external_order(uuid, text, jsonb, text) from public;
grant execute on function public.fn_ingest_external_order(uuid, text, jsonb, text) to service_role;

comment on function public.fn_ingest_external_order(uuid, text, jsonb, text) is
  'Convierte el payload de un canal externo en una orden de delivery del POS. '
  'Idempotente por (business_id, external_order_id) con advisory lock. Solo '
  'service_role: la llama la edge function, nunca la app.';

commit;
