-- =============================================================================
-- 20260917_0008 — Abonar es SOLO de dueño/administrador
-- =============================================================================
--
-- QUÉ CAMBIA:
--   La 0007 le dio `ventas.abono_mesa.registrar` a owner/admin/manager/cashier
--   y `.devolver` a owner/admin/manager. El negocio decidió que **abonar es
--   solo del dueño o un administrador**. Devolver y mover saldo van igual de
--   restringidos: sacan o mueven dinero, así que no pueden ser más laxos que
--   registrarlo.
--
--   `ventas.abono_mesa.ver` NO se toca: el cajero tiene que poder consultar el
--   saldo de la mesa (el cliente pregunta cuánto le queda) y seguir COBRANDO
--   contra él en el modal de pago. Ver y gastar el saldo es operación de caja;
--   cargarlo es decisión del dueño.
--
-- POR QUÉ NO ALCANZA CON QUITAR EL PERMISO:
--   `fn_table_deposit_add` solo validaba `user_has_business_access`, o sea que
--   cualquiera con acceso al negocio podía llamar el RPC directo y abonar
--   aunque la app le escondiera el botón — el permiso habría sido decorativo
--   ([[project_permission_gates_enforcement]]: 44 de 102 permisos no hacían
--   nada). Acá el candado vive en el servidor.
--
-- DE DÓNDE SALE EL ROL:
--   `user_business_role()` (user_businesses + businesses.owner_id), con el
--   fallback legacy a `memberships.role` que usa
--   20260911_0001_fix_close_cash_session_role_source. `memberships` NO es la
--   tabla de roles (es la de suscripción, con default 'staff'), pero hay
--   negocios viejos donde su role sí se mantiene y sin el fallback su admin
--   quedaría afuera.
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Quitar el permiso a los roles que ya no deben tenerlo
-- ---------------------------------------------------------------------------
-- Las filas ya existen (la 0007 se aplicó), así que hay que BORRARLAS: un
-- `on conflict do nothing` no revoca nada.

delete from public.role_permissions rp
 using public.permissions p, public.roles r
 where p.id = rp.permission_id
   and r.id = rp.role_id
   and r.is_system = true
   and lower(r.name) in ('manager', 'cashier', 'supervisor', 'waiter')
   and p.code in ('ventas.abono_mesa.registrar', 'ventas.abono_mesa.devolver');

-- Y asegurar que dueño y admin sí lo tengan.
insert into public.role_permissions (role_id, permission_id, allow)
select r.id, p.id, true
from public.roles r
cross join public.permissions p
where r.is_system = true
  and lower(r.name) in ('owner', 'admin')
  and p.code in ('ventas.abono_mesa.registrar', 'ventas.abono_mesa.devolver')
on conflict (role_id, permission_id) do nothing;

-- Overrides por usuario: si alguien le dio el permiso a mano a un cajero antes
-- de este cambio, el gate del servidor lo va a rechazar igual. Los dejamos
-- visibles en vez de borrarlos en silencio — la consulta de verificación de
-- abajo los lista.

-- ---------------------------------------------------------------------------
-- 2. ¿Quién puede manejar el saldo de una mesa?
-- ---------------------------------------------------------------------------

create or replace function public.fn_table_deposit_can_manage(
  p_business_id uuid,
  p_user_id     uuid default null
) returns boolean
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  v_user_id uuid := coalesce(p_user_id, auth.uid());
  v_role    text;
begin
  if v_user_id is null or p_business_id is null then
    return false;
  end if;

  -- Fuente buena: user_businesses + businesses.owner_id.
  v_role := public.user_business_role(v_user_id, p_business_id);
  if coalesce(v_role, '') in ('owner', 'admin') then
    return true;
  end if;

  -- Fallback legacy: negocios donde memberships.role sí se mantiene.
  return exists (
    select 1
    from public.memberships m
    where m.user_id = v_user_id
      and m.business_id = p_business_id
      and m.status = 'active'
      and m.role::text in ('owner', 'admin')
  );
end;
$$;

comment on function public.fn_table_deposit_can_manage(uuid, uuid) is
  'True si el usuario es dueño o administrador del negocio. Es el candado de '
  'registrar/devolver/mover abonos de mesa: cargar saldo es decisión del '
  'dueño, no del cajero. Cobrar CONTRA el saldo no pasa por aquí.';

grant execute on function public.fn_table_deposit_can_manage(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Registrar abono — ahora exige dueño/admin
-- ---------------------------------------------------------------------------
-- Cuerpo idéntico al de la 0007 salvo el bloque de autorización.

create or replace function public.fn_table_deposit_add(
  p_table_id           uuid,
  p_amount             numeric,
  p_payment_method_id  text    default 'cash',
  p_cashier_session_id uuid    default null,
  p_reference          text    default null,
  p_holder_name        text    default null,
  p_note               text    default null
) returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_account       public.table_deposit_accounts;
  v_business_id   uuid;
  v_method_id     uuid;
  v_method_code   text;
  v_movement_id   uuid;
  v_table_label   text;
begin
  if coalesce(p_amount, 0) <= 0 then
    raise exception 'DEPOSIT_INVALID_AMOUNT';
  end if;

  select z.business_id, coalesce(dt.label, dt.code)
    into v_business_id, v_table_label
  from public.dining_tables dt
  join public.zones z on z.id = dt.zone_id
  where dt.id = p_table_id;

  if v_business_id is null then
    raise exception 'TABLE_NOT_FOUND';
  end if;

  if not public.user_has_business_access(auth.uid(), v_business_id) then
    raise exception 'ACCESS_DENIED';
  end if;

  -- Abonar es solo del dueño o un administrador.
  if not public.fn_table_deposit_can_manage(v_business_id) then
    raise exception 'DEPOSIT_OWNER_ADMIN_ONLY';
  end if;

  -- La caja tiene que estar abierta: el dinero entra AHORA, y sin sesión no
  -- hay dónde registrarlo (mismo criterio que fn_process_payment_v3).
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

  -- Método con el que el cliente pagó el abono (efectivo, tarjeta...).
  if p_payment_method_id ~* '^[0-9a-f-]{36}$' then
    select pm.id, pm.code into v_method_id, v_method_code
    from public.payment_methods pm
    where pm.id = p_payment_method_id::uuid
      and pm.business_id = v_business_id
    limit 1;
  else
    select pm.id, pm.code into v_method_id, v_method_code
    from public.payment_methods pm
    where pm.business_id = v_business_id
      and pm.code = coalesce(p_payment_method_id, 'cash')
      and pm.is_active = true
    limit 1;
  end if;

  if v_method_id is null then
    raise exception 'INVALID_PAYMENT_METHOD';
  end if;

  -- Cobrar el abono CON saldo de mesa sería mover plata en círculo.
  if v_method_code = 'table_deposit' then
    raise exception 'DEPOSIT_METHOD_NOT_ALLOWED';
  end if;

  -- El método con el que DESPUÉS se cobra contra este saldo tiene que existir
  -- antes de que haya saldo. Los negocios creados después de la 0007 no lo
  -- tienen, y sin él el cajero podría abonar pero nunca gastar lo abonado.
  perform public.fn_ensure_table_deposit_method(v_business_id);

  v_account := public.fn_table_deposit_account(p_table_id, true);

  update public.table_deposit_accounts a
     set balance          = a.balance + p_amount,
         total_deposited  = a.total_deposited + p_amount,
         holder_name      = coalesce(nullif(trim(coalesce(p_holder_name, '')), ''),
                                     a.holder_name),
         note             = coalesce(nullif(trim(coalesce(p_note, '')), ''), a.note),
         last_movement_at = now(),
         updated_at       = now()
   where a.id = v_account.id
  returning * into v_account;

  insert into public.table_deposit_movements (
    account_id, business_id, table_id, type, amount, balance_after,
    payment_method_id, cash_session_id, reference, note, created_by
  ) values (
    v_account.id, v_business_id, p_table_id, 'deposit', p_amount,
    v_account.balance, v_method_id, p_cashier_session_id, p_reference,
    p_note, auth.uid()
  )
  returning id into v_movement_id;

  -- Solo el efectivo entra a la gaveta.
  if v_method_code = 'cash' then
    insert into public.cash_transactions (session_id, amount, type, description)
    values (
      p_cashier_session_id,
      p_amount,
      'deposit',
      'Abono mesa ' || coalesce(v_table_label, left(p_table_id::text, 8))
    );
  end if;

  return jsonb_build_object(
    'success', true,
    'account_id', v_account.id,
    'movement_id', v_movement_id,
    'table_id', p_table_id,
    'table_label', v_table_label,
    'amount', p_amount,
    'balance', v_account.balance,
    'total_deposited', v_account.total_deposited,
    'total_consumed', v_account.total_consumed,
    'holder_name', v_account.holder_name,
    'payment_method_code', v_method_code,
    'entered_cash_drawer', (v_method_code = 'cash')
  );
end;
$$;

comment on function public.fn_table_deposit_add(uuid, numeric, text, uuid, text, text, text) is
  'Registra un abono prepagado a una mesa. SOLO dueño/administrador. El dinero '
  'entra a la caja en este momento (cash_transactions type=deposit si es '
  'efectivo). NO emite NCF: el abono no es una venta.';

-- ---------------------------------------------------------------------------
-- 4. Devolver saldo — mismo candado
-- ---------------------------------------------------------------------------

create or replace function public.fn_table_deposit_refund(
  p_table_id           uuid,
  p_amount             numeric,
  p_cashier_session_id uuid,
  p_note               text default null
) returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_account     public.table_deposit_accounts;
  v_table_label text;
begin
  if coalesce(p_amount, 0) <= 0 then
    raise exception 'DEPOSIT_INVALID_AMOUNT';
  end if;

  select a.* into v_account
  from public.table_deposit_accounts a
  where a.table_id = p_table_id;

  if not found then
    raise exception 'TABLE_DEPOSIT_ACCOUNT_NOT_FOUND';
  end if;

  if not public.user_has_business_access(auth.uid(), v_account.business_id) then
    raise exception 'ACCESS_DENIED';
  end if;

  if not public.fn_table_deposit_can_manage(v_account.business_id) then
    raise exception 'DEPOSIT_OWNER_ADMIN_ONLY';
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

  update public.table_deposit_accounts a
     set balance          = a.balance - p_amount,
         total_refunded   = a.total_refunded + p_amount,
         last_movement_at = now(),
         updated_at       = now()
   where a.id = v_account.id
     and a.balance >= p_amount
  returning * into v_account;

  if not found then
    raise exception 'TABLE_DEPOSIT_INSUFFICIENT';
  end if;

  select coalesce(dt.label, dt.code) into v_table_label
  from public.dining_tables dt where dt.id = p_table_id;

  insert into public.table_deposit_movements (
    account_id, business_id, table_id, type, amount, balance_after,
    cash_session_id, note, created_by
  ) values (
    v_account.id, v_account.business_id, p_table_id, 'refund', -p_amount,
    v_account.balance, p_cashier_session_id, p_note, auth.uid()
  );

  insert into public.cash_transactions (session_id, amount, type, description)
  values (
    p_cashier_session_id,
    p_amount,
    'withdrawal',
    'Devolución de abono mesa ' || coalesce(v_table_label, left(p_table_id::text, 8))
  );

  return jsonb_build_object(
    'success', true,
    'table_id', p_table_id,
    'amount', p_amount,
    'balance', v_account.balance
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Mover saldo entre mesas — mismo candado
-- ---------------------------------------------------------------------------

create or replace function public.fn_table_deposit_transfer(
  p_from_table_id uuid,
  p_to_table_id   uuid,
  p_amount        numeric,
  p_note          text default null
) returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_from public.table_deposit_accounts;
  v_to   public.table_deposit_accounts;
begin
  if coalesce(p_amount, 0) <= 0 then
    raise exception 'DEPOSIT_INVALID_AMOUNT';
  end if;

  if p_from_table_id = p_to_table_id then
    raise exception 'DEPOSIT_SAME_TABLE';
  end if;

  select a.* into v_from
  from public.table_deposit_accounts a
  where a.table_id = p_from_table_id;

  if not found then
    raise exception 'TABLE_DEPOSIT_ACCOUNT_NOT_FOUND';
  end if;

  if not public.user_has_business_access(auth.uid(), v_from.business_id) then
    raise exception 'ACCESS_DENIED';
  end if;

  if not public.fn_table_deposit_can_manage(v_from.business_id) then
    raise exception 'DEPOSIT_OWNER_ADMIN_ONLY';
  end if;

  v_to := public.fn_table_deposit_account(p_to_table_id, true);

  if v_to.business_id <> v_from.business_id then
    raise exception 'DEPOSIT_CROSS_BUSINESS';
  end if;

  update public.table_deposit_accounts a
     set balance          = a.balance - p_amount,
         last_movement_at = now(),
         updated_at       = now()
   where a.id = v_from.id
     and a.balance >= p_amount
  returning * into v_from;

  if not found then
    raise exception 'TABLE_DEPOSIT_INSUFFICIENT';
  end if;

  update public.table_deposit_accounts a
     set balance          = a.balance + p_amount,
         holder_name      = coalesce(a.holder_name, v_from.holder_name),
         last_movement_at = now(),
         updated_at       = now()
   where a.id = v_to.id
  returning * into v_to;

  insert into public.table_deposit_movements (
    account_id, business_id, table_id, type, amount, balance_after,
    related_table_id, note, created_by
  ) values (
    v_from.id, v_from.business_id, p_from_table_id, 'transfer_out', -p_amount,
    v_from.balance, p_to_table_id, p_note, auth.uid()
  ), (
    v_to.id, v_to.business_id, p_to_table_id, 'transfer_in', p_amount,
    v_to.balance, p_from_table_id, p_note, auth.uid()
  );

  return jsonb_build_object(
    'success', true,
    'from_balance', v_from.balance,
    'to_balance', v_to.balance,
    'amount', p_amount
  );
end;
$$;

commit;

-- =============================================================================
-- VERIFICACIÓN (una sola consulta: el SQL Editor solo muestra el último
-- resultado)
--
--   select jsonb_pretty(jsonb_build_object(
--     'roles_que_pueden_abonar', (
--       select jsonb_agg(distinct r.name order by r.name)
--       from public.role_permissions rp
--       join public.roles r       on r.id = rp.role_id
--       join public.permissions p on p.id = rp.permission_id
--       where p.code = 'ventas.abono_mesa.registrar' and rp.allow),
--     'candado_servidor', (
--       select count(*) = 1 from pg_proc pr
--       join pg_namespace n on n.oid = pr.pronamespace
--       where n.nspname = 'public' and pr.proname = 'fn_table_deposit_can_manage'),
--     'overrides_por_usuario_a_revisar', (
--       select jsonb_agg(jsonb_build_object('user_id', o.user_id, 'allow', o.allow))
--       from public.user_permission_overrides o
--       join public.permissions p on p.id = o.permission_id
--       where p.code in ('ventas.abono_mesa.registrar','ventas.abono_mesa.devolver'))
--   ));
--
--   Esperado: roles_que_pueden_abonar = ["admin","owner"], candado_servidor = true.
-- =============================================================================
