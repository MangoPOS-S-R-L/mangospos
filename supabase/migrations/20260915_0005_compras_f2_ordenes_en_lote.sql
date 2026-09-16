-- =============================================================================
-- 20260915_0005 — Compras F2: crear las órdenes del pedido sugerido en lote
--
-- PRD: docs/PRD_COMPRAS_PEDIDO_SUGERIDO.md (F2).
-- REQUIERE: 20260915_0003 (fn_purchase_order_create).
--
-- QUÉ ENTREGA: `fn_purchase_orders_create_batch`. La pantalla «Pedido
--   sugerido» arma UNA orden por suplidor y las manda juntas:
--
--   * TODO O NADA. Si la orden del tercer suplidor tiene una línea mala, no
--     queda creada ni la del primero: el comprador corrige y vuelve a tocar el
--     botón sin tener que averiguar cuáles ya salieron.
--   * Cada orden pasa por `fn_purchase_order_create` (las mismas validaciones,
--     el mismo PO-00000 bajo el mismo candado): los números salen seguidos.
--   * Idempotente: la llave del lote se vuelve `llave:suplidor` por orden. Un
--     doble toque o un reintento tras perder la red devuelve las mismas
--     órdenes con `reused = true`, sin duplicarlas.
--   * Un suplidor por orden y sin repetir dentro del lote.
--
-- NEGOCIOS SIN INVENTARIO: la función no escribe nada y solo corre si alguien
--   la llama.
--
-- PRUEBA: supabase/tests/compras_f2_local_test.sh (Postgres 15 local).
-- IDEMPOTENTE: sí. REVERSIBLE: sí (_ROLLBACK).
-- =============================================================================

begin;

set local lock_timeout = '5s';
set local statement_timeout = '60s';

do $guard$
begin
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'fn_purchase_order_create'
  ) then
    raise exception 'Falta aplicar 20260915_0003 (fn_purchase_order_create). No se aplicó nada.';
  end if;
end
$guard$;

create or replace function public.fn_purchase_orders_create_batch(
  p_business_id     uuid,
  p_warehouse_id    uuid,
  p_orders          jsonb,
  p_status          text default 'draft',
  p_idempotency_key text default null
)
returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_key      text := nullif(trim(p_idempotency_key), '');
  v_order    jsonb;
  v_supplier uuid;
  v_label    text;
  v_seen     uuid[] := '{}';
  v_result   jsonb;
  v_out      jsonb := '[]'::jsonb;
  v_index    integer := 0;
  v_total    integer;
  v_created  integer := 0;
  v_reused   integer := 0;
begin
  if p_orders is null or jsonb_typeof(p_orders) <> 'array'
     or jsonb_array_length(p_orders) = 0 then
    raise exception 'PURCHASE_BATCH_EMPTY: no hay órdenes que crear';
  end if;

  v_total := jsonb_array_length(p_orders);
  if v_total > 200 then
    raise exception 'PURCHASE_BATCH_TOO_LARGE: % órdenes en un lote (máximo 200)', v_total;
  end if;

  for v_order in select value from jsonb_array_elements(p_orders) loop
    v_index := v_index + 1;
    v_supplier := nullif(v_order ->> 'supplier_id', '')::uuid;
    v_label := coalesce(nullif(trim(v_order ->> 'supplier_name'), ''), 'orden ' || v_index);

    if v_supplier is null then
      raise exception 'PURCHASE_BATCH_SUPPLIER_REQUIRED: la orden % de % no tiene suplidor', v_index, v_total;
    end if;
    if v_supplier = any (v_seen) then
      raise exception 'PURCHASE_BATCH_DUPLICATE_SUPPLIER: % aparece dos veces en el lote', v_label;
    end if;
    v_seen := v_seen || v_supplier;

    begin
      v_result := public.fn_purchase_order_create(
        p_business_id,
        p_warehouse_id,
        v_supplier,
        v_order -> 'lines',
        p_status,
        nullif(v_order ->> 'expected_date', '')::date,
        coalesce(v_order -> 'header', '{}'::jsonb),
        case when v_key is null then null else v_key || ':' || v_supplier::text end
      );
    exception when others then
      -- Se relanza con el suplidor en el mensaje: la transacción entera se
      -- deshace igual, pero la pantalla puede decir CUÁL orden falló.
      raise exception using
        errcode = sqlstate,
        message = sqlerrm || ' — ' || v_label || ' (orden ' || v_index || ' de ' || v_total || ')';
    end;

    if coalesce((v_result ->> 'reused')::boolean, false) then
      v_reused := v_reused + 1;
    else
      v_created := v_created + 1;
    end if;
    v_out := v_out || jsonb_build_array(v_result || jsonb_build_object('supplier_id', v_supplier));
  end loop;

  return jsonb_build_object('orders', v_out, 'created', v_created, 'reused', v_reused);
end;
$$;

comment on function public.fn_purchase_orders_create_batch(uuid, uuid, jsonb, text, text) is
  'Crea una orden de compra por suplidor en UNA transacción (todo o nada) '
  'usando fn_purchase_order_create; idempotente por llave:suplidor. '
  'p_orders = [{supplier_id, supplier_name?, expected_date?, header{}, lines[]}]. '
  'Ver 20260915_0005.';

grant execute on function public.fn_purchase_orders_create_batch(uuid, uuid, jsonb, text, text) to authenticated;

commit;

notify pgrst, 'reload schema';
