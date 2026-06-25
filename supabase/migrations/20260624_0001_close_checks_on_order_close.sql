-- =============================================================================
-- Fix: cerrar una orden debe cerrar TAMBIÉN sus order_checks (cierre atómico).
--
-- Bug raíz (caso NCF B0200070797 — Medio Tiempo — 2026-06-24):
--   En un cobro a nivel de orden (fn_process_payment_v3 con p_check_id IS NULL),
--   se marcaban los ítems como 'paid' y se cerraba la orden vía
--   fn_close_order_and_table, pero NUNCA se cerraban los order_checks.
--   El check C1 por defecto quedaba is_closed=false → la POS lo seguía tratando
--   como cuenta abierta → se le podían agregar ítems DESPUÉS del pago.
--
--   Consecuencia: el NCF (que es un snapshot de orders.total al emitirse) queda
--   congelado, mientras el check/ítems siguen creciendo. Cliente sub-cobrado,
--   comprobante sub-registrado. (3 coronas = 750 cobradas como 500.)
--
-- Fix: fn_close_order_and_table cierra de forma idempotente todos los checks
--   abiertos de la orden. Cubre CUALQUIER camino que cierre una orden (cobro de
--   orden completa, void, etc.), no solo el RPC de pago. Para split bill, el
--   cobro por-check ya cierra su propio check; al cerrar el último, esta función
--   no encuentra checks abiertos (idempotente, no-op).
--
-- Nota: order_checks.closed_at existe en la BD viva (ver
--   20260620_0001_ensure_order_checks_fiscal_columns y el uso en
--   fn_process_payment_v3). Se replica el mismo UPDATE ya probado allí.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_close_order_and_table(p_order_id uuid, p_status order_status)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_session uuid;
  v_open_count int;
  v_table_id uuid;
  v_legacy_status text;
begin
  -- Mapeo enum → text legacy. Mantenemos compatibilidad con queries
  -- que aún leen `status` (KDS, reportes, etc.).
  v_legacy_status := case p_status
    when 'paid'::public.order_status then 'paid'
    when 'void'::public.order_status then 'canceled'
    else null
  end;

  update public.orders
  set status_ext = p_status,
      status     = coalesce(v_legacy_status, status),
      closed_at  = now()
  where id = p_order_id;

  -- FIX 2026-06-24: cierre atómico de checks. Sin esto, un cobro a nivel de
  -- orden dejaba el/los order_checks con is_closed=false → cuenta editable tras
  -- el pago (ver caso NCF B0200070797). Idempotente: solo cierra los abiertos.
  update public.order_checks
  set is_closed = true,
      closed_at = now()
  where order_id = p_order_id
    and coalesce(is_closed, false) = false;

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
$function$;
