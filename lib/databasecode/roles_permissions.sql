-- RBAC para MangoPOS alineado con backend data structure/roles_usuarios_mangopos.txt
-- Crea tablas de roles, permisos, asignaciones y auditoria.

-- ==========================================
-- TABLAS BASICAS
-- ==========================================
create table if not exists permissions (
    id uuid primary key default gen_random_uuid(),
    code text not null unique,              -- ej: ventas.orden.enviar_cocina
    name text not null,                     -- label corto
    module text not null,                   -- agrupador (ventas, pagos, kds, settings, etc)
    description text,
    created_at timestamptz default now()
);

create table if not exists roles (
    id uuid primary key default gen_random_uuid(),
    business_id uuid not null,              -- scope por negocio/sucursal
    name text not null,
    description text,
    is_system boolean default false,        -- true: roles base protegidos
    created_by uuid references auth.users(id),
    created_at timestamptz default now()
);

create table if not exists role_permissions (
    role_id uuid references roles(id) on delete cascade,
    permission_id uuid references permissions(id) on delete cascade,
    allow boolean default true,
    created_at timestamptz default now(),
    primary key (role_id, permission_id)
);

create table if not exists user_roles (
    user_id uuid references auth.users(id) on delete cascade,
    role_id uuid references roles(id) on delete cascade,
    business_id uuid not null,              -- permite que un usuario tenga rol por sucursal
    created_by uuid references auth.users(id),
    created_at timestamptz default now(),
    primary key (user_id, role_id, business_id)
);

create table if not exists user_permission_overrides (
    user_id uuid references auth.users(id) on delete cascade,
    permission_id uuid references permissions(id) on delete cascade,
    business_id uuid not null,
    allow boolean not null,                 -- true = concede, false = revoca
    created_by uuid references auth.users(id),
    created_at timestamptz default now(),
    primary key (user_id, permission_id, business_id)
);

create table if not exists audit_logs (
    id uuid primary key default gen_random_uuid(),
    business_id uuid not null,
    user_id uuid references auth.users(id),
    action text not null,                   -- ej: ventas.orden.anular
    reason text,
    ref_table text,
    ref_id uuid,
    created_at timestamptz default now()
);

-- ==========================================
-- RLS (scoping por negocio via user_businesses)
-- ==========================================
alter table roles enable row level security;
alter table role_permissions enable row level security;
alter table user_roles enable row level security;
alter table user_permission_overrides enable row level security;
alter table audit_logs enable row level security;

-- helpers: valida que el usuario pertenece al negocio
create or replace function fn_user_in_business(p_business_id uuid)
returns boolean language sql stable as $$
select exists (
  select 1 from user_businesses ub
  where ub.business_id = p_business_id and ub.user_id = auth.uid()
);
$$;

-- roles
drop policy if exists "roles by business" on roles;
create policy "roles by business" on roles
  for all using (fn_user_in_business(business_id));

-- role_permissions: validar rol pertenece al mismo negocio
drop policy if exists "role_permissions by business" on role_permissions;
create policy "role_permissions by business" on role_permissions
  for all using (
    exists (
      select 1 from roles r
      where r.id = role_permissions.role_id
        and fn_user_in_business(r.business_id)
    )
  );

-- user_roles
drop policy if exists "user_roles by business" on user_roles;
create policy "user_roles by business" on user_roles
  for all using (fn_user_in_business(business_id));

-- overrides
drop policy if exists "overrides by business" on user_permission_overrides;
create policy "overrides by business" on user_permission_overrides
  for all using (fn_user_in_business(business_id));

-- audit
drop policy if exists "audit by business" on audit_logs;
create policy "audit by business" on audit_logs
  for all using (fn_user_in_business(business_id));

-- ==========================================
-- VISTAS / FUNCIONES DE RESOLUCION
-- ==========================================
-- Devuelve permisos efectivos de un usuario para un negocio, consolidando roles y overrides.
create or replace function fn_user_effective_permissions(
  p_user_id uuid,
  p_business_id uuid
) returns table (code text, allowed boolean) as $$
begin
  return query
  with role_perms as (
    select p.code as perm_code, rp.allow
    from user_roles ur
    join roles r on r.id = ur.role_id and r.business_id = ur.business_id
    join role_permissions rp on rp.role_id = r.id
    join permissions p on p.id = rp.permission_id
    where ur.user_id = p_user_id and ur.business_id = p_business_id
  ),
  base as (
    select perm_code as code_base, bool_or(allow) as allowed_base
    from role_perms
    group by perm_code
  ),
  overrides as (
    select p.code as code_override, o.allow as allow_override
    from user_permission_overrides o
    join permissions p on p.id = o.permission_id
    where o.user_id = p_user_id and o.business_id = p_business_id
  )
  select coalesce(o.code_override, b.code_base) as code,
         coalesce(o.allow_override, b.allowed_base) as allowed
  from base b
  full outer join overrides o on o.code_override = b.code_base;
end;
$$ language plpgsql stable;

-- Vista rapida para el usuario autenticado y negocio actual
create or replace view me_permissions as
select code, allowed
from fn_user_effective_permissions(auth.uid(), current_setting('app.current_business', true)::uuid);

-- ==========================================
-- SEEDS MINIMOS (opcional)
-- ==========================================
-- Inserta codigos base solo si no existen.
insert into permissions (code, name, module)
values
  ('settings.usuarios.acceso','Ajustes: usuarios','settings'),
  ('settings.roles.acceso','Ajustes: roles','settings'),
  ('ventas.mesas.acceso','Ventas: mesas','ventas'),
  ('ventas.orden.agregar_item','Ventas: agregar item','ventas'),
  ('pagos.acceso','Pagos: abrir modal','pagos'),
  ('caja.apertura','Caja: apertura','caja'),
  ('kds.acceso','KDS acceso','kds'),
  ('reportes.ventas','Reportes ventas','reportes')
on conflict (code) do nothing;

-- ==========================================
-- NOTAS
-- - Establecer app.current_business en la sesion al autenticar.
-- - Para acciones criticas loguear en audit_logs con reason y ref_id.
-- - Agregar permisos adicionales segun el catalogo del archivo de roles.
