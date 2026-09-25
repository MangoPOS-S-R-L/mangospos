-- =============================================================================
-- 20260924_0001 — Asignarle una mesa abierta a otro mesero
--
-- QUÉ ARREGLA:
--   El dueño de una mesa (`table_sessions.opened_by_employee_id`) se escribe
--   al abrirla y NUNCA cambia: `fn_open_table` solo lo pone en el INSERT de
--   una sesión nueva (verificado en la BD viva el 2026-07-15). Si el mesero
--   se va a su casa, entra otro turno, o la mesa se abrió a nombre de quien
--   no era, no había forma de corregirlo: la mesa quedaba de por vida a
--   nombre del primero en el salón, en la precuenta, en la factura, en la
--   pantalla de mozos y —con «cada mesero es dueño de su mesa» prendido— el
--   mesero que de verdad la atiende no podía ni entrar.
--
-- DECISIÓN DEL DUEÑO (2026-09-24): la reasignación vale **de aquí en
--   adelante**. Lo que ya se consumió sigue acreditado a quien lo digitó; el
--   mesero nuevo se lleva la mesa y lo que agregue desde ahora.
--
-- POR QUÉ LA FUNCIÓN «CONGELA» LOS ÍTEMS SIN AUTOR:
--   `fn_sales_by_waiter` acredita por ÍTEM con
--   `coalesce(oi.created_by_employee_id, ts.opened_by_employee_id)`. O sea,
--   los ítems que NO tienen autor propio (los digitó un admin o una cajera
--   sin PIN) cuelgan del dueño de la mesa. Si solo cambiáramos el dueño,
--   esas ventas VIEJAS se le moverían solas al mesero nuevo — justo lo
--   contrario de lo que se pidió. Por eso, antes de cambiar el dueño, esos
--   ítems se estampan con el empleado que los tenía hasta ahora. Así
--   «de aquí en adelante» es literal y el reporte no se mueve solo.
--
-- LO QUE NO SE TOCA:
--   - `order_items.created_by_employee_id` YA puesto: es de quien lo digitó.
--   - `waiter_user_id` / `opened_by`: son la cuenta del DISPOSITIVO que
--     abrió, dato de auditoría del equipo, no del mesero. La prioridad de
--     atribución (empleado > usuario) hace que cambiar el empleado alcance.
--   - Comandas ya impresas: el papel que salió salió.
--
-- LO QUE SÍ CAMBIA SOLO, sin tocar más código:
--   - Tarjeta del salón (`v_zone_table_status` resuelve por
--     `opened_by_employee_id` primero, mig 20260605_0007).
--   - «MESERO:» de precuenta y factura (`fn_order_opener_name`).
--   - Pantalla de mozos (agrupa `emp:<opened_by_employee_id>` primero).
--   - Quién puede entrar con `multimesero_table_owner_only` (20260916_0002).
--
-- SOLO MESAS ABIERTAS: una sesión cerrada es una venta liquidada; cambiarle
--   el mesero es reescribir historia ya cobrada e impresa.
--
-- CONTRATO DE ERRORES (strings mapeables en Dart):
--   AUTH_REQUIRED, SESSION_NOT_FOUND, SESSION_CLOSED,
--   TABLE_BUSINESS_NOT_FOUND, REASSIGN_DENIED, EMPLOYEE_NOT_IN_BUSINESS.
--
-- PERMISOS: SECURITY DEFINER con chequeo explícito — rol owner/admin/
--   manager/cashier, o el permiso nuevo `ventas.mesas.reasignar_mesero`.
--   Un mesero NO puede regalarse ni quitarse mesas solo.
--
-- IDEMPOTENTE: sí. REVERSIBLE: sí (_ROLLBACK).
-- =============================================================================

begin;

set local lock_timeout = '5s';
set local statement_timeout = '30s';

-- ---------------------------------------------------------------------------
-- 1. Permiso
-- ---------------------------------------------------------------------------
insert into public.permissions (code, name, module, description) values
  ('ventas.mesas.reasignar_mesero',
   'Asignar una mesa a otro mesero',
   'operations',
   'Cambia a que mesero pertenece una mesa ya abierta (cambio de turno, mesa abierta a nombre equivocado). Lo ya consumido sigue acreditado a quien lo digito.')
on conflict (code) do update
  set name = excluded.name,
      module = excluded.module,
      description = excluded.description;

insert into public.role_permissions (role_id, permission_id, allow)
select r.id, p.id, true
from public.roles r
cross join public.permissions p
where r.is_system = true
  and lower(r.name) in ('owner', 'admin', 'manager', 'cashier')
  and p.code = 'ventas.mesas.reasignar_mesero'
on conflict (role_id, permission_id) do nothing;

-- ---------------------------------------------------------------------------
-- 2. Bitácora
--
-- Regalar la mesa de alguien mueve plata de columna en el reporte de
-- ventas por mesero. Sin rastro de quién lo hizo y por qué, es un agujero.
-- ---------------------------------------------------------------------------
create table if not exists public.table_session_waiter_changes (
  id                uuid primary key default gen_random_uuid(),
  business_id       uuid not null references public.businesses(id) on delete cascade,
  session_id        uuid not null references public.table_sessions(id) on delete cascade,
  table_id          uuid,
  from_employee_id  uuid references public.employees(id),
  to_employee_id    uuid not null references public.employees(id),
  changed_by        uuid references auth.users(id),
  reason            text,
  items_frozen      integer not null default 0,
  created_at        timestamptz not null default now()
);

create index if not exists idx_table_session_waiter_changes_session
  on public.table_session_waiter_changes (session_id, created_at desc);
create index if not exists idx_table_session_waiter_changes_business
  on public.table_session_waiter_changes (business_id, created_at desc);

comment on table public.table_session_waiter_changes is
  'Bitacora de reasignaciones de mesa a otro mesero: de quien a quien, quien '
  'lo hizo, por que, y cuantos items sin autor se congelaron al mesero '
  'anterior. Ver 20260924_0001.';

alter table public.table_session_waiter_changes enable row level security;

drop policy if exists "tswc_select" on public.table_session_waiter_changes;
create policy "tswc_select" on public.table_session_waiter_changes
  for select to authenticated
  using (public.user_has_business_access(auth.uid(), business_id));

-- Sin politica de escritura: las filas las pone la RPC (security definer).

-- ---------------------------------------------------------------------------
-- 3. Reasignar
-- ---------------------------------------------------------------------------
create or replace function public.fn_reassign_table_waiter(
  p_session_id  uuid,
  p_employee_id uuid,
  p_reason      text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id     uuid := auth.uid();
  v_session     public.table_sessions;
  v_business_id uuid;
  v_role        text;
  v_from_emp    uuid;
  v_frozen      integer := 0;
  v_to_name     text;
begin
  if v_user_id is null then
    raise exception 'AUTH_REQUIRED';
  end if;
  if p_session_id is null or p_employee_id is null then
    raise exception 'SESSION_NOT_FOUND';
  end if;

  select * into v_session
    from public.table_sessions
   where id = p_session_id
   for update;
  if not found then
    raise exception 'SESSION_NOT_FOUND';
  end if;

  -- Una sesion cerrada ya se cobro y se imprimio: no se le cambia el mesero.
  if v_session.closed_at is not null then
    raise exception 'SESSION_CLOSED';
  end if;

  -- El negocio sale de la mesa (dining_tables -> zones), el mismo camino que
  -- usa fn_open_table. `table_sessions.business_id` puede venir nulo en
  -- sesiones creadas por esa funcion, asi que no se confia en esa columna.
  select z.business_id
    into v_business_id
    from public.dining_tables t
    join public.zones z on z.id = t.zone_id
   where t.id = v_session.table_id;
  v_business_id := coalesce(v_business_id, v_session.business_id);
  if v_business_id is null then
    raise exception 'TABLE_BUSINESS_NOT_FOUND';
  end if;

  select public.user_business_role(v_user_id, v_business_id) into v_role;
  if coalesce(v_role, '') not in ('owner', 'admin', 'manager', 'cashier')
     and not public.user_has_business_permission(
       v_business_id, 'ventas.mesas.reasignar_mesero') then
    raise exception 'REASSIGN_DENIED';
  end if;

  -- El mesero nuevo tiene que ser de este negocio y estar activo.
  select nullif(btrim(e.first_name || ' ' || coalesce(e.last_name, '')), '')
    into v_to_name
    from public.employees e
   where e.id = p_employee_id
     and e.business_id = v_business_id
     and e.status = 'active';
  if not found then
    raise exception 'EMPLOYEE_NOT_IN_BUSINESS';
  end if;

  -- Ya es de ese mesero: no es un error, simplemente no hay nada que hacer.
  if v_session.opened_by_employee_id = p_employee_id then
    return jsonb_build_object(
      'changed', false,
      'session_id', p_session_id,
      'table_id', v_session.table_id,
      'to_employee_id', p_employee_id,
      'to_employee_name', v_to_name,
      'items_frozen', 0
    );
  end if;

  -- Quien la tenia hasta ahora. Si la abrieron sin PIN, se busca el empleado
  -- de esa cuenta: es a quien el reporte le estaba acreditando los items sin
  -- autor, y es a quien hay que dejarselos.
  v_from_emp := v_session.opened_by_employee_id;
  if v_from_emp is null then
    select e.id into v_from_emp
      from public.employees e
     where e.user_id = v_session.opened_by
       and e.business_id = v_business_id
     limit 1;
  end if;

  -- Congelar lo ya consumido en el mesero anterior (ver cabecera).
  if v_from_emp is not null then
    update public.order_items oi
       set created_by_employee_id = v_from_emp
     where oi.created_by_employee_id is null
       and oi.order_id in (
         select o.id from public.orders o where o.session_id = p_session_id
       );
    get diagnostics v_frozen = row_count;
  end if;

  update public.table_sessions
     set opened_by_employee_id = p_employee_id
   where id = p_session_id;

  insert into public.table_session_waiter_changes (
    business_id, session_id, table_id, from_employee_id, to_employee_id,
    changed_by, reason, items_frozen
  ) values (
    v_business_id, p_session_id, v_session.table_id, v_from_emp, p_employee_id,
    v_user_id, nullif(btrim(p_reason), ''), v_frozen
  );

  return jsonb_build_object(
    'changed', true,
    'session_id', p_session_id,
    'table_id', v_session.table_id,
    'from_employee_id', v_from_emp,
    'to_employee_id', p_employee_id,
    'to_employee_name', v_to_name,
    'items_frozen', v_frozen
  );
end;
$$;

comment on function public.fn_reassign_table_waiter(uuid, uuid, text) is
  'Asigna una mesa ABIERTA a otro mesero (cambia opened_by_employee_id). Vale '
  'de aqui en adelante: antes de cambiar el dueno, estampa los items sin autor '
  'con el mesero anterior para que el reporte de ventas por mesero no se mueva '
  'solo. Deja bitacora en table_session_waiter_changes. Ver 20260924_0001.';

commit;
