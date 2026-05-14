-- =============================================================================
-- Fix arquitectónico: el summary del cierre debe ser la ÚNICA fuente de
-- verdad. Toast-level precision. (2026-05-14)
--
-- PROBLEMA:
--   El RPC `fn_get_cash_session_summary` (versión 20260514_0001) devuelve
--   solo `expected_amount`. La UI del cierre ciego en Dart espera campos
--   legacy adicionales (`expected_cash`, `expected_card`, `expected_transfer`,
--   `total_sales_all_methods`, `transaction_count`) que dejaron de existir
--   cuando la migración 20260508_0008 simplificó el RPC.
--
--   El Dart hizo un patch defensivo: usa `expected_cash` si existe, sino
--   `expected_amount`, sino re-calcula a mano sumando payments. Eso
--   significa que durante el ciclo de bug fixes, la UI mostraba números
--   distintos a los que la DB realmente persistía como `difference`.
--
-- IMPACTO DE LA INCONSISTENCIA:
--   Sesión 4572afa5 (2026-05-14):
--     - DB columna `difference`: 105.00  (cálculo con fix SQL)
--     - Notes del modal Dart:   6,470    (cálculo viejo del Dart sin fix)
--     Cajero vio sobrante de 6,470 en pantalla y firmó. Auditoría
--     persistió 105 como la diferencia real. Discrepancia: 6,365 ≈
--     start_amount (6,515).
--
-- FIX:
--   El RPC vuelve a devolver TODOS los campos que la UI necesita:
--     - expected_cash       = start + cash_sales (no anuladas)
--                             + cash_deposits - withdrawals - expenses
--     - expected_card       = sum(payments tarjeta completed - change)
--     - expected_transfer   = sum(payments transferencia completed - change)
--     - expected_total      = expected_cash + expected_card + expected_transfer
--     - total_sales_all_methods = sum(payments completed - change)
--     - transaction_count   = count(payments completed)
--     - cash_sales_net      = sum(cash_transactions type=sale no anuladas)
--   Todos los campos del cierre vienen ya calculados del backend. Dart
--   solo los lee, no recalcula.
--
-- BACKWARDS-COMPATIBLE:
--   - Firma intacta.
--   - Mantiene los campos existentes (expected_amount, total_deposits, etc.).
--   - Solo agrega campos que ya existían en 20260405_0002 y que la UI
--     espera. El Dart que usa `expected_amount` sigue funcionando.
-- =============================================================================

begin;

drop function if exists public.fn_get_cash_session_summary(uuid);

create function public.fn_get_cash_session_summary(
  p_session_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_start_amount        numeric := 0;
  v_opened_at           timestamptz;
  v_cash_sales_net      numeric := 0;
  v_voided_sales        numeric := 0;
  v_total_deposits      numeric := 0;
  v_total_withdrawals   numeric := 0;
  v_total_expenses      numeric := 0;
  v_paid_cash           numeric := 0;
  v_expected_card       numeric := 0;
  v_expected_transfer   numeric := 0;
  v_total_sales_all     numeric := 0;
  v_transaction_count   int := 0;
  v_expected_cash       numeric := 0;
  v_expected_total      numeric := 0;
begin
  -- Lookup base de la sesión.
  select coalesce(s.start_amount, 0), s.opened_at
    into v_start_amount, v_opened_at
  from public.cash_register_sessions s
  where s.id = p_session_id;

  if not found then
    return jsonb_build_object(
      'success', false,
      'error', 'SESSION_NOT_FOUND'
    );
  end if;

  -- Ventas en efectivo (excluye anuladas).
  select coalesce(sum(amount), 0)
    into v_cash_sales_net
  from public.cash_transactions ct
  where ct.session_id = p_session_id
    and ct.type = 'sale'
    and not exists (
      select 1 from public.payments p
      where p.order_id = ct.related_order_id
        and p.status in ('cancelled', 'void')
    );

  -- Ventas anuladas (informativo).
  select coalesce(sum(amount), 0)
    into v_voided_sales
  from public.cash_transactions ct
  where ct.session_id = p_session_id
    and ct.type = 'sale'
    and exists (
      select 1 from public.payments p
      where p.order_id = ct.related_order_id
        and p.status in ('cancelled', 'void')
    );

  -- Depósitos, retiros, gastos.
  select coalesce(sum(amount), 0) into v_total_deposits
  from public.cash_transactions
  where session_id = p_session_id and type = 'deposit';

  select coalesce(sum(amount), 0) into v_total_withdrawals
  from public.cash_transactions
  where session_id = p_session_id and type = 'withdrawal';

  select coalesce(sum(amount), 0) into v_total_expenses
  from public.cash_transactions
  where session_id = p_session_id and type = 'expense';

  -- Breakdown de payments por método (excluye cancelled/void).
  select
    coalesce(sum(
      case
        when pm.code = 'cash' or lower(coalesce(pm.name, '')) like '%efectivo%'
          then greatest(p.amount - coalesce(p.change_amount, 0), 0)
        else 0
      end
    ), 0),
    coalesce(sum(
      case
        when pm.code = 'card' or lower(coalesce(pm.name, '')) like '%tarjet%'
          then greatest(p.amount - coalesce(p.change_amount, 0), 0)
        else 0
      end
    ), 0),
    coalesce(sum(
      case
        when pm.code = 'transfer' or lower(coalesce(pm.name, '')) like '%transfer%'
          then greatest(p.amount - coalesce(p.change_amount, 0), 0)
        else 0
      end
    ), 0),
    coalesce(sum(greatest(p.amount - coalesce(p.change_amount, 0), 0)), 0),
    coalesce(count(*), 0)::int
    into
      v_paid_cash,
      v_expected_card,
      v_expected_transfer,
      v_total_sales_all,
      v_transaction_count
  from public.payments p
  join public.payment_methods pm on pm.id = p.payment_method_id
  where p.session_id = p_session_id
    and p.status = 'completed';

  -- Fórmula canónica del efectivo esperado en caja:
  -- = monto de apertura
  --   + ventas en efectivo (no anuladas)
  --   + depósitos manuales
  --   - retiros
  --   - gastos
  v_expected_cash := v_start_amount
                   + v_cash_sales_net
                   + v_total_deposits
                   - v_total_withdrawals
                   - v_total_expenses;

  v_expected_total := v_expected_cash + v_expected_card + v_expected_transfer;

  return jsonb_build_object(
    'success', true,
    'start_amount', v_start_amount,
    'opened_at', v_opened_at,

    -- Ventas efectivo (informativos individuales)
    'cash_sales_net', v_cash_sales_net,
    'total_sales', v_cash_sales_net,           -- alias legacy
    'voided_sales_total', v_voided_sales,

    -- Movimientos manuales
    'total_deposits', v_total_deposits,
    'total_withdrawals', v_total_withdrawals,
    'total_expenses', v_total_expenses,
    'total_income', v_cash_sales_net + v_total_deposits,
    'total_outflows', v_total_withdrawals + v_total_expenses,

    -- Esperados por método (FUENTE ÚNICA DE VERDAD)
    'expected_cash', v_expected_cash,
    'expected_card', v_expected_card,
    'expected_transfer', v_expected_transfer,
    'expected_total', v_expected_total,
    -- Alias legacy: expected_amount == expected_cash (lo que cuadra contra
    -- el efectivo contado al cerrar).
    'expected_amount', v_expected_cash,

    -- Totales por método informativos
    'paid_cash', v_paid_cash,
    'total_sales_all_methods', v_total_sales_all,
    'transaction_count', v_transaction_count
  );
exception when others then
  return jsonb_build_object(
    'success', false,
    'error', sqlerrm,
    'error_code', sqlstate
  );
end;
$$;

alter function public.fn_get_cash_session_summary(uuid) owner to postgres;

grant execute on function public.fn_get_cash_session_summary(uuid)
  to anon, authenticated, service_role;

comment on function public.fn_get_cash_session_summary(uuid) is
  'Resumen jsonb completo de una sesión de caja. Fuente única de verdad '
  'para el cierre. Devuelve expected_cash/card/transfer/total con '
  'start_amount sumado donde corresponde, además de breakdown de '
  'movimientos y conteo de transacciones. Fix 2026-05-14: re-incluye '
  'todos los campos legacy que la UI esperaba y que 20260508_0008 había '
  'eliminado, evitando que el Dart re-calcule por su cuenta y se desfase.';

commit;
