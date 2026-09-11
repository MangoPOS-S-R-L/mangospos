-- =============================================================================
-- Migration: fn_close_cash_session (4 args) — arreglar la FUENTE del rol
-- =============================================================================
-- SÍNTOMA EN CAMPO (2026-09-11, conteo a ciegas ya firmado):
--   "CLOSE_DENIED: only the session owner or a business admin/owner can close
--    this session" — incluso para el DUEÑO del negocio.
--
-- CAUSA RAÍZ:
--   La migración 20260401_0002_cash_close_ownership_hardening leyó el rol de
--   `public.memberships`. Esa tabla NO es la de roles: es la de SUSCRIPCIÓN
--   SaaS (plan_type trial/free/basic/pro, status active/canceled/expired) y su
--   columna `role` es vestigial, con default 'staff'. Los roles reales del POS
--   viven en `public.user_businesses` (owner/admin/manager/cashier/waiter/...)
--   + `businesses.owner_id`, que es justo lo que resuelve
--   `public.user_business_role(uuid, uuid)` y lo que usa el resto de la BD
--   (incluida `fn_force_close_cash_session` de 20260513_0016).
--   Consecuencia: la excepción admin/owner nunca se cumplía y el guard quedó
--   de facto en "solo el que abrió la caja puede cerrarla". En un cambio de
--   turno (o si el cajero se fue) la caja queda imposible de cerrar, y el
--   candado revienta DESPUÉS de firmar el conteo a ciegas.
--
-- QUÉ HACE ESTA MIGRACIÓN:
--   1. Rehace SOLO la sobrecarga de 4 args (la que llama la app: el cliente
--      siempre manda p_force_with_open_tables). La de 3 args no se toca.
--   2. Autoriza con `user_business_role()` → owner / admin / manager, la misma
--      regla que `fn_force_close_cash_session`. Sigue siendo fail-closed:
--      cualquier otro rol (cashier, waiter, cook...) que no sea dueño de la
--      sesión recibe CLOSE_DENIED.
--      Se conserva el chequeo legacy contra memberships como OR, por si algún
--      negocio sí lo tiene poblado a mano.
--   3. Aprovecha para alinear el cálculo con la sobrecarga de 3 args y con
--      `fn_get_cash_session_summary`: EXCLUIR las ventas anuladas del esperado
--      (20260508_0008 / 20260514_0001 solo arreglaron la firma de 3 args, que
--      la app nunca llama, así que el cierre real seguía sumando anuladas y
--      reportando un faltante falso).
--
-- Sin cambios de esquema. Sin cambios en el cliente Flutter.
--
-- ANTES DE APLICAR (la BD viva diverge del repo):
--   select p.oid::regprocedure, pg_get_functiondef(p.oid)
--   from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--   where n.nspname = 'public' and p.proname = 'fn_close_cash_session';
-- =============================================================================

begin;

create or replace function public.fn_close_cash_session(
  p_session_id uuid,
  p_end_amount numeric,
  p_notes text,
  p_force_with_open_tables boolean default false
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_id uuid := auth.uid();
  v_session_user_id uuid;
  v_start_amount numeric := 0;
  v_total_sales numeric := 0;
  v_voided_sales numeric := 0;
  v_total_deposits numeric := 0;
  v_total_withdrawals numeric := 0;
  v_total_expenses numeric := 0;
  v_expected_cash numeric := 0;
  v_difference numeric := 0;
  v_business_id uuid;
  v_open_tables_count integer := 0;
  v_notes text;
  v_caller_role text;
  v_legacy_role public.member_role;
begin
  -- ---------------------------------------------------------------
  -- 1. Leer sesión + lock de la fila
  -- ---------------------------------------------------------------
  select
    s.user_id,
    coalesce(s.start_amount, 0),
    cr.business_id
    into v_session_user_id, v_start_amount, v_business_id
  from public.cash_register_sessions s
  join public.cash_registers cr on cr.id = s.cash_register_id
  where s.id = p_session_id
  for update;

  if not found then
    raise exception 'SESSION_NOT_FOUND';
  end if;

  -- ---------------------------------------------------------------
  -- 2. Autorización (fail-closed)
  --    Dueño de la sesión, o owner/admin/manager del negocio según
  --    user_businesses/businesses.owner_id (NO memberships, que es la
  --    tabla de suscripción y tiene role default 'staff').
  -- ---------------------------------------------------------------
  if v_caller_id is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  if v_session_user_id is distinct from v_caller_id then
    v_caller_role := public.user_business_role(v_caller_id, v_business_id);

    if coalesce(v_caller_role, '') not in ('owner', 'admin', 'manager') then
      -- Fallback legacy: negocios donde memberships.role sí se mantiene.
      select m.role into v_legacy_role
      from public.memberships m
      where m.user_id = v_caller_id
        and m.business_id = v_business_id
        and m.status = 'active'
      limit 1;

      if v_legacy_role is null or v_legacy_role not in ('owner', 'admin') then
        raise exception 'CLOSE_DENIED: only the session owner or a business admin/owner/manager can close this session';
      end if;

      v_caller_role := v_legacy_role::text;
    end if;
  end if;

  -- ---------------------------------------------------------------
  -- 3. Guard de mesas abiertas (sin cambios)
  -- ---------------------------------------------------------------
  select count(distinct ts.id)
    into v_open_tables_count
  from public.table_sessions ts
  join public.orders o on o.session_id = ts.id
  where ts.business_id = v_business_id
    and ts.closed_at is null
    and o.closed_at is null
    and o.status_ext not in ('paid', 'void');

  if v_open_tables_count > 0 and not coalesce(p_force_with_open_tables, false) then
    raise exception 'OPEN_TABLES_EXIST';
  end if;

  -- ---------------------------------------------------------------
  -- 4. Totales — ventas EXCLUYENDO anuladas (igual que la firma de 3
  --    args y que fn_get_cash_session_summary).
  -- ---------------------------------------------------------------
  select coalesce(sum(ct.amount), 0)
    into v_total_sales
  from public.cash_transactions ct
  where ct.session_id = p_session_id
    and ct.type = 'sale'
    and not exists (
      select 1 from public.payments p
      where p.order_id = ct.related_order_id
        and p.status in ('cancelled', 'void')
    );

  -- Informativo: lo anulado no entra al esperado pero se reporta.
  select coalesce(sum(ct.amount), 0)
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
  where session_id = p_session_id
    and type = 'deposit';

  select coalesce(sum(amount), 0)
    into v_total_withdrawals
  from public.cash_transactions
  where session_id = p_session_id
    and type = 'withdrawal';

  select coalesce(sum(amount), 0)
    into v_total_expenses
  from public.cash_transactions
  where session_id = p_session_id
    and type = 'expense';

  v_expected_cash :=
    v_start_amount +
    v_total_sales +
    v_total_deposits -
    v_total_withdrawals -
    v_total_expenses;

  v_difference := p_end_amount - v_expected_cash;

  v_notes := concat_ws(
    ' | ',
    nullif(trim(coalesce(p_notes, '')), ''),
    case
      when coalesce(p_force_with_open_tables, false)
        then format('Cierre forzado con %s mesa(s) abierta(s)', v_open_tables_count)
      else null
    end,
    case
      when v_session_user_id is distinct from v_caller_id
        then format('Cerrado por %s (rol: %s)', v_caller_id, coalesce(v_caller_role, 'n/d'))
      else null
    end
  );

  -- ---------------------------------------------------------------
  -- 5. Cerrar la sesión
  -- ---------------------------------------------------------------
  update public.cash_register_sessions
  set closed_at = now(),
      end_amount = p_end_amount,
      difference = v_difference,
      status = 'closed',
      notes = v_notes
  where id = p_session_id;

  return jsonb_build_object(
    'success', true,
    'difference', v_difference,
    'expected', v_expected_cash,
    'expected_amount', v_expected_cash,
    'expected_cash', v_expected_cash,
    'start_amount', v_start_amount,
    'total_sales', v_total_sales,
    'voided_sales_total', v_voided_sales,
    'total_deposits', v_total_deposits,
    'total_withdrawals', v_total_withdrawals,
    'total_expenses', v_total_expenses,
    'open_tables_count', v_open_tables_count,
    'forced_with_open_tables', coalesce(p_force_with_open_tables, false)
  );
end;
$$;

grant execute on function public.fn_close_cash_session(uuid, numeric, text, boolean)
  to authenticated;

comment on function public.fn_close_cash_session(uuid, numeric, text, boolean) is
  'Cierra una sesión de caja. Autoriza al dueño de la sesión o a '
  'owner/admin/manager según user_business_role() (user_businesses + '
  'businesses.owner_id). Fix 2026-09-11: antes leía memberships.role '
  '(tabla de suscripción, default staff) y nadie salvo el que abrió la '
  'caja podía cerrarla. El esperado excluye ventas anuladas.';

commit;
