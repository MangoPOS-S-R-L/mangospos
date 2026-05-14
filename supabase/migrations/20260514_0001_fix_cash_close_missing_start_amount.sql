-- =============================================================================
-- Fix crítico: el monto de apertura (start_amount) no se suma en el
-- esperado del cierre de caja. (2026-05-14)
--
-- BUG:
--   La migración 20260508_0008 reescribió `fn_close_cash_session` y
--   `fn_get_cash_session_summary` para excluir ventas anuladas, pero
--   en el proceso eliminó `start_amount` de la fórmula de
--   `expected_amount`. Antes del bug, `start_amount` aparecía
--   "por accidente" porque `fn_open_cash_session` insertaba un row
--   en `cash_transactions` (type='deposit', description='Apertura de
--   caja') que se sumaba dentro de v_total_deposits.
--
--   La migración 20260513_0014 (fix de double-counting) eliminó ese
--   INSERT duplicado correctamente — pero como las fórmulas de 0008
--   nunca sumaban explícitamente `start_amount`, el monto de
--   apertura quedó completamente fuera del esperado.
--
-- IMPACTO:
--   Si un cajero abre caja con $1,000 y vende $500 en efectivo,
--   el sistema le dice que esperaba $500 en caja. Al contar $1,500
--   reales reporta un "sobrante" de $1,000 fantasma.
--
-- EVIDENCIA:
--   `fn_force_close_cash_session` (20260513_0016 línea 125) sí incluye
--   `start_amount` en su cálculo — el contraste prueba que la fórmula
--   correcta es la de force_close, no la de 0008.
--
-- FIX:
--   Re-crear `fn_close_cash_session` y `fn_get_cash_session_summary`
--   con `start_amount` añadido al `expected_amount`. Conserva la
--   exclusión de ventas anuladas (que es lo que aportaba 0008).
--   Firmas y forma del jsonb retornado se mantienen idénticas.
--
-- BACKWARDS-COMPATIBLE:
--   - No cambia schema ni firmas.
--   - Sesiones ya cerradas (con `difference` calculado bajo el bug) NO
--     se tocan — recalcular alteraría arqueos firmados / reportes
--     históricos. Solo aplica a cierres futuros.
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. fn_close_cash_session
-- ---------------------------------------------------------------------------

drop function if exists public.fn_close_cash_session(uuid, numeric, text);

create function public.fn_close_cash_session(
  p_session_id uuid,
  p_end_amount numeric,
  p_notes      text default null
) returns jsonb
language plpgsql
security definer
as $$
declare
    v_start_amount       numeric := 0;
    v_total_sales        numeric := 0;
    v_voided_sales       numeric := 0;
    v_total_deposits     numeric := 0;
    v_total_withdrawals  numeric := 0;
    v_total_expenses     numeric := 0;
    v_expected_amount    numeric := 0;
    v_difference         numeric := 0;
begin
    select coalesce(start_amount, 0) into v_start_amount
    from public.cash_register_sessions
    where id = p_session_id;

    if not found then
        raise exception 'SESSION_NOT_FOUND';
    end if;

    -- Ventas en efectivo (excluye anuladas).
    select coalesce(sum(amount), 0)
      into v_total_sales
      from public.cash_transactions ct
     where ct.session_id = p_session_id
       and ct.type = 'sale'
       and not exists (
         select 1 from public.payments p
         where p.order_id = ct.related_order_id
           and p.status in ('cancelled', 'void')
       );

    -- Ventas anuladas (informativo, no entra al esperado).
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

    select coalesce(sum(amount), 0)
      into v_total_deposits
      from public.cash_transactions
     where session_id = p_session_id and type = 'deposit';

    select coalesce(sum(amount), 0)
      into v_total_withdrawals
      from public.cash_transactions
     where session_id = p_session_id and type = 'withdrawal';

    select coalesce(sum(amount), 0)
      into v_total_expenses
      from public.cash_transactions
     where session_id = p_session_id and type = 'expense';

    -- FIX 2026-05-14: incluir v_start_amount al inicio. Antes solo se
    -- sumaban deposits+sales y se restaban withdrawals+expenses, lo que
    -- dejaba fuera el monto con el que se abrió la caja.
    v_expected_amount := v_start_amount
                       + v_total_deposits
                       + v_total_sales
                       - v_total_withdrawals
                       - v_total_expenses;

    v_difference := p_end_amount - v_expected_amount;

    update public.cash_register_sessions
       set closed_at  = now(),
           end_amount = p_end_amount,
           difference = v_difference,
           status     = 'closed',
           notes      = p_notes
     where id = p_session_id;

    return jsonb_build_object(
      'success', true,
      'difference', v_difference,
      'expected', v_expected_amount,
      'expected_amount', v_expected_amount,
      'start_amount', v_start_amount,
      'total_sales', v_total_sales,
      'voided_sales_total', v_voided_sales,
      'total_deposits', v_total_deposits,
      'total_withdrawals', v_total_withdrawals,
      'total_expenses', v_total_expenses
    );
end;
$$;

alter function public.fn_close_cash_session(uuid, numeric, text)
  owner to postgres;

grant execute on function public.fn_close_cash_session(uuid, numeric, text)
  to anon, authenticated, service_role;

comment on function public.fn_close_cash_session(uuid, numeric, text) is
  'Cierra una sesión de caja. expected_amount = start_amount + deposits + '
  'sales (no anuladas) - withdrawals - expenses. Fix 2026-05-14: agregar '
  'start_amount que la versión de 20260508_0008 olvidaba sumar.';


-- ---------------------------------------------------------------------------
-- 2. fn_get_cash_session_summary
-- ---------------------------------------------------------------------------

drop function if exists public.fn_get_cash_session_summary(uuid);

create function public.fn_get_cash_session_summary(
  p_session_id uuid
) returns jsonb
language plpgsql
security definer
as $$
declare
    v_result jsonb;
begin
    select jsonb_build_object(
        'start_amount', s.start_amount,
        'opened_at', s.opened_at,
        -- total_sales: solo ventas NO anuladas
        'total_sales', (
          select coalesce(sum(amount), 0)
          from public.cash_transactions ct
          where ct.session_id = s.id
            and ct.type = 'sale'
            and not exists (
              select 1 from public.payments p
              where p.order_id = ct.related_order_id
                and p.status in ('cancelled', 'void')
            )
        ),
        'voided_sales_total', (
          select coalesce(sum(amount), 0)
          from public.cash_transactions ct
          where ct.session_id = s.id
            and ct.type = 'sale'
            and exists (
              select 1 from public.payments p
              where p.order_id = ct.related_order_id
                and p.status in ('cancelled', 'void')
            )
        ),
        'total_deposits', (
          select coalesce(sum(amount), 0)
          from public.cash_transactions
          where session_id = s.id and type = 'deposit'
        ),
        'total_withdrawals', (
          select coalesce(sum(amount), 0)
          from public.cash_transactions
          where session_id = s.id and type = 'withdrawal'
        ),
        'total_expenses', (
          select coalesce(sum(amount), 0)
          from public.cash_transactions
          where session_id = s.id and type = 'expense'
        ),
        -- total_income: ventas (no anuladas) + depósitos
        'total_income', (
          select coalesce(sum(amount), 0)
          from public.cash_transactions ct
          where ct.session_id = s.id
            and (
              ct.type = 'deposit'
              or (
                ct.type = 'sale'
                and not exists (
                  select 1 from public.payments p
                  where p.order_id = ct.related_order_id
                    and p.status in ('cancelled', 'void')
                )
              )
            )
        ),
        'total_outflows', (
          select coalesce(sum(amount), 0)
          from public.cash_transactions
          where session_id = s.id
            and type in ('withdrawal', 'expense')
        ),
        -- FIX 2026-05-14: expected_amount = start_amount + total_income -
        -- total_outflows. La versión de 20260508_0008 omitía
        -- start_amount, dejando fuera el monto con el que se abrió la
        -- caja.
        'expected_amount',
          coalesce(s.start_amount, 0)
          + (
            select coalesce(sum(amount), 0)
            from public.cash_transactions ct
            where ct.session_id = s.id
              and (
                ct.type = 'deposit'
                or (
                  ct.type = 'sale'
                  and not exists (
                    select 1 from public.payments p
                    where p.order_id = ct.related_order_id
                      and p.status in ('cancelled', 'void')
                  )
                )
              )
          )
          - (
            select coalesce(sum(amount), 0)
            from public.cash_transactions
            where session_id = s.id
              and type in ('withdrawal', 'expense')
          )
    ) into v_result
    from public.cash_register_sessions s
    where s.id = p_session_id;

    return v_result;
end;
$$;

alter function public.fn_get_cash_session_summary(uuid) owner to postgres;

grant execute on function public.fn_get_cash_session_summary(uuid)
  to anon, authenticated, service_role;

comment on function public.fn_get_cash_session_summary(uuid) is
  'Resumen jsonb de una sesión de caja para el modal de cierre. '
  'expected_amount = start_amount + deposits + sales (no anuladas) - '
  'withdrawals - expenses. Fix 2026-05-14: agregar start_amount que '
  'la versión de 20260508_0008 olvidaba sumar.';

commit;
