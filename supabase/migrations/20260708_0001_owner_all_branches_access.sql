-- Propietario accede a TODAS sus sucursales (por businesses.owner_id).
--
-- Contexto: cada sucursal es una fila en `businesses` (mismo owner_id/brand).
-- El acceso a datos lo decide el RLS de dos maneras distintas segun la tabla:
--   (a) Tablas que filtran por `id in (select current_user_business_ids())`.
--   (b) Tablas que llaman a `is_member_of_business(business_id)` /
--       `is_admin_of_business(business_id)` (p. ej. print_areas, printers).
-- Un dueno sin fila explicita en una sucursal (creada por un empleado suyo,
-- que queda con owner_id = el) no la veia por NINGUNA de las dos vias. Aqui
-- agregamos la rama `owner_id` a las TRES funciones.
--
-- IMPORTANTE: en `businesses` la PK es `id` (NO existe `business_id`). La rama
-- de owner debe ser `b.id = p_business` / `b.owner_id = auth.uid()`. Un typo
-- `b.business_id` rompe con `column b.business_id does not exist` (42703) TODA
-- RLS que use estas funciones (bloquea cocina, ventas, etc.).
--
-- NOTA: verifica primero las definiciones vivas (el repo puede diverger de
-- prod). Estas versiones preservan las ramas existentes en prod y solo agregan
-- la rama owner_id:
--   select pg_get_functiondef('public.current_user_business_ids()'::regprocedure);
--   select pg_get_functiondef('public.is_member_of_business(uuid)'::regprocedure);
--   select pg_get_functiondef('public.is_admin_of_business(uuid)'::regprocedure);

begin;

-- Indice para que el filtro por owner_id en RLS no sea seq scan.
create index if not exists idx_businesses_owner_id
  on public.businesses (owner_id);

-- (a) Funcion usada por las policies "id in (current_user_business_ids())".
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
  select b.id from public.businesses b where b.owner_id = auth.uid();
$$;

-- (b) Membresia: usada por policies de SELECT en print_areas, printers, etc.
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
           where b.id = p_business and b.owner_id = auth.uid());  -- b.id, NO b.business_id
$$;

-- (b) Admin: usada por policies de INSERT/UPDATE/DELETE (configurar areas,
-- impresoras, etc.). El dueno del negocio es admin de todas sus sucursales.
-- Preserva la rama de empleados (roles) de la version viva en prod.
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
      -- En el sistema de empleados, admin/owner tiene un rol con nivel 'admin'.
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
    );
$$;

commit;
