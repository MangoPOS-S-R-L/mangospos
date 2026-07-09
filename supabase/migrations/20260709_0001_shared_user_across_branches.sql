-- Compartir un usuario entre sucursales (multisucursal para empleados).
--
-- Requisito: poder designar a un usuario (no solo al dueno por owner_id) para
-- que vea/opere TODAS las sucursales del grupo. El "grupo" es el conjunto de
-- `businesses` que comparten `owner_id` (no hay tabla de organizacion/grupo).
--
-- Marca EXPLICITA (sin expansion retroactiva): columna
-- `user_businesses.shared_across_branches`. Un usuario con esa marca en un
-- negocio H accede a todas las sucursales S donde S.owner_id = H.owner_id.
-- El ROL de esa fila define su nivel (un cajero compartido sigue siendo cajero
-- en todas; solo owner/admin son admin en todas).
--
-- Esta migracion SUPERSEDE los cuerpos de las 3 funciones de gate definidos en
-- 20260708_0001 (owner_id): aqui quedan con la rama owner_id + la nueva rama
-- de usuario compartido. Preserva la rama de empleados de is_admin_of_business
-- (existe en prod, no en el repo -> ver project_db_diverges_from_repo_migrations).
--
-- RECORDATORIO CRITICO (incidente 2026-07-09): `current_user_business_ids()`
-- devuelve `SETOF uuid` (uuids escalares), NO filas con columna `business_id`.
-- En `businesses` la PK es `id` (NO existe `business_id`). Cualquier guarda
-- tipo `... current_user_business_ids() x WHERE x.business_id` o `b.business_id`
-- revienta con 42703 y tumba TODA la RLS que use la funcion.

begin;

-- Marca explicita de "usuario compartido entre sucursales".
alter table public.user_businesses
  add column if not exists shared_across_branches boolean not null default false;

-- Indice para el filtro por owner_id en los self-joins de las funciones RLS.
create index if not exists idx_businesses_owner_id
  on public.businesses (owner_id);

-- (a) IDs de negocios accesibles: base de las policies
--     `business_id in (select current_user_business_ids())`.
create or replace function public.current_user_business_ids()
returns setof uuid
language sql
stable
security definer
set search_path to 'public'
as $$
  select m.business_id from public.memberships m where m.user_id = auth.uid()
  union
  select ub.business_id from public.user_businesses ub where ub.user_id = auth.uid()
  union
  select b.id from public.businesses b where b.owner_id = auth.uid()
  union
  -- Usuario compartido: todas las hermanas (mismo owner_id) de cualquier
  -- negocio donde tenga shared_across_branches = true.
  select sib.id
  from public.user_businesses ub
  join public.businesses home on home.id = ub.business_id
  join public.businesses sib on sib.owner_id = home.owner_id
  where ub.user_id = auth.uid()
    and ub.shared_across_branches = true
    and home.owner_id is not null;
$$;

-- (b) Membresia: SELECT en print_areas, printers, etc.
create or replace function public.is_member_of_business(p_business uuid)
returns boolean
language sql
stable
as $$
  select
    exists(select 1 from public.memberships m
           where m.business_id = p_business and m.user_id = auth.uid())
    or exists(select 1 from public.user_businesses ub
           where ub.business_id = p_business and ub.user_id = auth.uid())
    or exists(select 1 from public.businesses b
           where b.id = p_business and b.owner_id = auth.uid())  -- b.id, NO b.business_id
    or exists(
      -- Usuario compartido: miembro de todas las hermanas del grupo.
      select 1
      from public.user_businesses ub
      join public.businesses home on home.id = ub.business_id
      join public.businesses target on target.id = p_business
      where ub.user_id = auth.uid()
        and ub.shared_across_branches = true
        and home.owner_id is not null
        and home.owner_id = target.owner_id
    );
$$;

-- (c) Admin: INSERT/UPDATE/DELETE (configurar areas, impresoras, etc.).
create or replace function public.is_admin_of_business(p_business uuid)
returns boolean
language sql
stable
as $$
  select
    exists(
      select 1 from public.memberships m
      where m.business_id = p_business and m.user_id = auth.uid()
        and m.role in ('owner', 'admin')
    )
    or exists(
      select 1 from public.user_businesses ub
      where ub.business_id = p_business and ub.user_id = auth.uid()
        and ub.role in ('owner', 'admin')
    )
    or exists(
      -- Sistema de empleados: admin/owner tiene un rol con nivel 'admin'.
      select 1 from public.employees e
      join public.employee_roles er on er.employee_id = e.id
      join public.roles r on r.id = er.role_id
      where e.business_id = p_business and e.user_id = auth.uid()
        and (r.level = 'admin'
             or lower(r.name) in ('administrador', 'propietario', 'owner', 'admin'))
    )
    or exists(
      -- Dueno del negocio (owner_id): admin de todas sus sucursales.
      select 1 from public.businesses b
      where b.id = p_business and b.owner_id = auth.uid()  -- b.id, NO b.business_id
    )
    or exists(
      -- Usuario compartido con rol owner/admin: admin en todas las hermanas.
      select 1
      from public.user_businesses ub
      join public.businesses home on home.id = ub.business_id
      join public.businesses target on target.id = p_business
      where ub.user_id = auth.uid()
        and ub.shared_across_branches = true
        and ub.role in ('owner', 'admin')
        and home.owner_id is not null
        and home.owner_id = target.owner_id
    );
$$;

commit;
