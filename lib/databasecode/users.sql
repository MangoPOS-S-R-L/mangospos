-- Gestión de usuarios/empleados (UI de Gestion de Usuarios)
-- Dependencias: roles_permissions.sql (roles, permissions) y fn_user_in_business

create table if not exists employees (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  user_id uuid references auth.users(id),
  first_name text not null,
  last_name text not null,
  email text not null,
  phone text not null,
  national_id text,
  gender text,
  address text,
  status text not null default 'active' check (status in ('active','inactive','password_reset')),
  hire_date date,
  contract_type text,        -- tiempo_completo, medio_tiempo, temporal
  department text,
  position text,
  work_schedule text,
  salary_base numeric(15,2),
  pay_frequency text,        -- semanal, quincenal, mensual
  afp text,
  ars text,
  bank_name text,
  bank_account text,
  pin text,
  emergency_name text,
  emergency_relation text,
  emergency_phone text,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

create table if not exists employee_roles (
  employee_id uuid references employees(id) on delete cascade,
  role_id uuid references roles(id) on delete cascade,
  primary key(employee_id, role_id)
);

create table if not exists employee_benefits (
  employee_id uuid references employees(id) on delete cascade,
  benefit text not null,
  primary key(employee_id, benefit)
);

-- RLS
alter table employees enable row level security;
alter table employee_roles enable row level security;
alter table employee_benefits enable row level security;

drop policy if exists "employees by business" on employees;
create policy "employees by business" on employees
  for all using (fn_user_in_business(business_id));

drop policy if exists "employee_roles by business" on employee_roles;
create policy "employee_roles by business" on employee_roles
  for all using (
    exists(select 1 from employees e where e.id = employee_roles.employee_id and fn_user_in_business(e.business_id))
  );

drop policy if exists "employee_benefits by business" on employee_benefits;
create policy "employee_benefits by business" on employee_benefits
  for all using (
    exists(select 1 from employees e where e.id = employee_benefits.employee_id and fn_user_in_business(e.business_id))
  );

-- Vista resumida para la tabla de UI
create or replace view v_employees_summary as
select
  e.id,
  e.business_id,
  e.first_name,
  e.last_name,
  e.email,
  e.phone,
  e.department,
  e.position,
  e.salary_base,
  e.pay_frequency,
  e.status,
  array_remove(array_agg(r.name order by r.name), null) as roles
from employees e
left join employee_roles er on er.employee_id = e.id
left join roles r on r.id = er.role_id
group by e.id;

-- helper: actualizar updated_at
create or replace function set_employees_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_employees_updated_at on employees;
create trigger trg_employees_updated_at
before update on employees
for each row
execute procedure set_employees_updated_at();
