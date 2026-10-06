-- =============================================================================
-- 20261005_0003 — Quién AUTORIZÓ con PIN el retiro de un producto
-- =============================================================================
--
-- EL HUECO:
--   El cajero no puede quitar de la cuenta algo que ya salió a cocina: la app
--   le pide PIN de Supervisor/Administrador. Pero ese PIN se validaba SOLO en
--   la app y no quedaba en ninguna parte. `order_item_removals` guarda
--   `removed_by` (la cuenta de la tablet = el cajero) y `reason_employee_id`
--   (el mesero activo), así que un retiro autorizado por la gerente salía a
--   nombre del cajero. Justo el dato que faltó en la auditoría de El Prodigio
--   (19-sep): «quien_lo_quito» era la cuenta compartida de la tablet.
--
-- QUÉ HACE:
--   1. `order_item_removals` + `approved_by_employee_id`, `approved_by_user_id`
--      y `approved_at`.
--   2. `fn_approve_order_item_removal(p_item_id, p_approver_pin)`: la app la
--      llama justo DESPUÉS de quitar el producto, con el PIN que escribió el
--      supervisor. El PIN se valida AQUÍ, en el servidor:
--        * `fn_verify_employee_pin` (la misma que usa la app y la que ya
--          valida el PIN al pasar una caja a otro equipo, 20261005_0002), y
--        * el rol del aprobador (`user_business_role`, que reconoce al dueño
--          por businesses.owner_id) debe ser owner/admin/manager — el mismo
--          nivel «supervisor» que exige la pantalla.
--      Solo sella el retiro MÁS RECIENTE de ese producto hecho por la cuenta
--      que llama en los últimos 30 minutos, y nunca pisa un aprobador ya
--      escrito. Devuelve el nombre del aprobador para el comprobante.
--
-- POR QUÉ UNA FUNCIÓN NUEVA Y NO TOCAR fn_note_order_item_removal:
--   esa función cambió de firma en 20260920_0002 (3 → 5 argumentos) y no hay
--   certeza de cuál está viva. Reemplazarla a ciegas podía dejar la app
--   llamando una firma que no existe (PGRST202) y perder también el motivo.
--   Esta no reemplaza nada vivo: solo agrega columnas y una función.
--
-- NO CAMBIA: quién puede borrar. El borrado sigue igual (DELETE directo con
--   respaldo en fn_delete_item); esto solo deja constancia de la autorización.
--   Sin red, el retiro se encola y no hay fila que sellar todavía: ese retiro
--   queda sin aprobador (el comprobante impreso sí dice que hubo PIN).
--
-- REQUIERE: 20260919_0002 (order_item_removals), fn_verify_employee_pin
--   (20260528_0006) y user_business_role. Si falta algo, aborta sin tocar nada.
--
-- IDEMPOTENTE. ROLLBACK: 20261005_0003_removal_approved_by_ROLLBACK.sql
-- =============================================================================

begin;

do $$
begin
  if to_regclass('public.order_item_removals') is null then
    raise exception
      'Falta public.order_item_removals: aplica primero 20260919_0002.';
  end if;
  if to_regprocedure('public.fn_verify_employee_pin(uuid, text)') is null then
    raise exception
      'Falta public.fn_verify_employee_pin(uuid, text) (20260528_0006).';
  end if;
  if to_regprocedure('public.user_business_role(uuid, uuid)') is null then
    raise exception 'Falta public.user_business_role(uuid, uuid).';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 1. Columnas
-- ---------------------------------------------------------------------------
-- Sin FK, igual que reason_employee_id: dar de baja a un empleado no puede
-- tumbar ni reescribir el registro de lo que autorizó.
alter table public.order_item_removals
  add column if not exists approved_by_employee_id uuid,
  add column if not exists approved_by_user_id     uuid,
  add column if not exists approved_at             timestamptz;

comment on column public.order_item_removals.approved_by_employee_id is
  'Empleado (Supervisor/Administrador) que autorizó el retiro con su PIN, '
  'validado en el servidor por fn_approve_order_item_removal (20261005_0003). '
  'NULL = no hizo falta PIN (dueño o permiso propio) o se quitó sin red.';
comment on column public.order_item_removals.approved_by_user_id is
  'Cuenta (auth.users) del empleado que autorizó con PIN.';
comment on column public.order_item_removals.approved_at is
  'Cuándo se selló la autorización.';

create index if not exists idx_order_item_removals_approved_by
  on public.order_item_removals (business_id, approved_by_employee_id)
  where approved_by_employee_id is not null;

-- ---------------------------------------------------------------------------
-- 2. Sello del aprobador
-- ---------------------------------------------------------------------------
create or replace function public.fn_approve_order_item_removal(
  p_item_id      uuid,
  p_approver_pin text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid               uuid := auth.uid();
  v_id                uuid;
  v_business          uuid;
  v_existing          uuid;
  v_approver          jsonb;
  v_approver_employee uuid;
  v_approver_user     uuid;
  v_approver_role     text;
  v_name              text;
begin
  if v_uid is null then
    return jsonb_build_object('approved', false,
      'error_code', 'UNAUTHENTICATED');
  end if;
  if p_item_id is null or p_approver_pin is null
     or btrim(p_approver_pin) = '' then
    return jsonb_build_object('approved', false,
      'error_code', 'APPROVAL_REQUIRED');
  end if;

  -- El retiro que ESTA cuenta acaba de hacer de ese producto. Mismo orden que
  -- fn_note_order_item_removal (el más reciente), pero acotado a quien lo
  -- quitó y a una ventana corta: el PIN se escribió segundos antes. Así nadie
  -- le pone aprobador a un retiro ajeno o viejo.
  select r.id, r.business_id, r.approved_by_employee_id
    into v_id, v_business, v_existing
  from public.order_item_removals r
  where r.item_id = p_item_id
    and r.removed_by = v_uid
    and r.business_id in (select public.current_user_business_ids())
    and r.removed_at > now() - interval '30 minutes'
  order by r.removed_at desc
  limit 1;

  if v_id is null then
    return jsonb_build_object('approved', false,
      'error_code', 'REMOVAL_NOT_FOUND');
  end if;

  -- El PIN se valida aquí, no se le cree a la app.
  v_approver := public.fn_verify_employee_pin(v_business,
                                              btrim(p_approver_pin));
  v_approver_employee := nullif(v_approver ->> 'employee_id', '')::uuid;
  v_approver_user := nullif(v_approver ->> 'user_id', '')::uuid;
  if v_approver_user is not null then
    v_approver_role := public.user_business_role(v_approver_user, v_business);
  end if;

  if v_approver_employee is null
     or v_approver_role is null
     or v_approver_role not in ('owner', 'admin', 'manager') then
    return jsonb_build_object('approved', false,
      'error_code', 'APPROVAL_DENIED',
      'error', 'PIN inválido o sin jerarquía de Supervisor/Administrador.');
  end if;

  -- Ya tenía aprobador (reintento): no se pisa.
  if v_existing is not null then
    select nullif(btrim(concat_ws(' ', e.first_name, e.last_name)), '')
      into v_name
    from public.employees e
    where e.id = v_existing;
    return jsonb_build_object('approved', true, 'already', true,
      'removal_id', v_id,
      'approver_employee_id', v_existing,
      'approver_name', v_name);
  end if;

  update public.order_item_removals r
     set approved_by_employee_id = v_approver_employee,
         approved_by_user_id     = v_approver_user,
         approved_at             = now()
   where r.id = v_id
     and r.approved_by_employee_id is null;

  v_name := nullif(btrim(concat_ws(' ',
              v_approver ->> 'first_name',
              v_approver ->> 'last_name')), '');

  return jsonb_build_object('approved', true,
    'removal_id', v_id,
    'approver_employee_id', v_approver_employee,
    'approver_name', v_name);
end;
$$;

comment on function public.fn_approve_order_item_removal(uuid, text) is
  'Sella en order_item_removals quién autorizó con PIN de Supervisor/'
  'Administrador el retiro más reciente de un producto hecho por la cuenta '
  'que llama (últimos 30 min). Valida el PIN en el servidor con '
  'fn_verify_employee_pin y el rol con user_business_role. Nunca pisa un '
  'aprobador ya escrito (20261005_0003).';

revoke all on function public.fn_approve_order_item_removal(uuid, text)
  from public;
grant execute on function public.fn_approve_order_item_removal(uuid, text)
  to authenticated;

notify pgrst, 'reload schema';

commit;

-- =============================================================================
-- VERIFICACIÓN (después de aplicar; UNA sola fila):
--
--   select
--     (select count(*) from information_schema.columns
--       where table_schema = 'public'
--         and table_name = 'order_item_removals'
--         and column_name in ('approved_by_employee_id',
--                             'approved_by_user_id', 'approved_at')) as columnas,
--     (to_regprocedure(
--        'public.fn_approve_order_item_removal(uuid, text)') is not null) as fn;
--
--   Esperado: columnas = 3, fn = true.
--
-- USO (retiros autorizados con PIN de un negocio, los más recientes primero):
--
--   select r.removed_at, r.table_name, r.product_name, r.quantity,
--          r.reason,
--          concat_ws(' ', ap.first_name, ap.last_name) as autorizo,
--          r.removed_by
--     from public.order_item_removals r
--     left join public.employees ap on ap.id = r.approved_by_employee_id
--    where r.business_id = '<BUSINESS_ID>'
--      and r.approved_by_employee_id is not null
--    order by r.removed_at desc
--    limit 100;
-- =============================================================================
