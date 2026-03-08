-- 20260308_0022_user_access_control.sql
-- RBAC real para control de usuarios:
-- 1) siembra catalogo de permisos
-- 2) crea roles base por negocio
-- 3) agrega RPCs para leer/guardar perfil de acceso por usuario
-- 4) crea helper para crear usuarios de acceso desde auth.users

begin;

create table if not exists public.permissions (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name text not null,
  module text not null,
  description text,
  created_at timestamptz default now()
);

create table if not exists public.roles (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  name text not null,
  description text,
  is_system boolean default false,
  created_by uuid references auth.users(id),
  created_at timestamptz default now()
);

create table if not exists public.role_permissions (
  role_id uuid not null references public.roles(id) on delete cascade,
  permission_id uuid not null references public.permissions(id) on delete cascade,
  allow boolean default true,
  created_at timestamptz default now(),
  primary key (role_id, permission_id)
);

create table if not exists public.user_roles (
  user_id uuid not null references auth.users(id) on delete cascade,
  role_id uuid not null references public.roles(id) on delete cascade,
  business_id uuid not null,
  created_by uuid references auth.users(id),
  created_at timestamptz default now(),
  primary key (user_id, role_id, business_id)
);

create table if not exists public.user_permission_overrides (
  user_id uuid not null references auth.users(id) on delete cascade,
  permission_id uuid not null references public.permissions(id) on delete cascade,
  business_id uuid not null,
  allow boolean not null,
  created_by uuid references auth.users(id),
  created_at timestamptz default now(),
  primary key (user_id, permission_id, business_id)
);

alter table public.permissions
  add column if not exists code text,
  add column if not exists name text,
  add column if not exists module text,
  add column if not exists description text,
  add column if not exists created_at timestamptz default now();

alter table public.roles
  add column if not exists business_id uuid,
  add column if not exists name text,
  add column if not exists description text,
  add column if not exists is_system boolean default false,
  add column if not exists created_by uuid references auth.users(id),
  add column if not exists created_at timestamptz default now();

alter table public.role_permissions
  add column if not exists role_id uuid references public.roles(id) on delete cascade,
  add column if not exists permission_id uuid references public.permissions(id) on delete cascade,
  add column if not exists allow boolean default true,
  add column if not exists created_at timestamptz default now();

alter table public.user_roles
  add column if not exists user_id uuid references auth.users(id) on delete cascade,
  add column if not exists role_id uuid references public.roles(id) on delete cascade,
  add column if not exists business_id uuid,
  add column if not exists created_by uuid references auth.users(id),
  add column if not exists created_at timestamptz default now();

alter table public.user_permission_overrides
  add column if not exists user_id uuid references auth.users(id) on delete cascade,
  add column if not exists permission_id uuid references public.permissions(id) on delete cascade,
  add column if not exists business_id uuid,
  add column if not exists allow boolean,
  add column if not exists created_by uuid references auth.users(id),
  add column if not exists created_at timestamptz default now();

create or replace function public.fn_user_in_business(p_business_id uuid)
returns boolean
language sql
stable
as $$
  select exists (
    select 1
    from public.user_businesses ub
    where ub.business_id = p_business_id
      and ub.user_id = auth.uid()
  );
$$;

drop view if exists public.me_permissions;
drop function if exists public.fn_user_effective_permissions(uuid, uuid);

create function public.fn_user_effective_permissions(
  p_user_id uuid,
  p_business_id uuid
)
returns table(code text, allowed boolean)
language plpgsql
stable
as $$
begin
  return query
  with role_perms as (
    select p.code, rp.allow
    from public.user_roles ur
    join public.roles r
      on r.id = ur.role_id
     and r.business_id = ur.business_id
    join public.role_permissions rp
      on rp.role_id = r.id
    join public.permissions p
      on p.id = rp.permission_id
    where ur.user_id = p_user_id
      and ur.business_id = p_business_id
  ),
  base as (
    select code, bool_or(allow) as allowed
    from role_perms
    group by code
  ),
  overrides as (
    select p.code, o.allow
    from public.user_permission_overrides o
    join public.permissions p
      on p.id = o.permission_id
    where o.user_id = p_user_id
      and o.business_id = p_business_id
  )
  select coalesce(o.code, b.code) as code,
         coalesce(o.allow, b.allowed) as allowed
  from base b
  full outer join overrides o
    on o.code = b.code;
end;
$$;

create or replace view public.me_permissions
with (security_invoker = on) as
select code, allowed
from public.fn_user_effective_permissions(
  auth.uid(),
  current_setting('app.current_business', true)::uuid
);

alter table public.permissions enable row level security;
alter table public.roles enable row level security;
alter table public.role_permissions enable row level security;
alter table public.user_roles enable row level security;
alter table public.user_permission_overrides enable row level security;

drop policy if exists "permissions_read_authenticated" on public.permissions;
create policy "permissions_read_authenticated"
on public.permissions
for select
to authenticated
using (true);

drop policy if exists "roles by business" on public.roles;
create policy "roles by business"
on public.roles
using (public.fn_user_in_business(business_id));

drop policy if exists "role_permissions by business" on public.role_permissions;
create policy "role_permissions by business"
on public.role_permissions
using (
  exists (
    select 1
    from public.roles r
    where r.id = role_permissions.role_id
      and public.fn_user_in_business(r.business_id)
  )
);

drop policy if exists "user_roles by business" on public.user_roles;
create policy "user_roles by business"
on public.user_roles
using (public.fn_user_in_business(business_id));

drop policy if exists "overrides by business" on public.user_permission_overrides;
create policy "overrides by business"
on public.user_permission_overrides
using (public.fn_user_in_business(business_id));

insert into public.permissions (code, name, module, description)
values
  ('ventas.mesas.acceso','Acceso a salon y mesas','restaurant','Abre el modulo de mesas y el mapa de salon.'),
  ('ventas.mesas.ver_estado','Ver estado de mesas','restaurant','Consulta ocupacion y estado de mesas.'),
  ('ventas.mesas.abrir','Abrir mesas','restaurant','Crea o retoma una cuenta en mesa.'),
  ('ventas.mesas.mover_unir','Mover o unir mesas','operations','Permite mover una cuenta o fusionar mesas.'),
  ('ventas.mesas.marcar_pagando','Marcar mesa pagando','operations','Marca una mesa en proceso de cobro.'),
  ('ventas.mesas.liberar','Liberar mesa','operations','Libera una mesa despues de cerrar la cuenta.'),
  ('ventas.orden.ver_total','Ver total de la orden','restaurant','Muestra totales e impuestos de la orden.'),
  ('ventas.orden.agregar_item','Agregar productos a la orden','restaurant','Agrega productos y recetas a una cuenta.'),
  ('ventas.orden.editar_item','Editar lineas de orden','restaurant','Edita cantidad, notas y takeout.'),
  ('ventas.orden.eliminar_item','Eliminar lineas de orden','operations','Quita productos antes del cobro.'),
  ('ventas.orden.enviar_cocina','Enviar a cocina','kds','Confirma items pendientes y los envia a cocina.'),
  ('ventas.orden.descuento_aplicar','Aplicar descuento en orden','finance','Permite descuentos por linea u orden.'),
  ('ventas.orden.anular','Anular orden','operations','Anula una orden abierta o enviada.'),
  ('ventas.orden.reabrir','Reabrir orden','operations','Reabre una orden cerrada.'),
  ('ventas.cuenta.split_manual','Dividir cuenta manual','operations','Mueve lineas entre subcuentas.'),
  ('ventas.cuenta.split_equiv','Dividir cuenta equitativa','operations','Divide la cuenta automaticamente.'),
  ('ventas_rapida.acceso','Acceso a venta rapida','restaurant','Abre el modulo de venta rapida.'),
  ('ventas_rapida.crear_orden','Crear orden rapida','restaurant','Crea una orden rapida o express.'),
  ('ventas_rapida.enviar_cocina','Enviar venta rapida a cocina','kds','Envia venta rapida a cocina.'),
  ('ventas_rapida.cobrar_inmediato','Cobro inmediato en venta rapida','finance','Permite cobrar una venta rapida.'),
  ('pagos.acceso','Abrir modal de pagos','finance','Abre el flujo de cobro.'),
  ('pagos.cobrar_efectivo','Cobrar en efectivo','finance','Registra pagos en efectivo.'),
  ('pagos.cobrar_tarjeta','Cobrar con tarjeta','finance','Registra pagos con tarjeta.'),
  ('pagos.cobrar_transferencia','Cobrar por transferencia','finance','Registra pagos por transferencia.'),
  ('pagos.asignar_referencia','Asignar referencia de pago','finance','Guarda referencias bancarias.'),
  ('pagos.anular_pago','Anular pagos','finance','Revierte pagos registrados.'),
  ('pagos.reimprimir_recibo','Reimprimir recibos','finance','Reimprime recibos y comprobantes.'),
  ('caja.apertura','Abrir caja','finance','Permite aperturar una caja.'),
  ('caja.cierre','Cerrar caja','finance','Permite cerrar caja y arqueo.'),
  ('caja.movimientos_ver','Ver movimientos de caja','finance','Consulta movimientos de caja.'),
  ('caja.arqueo_ver','Ver arqueos','finance','Consulta cierres y arqueos.'),
  ('kds.acceso','Acceso a cocina','kds','Abre la pantalla de cocina.'),
  ('kds.ver_comandas','Ver comandas','kds','Consulta comandas activas en cocina.'),
  ('kds.cambiar_estado','Cambiar estado de comanda','kds','Permite pasar items a preparando/listo/servido.'),
  ('kds.reimprimir_comanda','Reimprimir comanda','kds','Reimprime comandas de cocina.'),
  ('clientes.ver','Ver clientes','delivery','Consulta clientes y su historial.'),
  ('clientes.crear_editar','Crear o editar clientes','delivery','Permite crear y editar clientes.'),
  ('clientes.asignar_a_mesa','Asignar cliente a mesa','delivery','Vincula clientes a una mesa o cuenta.'),
  ('delivery.crear_orden','Crear orden delivery','delivery','Crea pedidos de delivery o despacho.'),
  ('delivery.asignar_repartidor','Asignar repartidor','delivery','Asigna un pedido a un repartidor.'),
  ('delivery.marcar_entregado','Marcar delivery entregado','delivery','Completa la entrega de un pedido.'),
  ('inventario.acceso','Acceso a inventario','inventory','Abre el modulo de inventario.'),
  ('inventario.productos.crear_editar','Crear o editar insumos','inventory','Gestiona insumos y stock items.'),
  ('inventario.ajustes.crear','Registrar ajustes de inventario','inventory','Permite entradas, salidas y conciliaciones.'),
  ('compras.proveedores.crear_editar','Crear o editar proveedores','inventory','Gestiona proveedores.'),
  ('compras.ordenes.crear','Crear ordenes de compra','inventory','Genera ordenes de compra.'),
  ('compras.ordenes.recibir','Recibir ordenes de compra','inventory','Recibe compras y sube stock.'),
  ('compras.ordenes.anular','Anular ordenes de compra','inventory','Revierte o anula una compra.'),
  ('reportes.ventas','Reporte de ventas','reports','Consulta ventas y tendencias.'),
  ('reportes.productos','Reporte de productos','reports','Consulta desempeno de menu.'),
  ('reportes.caja','Reporte de caja','reports','Consulta cierres y movimientos.'),
  ('reportes.fiscales','Reporte fiscal','reports','Consulta comprobantes y estado fiscal.'),
  ('settings.usuarios.acceso','Acceso a usuarios','settings','Abre la gestion de usuarios.'),
  ('settings.usuarios.ver','Ver usuarios','settings','Consulta listado y detalle de usuarios.'),
  ('settings.usuarios.crear','Crear usuarios','settings','Permite crear usuarios.'),
  ('settings.usuarios.editar','Editar usuarios','settings','Permite modificar usuarios.'),
  ('settings.usuarios.desactivar','Desactivar usuarios','settings','Permite desactivar usuarios.'),
  ('settings.roles.acceso','Acceso a roles','settings','Abre la gestion de roles.'),
  ('settings.roles.ver','Ver roles','settings','Consulta roles.'),
  ('settings.roles.crear','Crear roles','settings','Crea roles del negocio.'),
  ('settings.roles.editar','Editar roles','settings','Edita roles del negocio.'),
  ('settings.roles.eliminar','Eliminar roles','settings','Elimina roles no protegidos.'),
  ('settings.impresoras.gestionar','Gestionar impresoras y areas','settings','Configura impresoras y areas.'),
  ('settings.zonas_mesas.gestionar','Gestionar zonas y mesas','settings','Configura zonas y layout de mesas.'),
  ('settings.impuestos_fiscal.gestionar','Gestionar impuestos y NCF','settings','Configura ITBIS y parametros fiscales.'),
  ('settings.metodos_pago.gestionar','Gestionar metodos de pago','settings','Configura medios de pago.'),
  ('settings.descuentos_propinas.gestionar','Gestionar descuentos y propinas','settings','Configura descuentos y propinas.'),
  ('settings.kds.gestionar','Gestionar KDS e impresion','settings','Configura KDS y targets de cocina.')
on conflict (code) do update
set name = excluded.name,
    module = excluded.module,
    description = excluded.description;

create or replace function public.fn_seed_business_rbac_defaults(p_business_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_business_id is null then
    return;
  end if;

  insert into public.roles (business_id, name, description, is_system)
  select
    p_business_id,
    seed.name,
    seed.description,
    true
  from (
    values
      ('owner', 'Propietario del negocio'),
      ('admin', 'Administrador del negocio'),
      ('manager', 'Supervisor / gerente de turno'),
      ('cashier', 'Cajero'),
      ('waiter', 'Mesero'),
      ('cook', 'Cocina'),
      ('delivery', 'Delivery')
  ) as seed(name, description)
  where not exists (
    select 1
    from public.roles r
    where r.business_id = p_business_id
      and lower(r.name) = seed.name
  );

  delete from public.role_permissions rp
  using public.roles r
  where r.id = rp.role_id
    and r.business_id = p_business_id
    and r.is_system = true
    and lower(r.name) in ('owner', 'admin', 'manager', 'cashier', 'waiter', 'cook', 'delivery');

  insert into public.role_permissions (role_id, permission_id, allow)
  select r.id, p.id, true
  from public.roles r
  join (
    values
      ('owner','ventas.mesas.acceso'),
      ('owner','ventas.mesas.ver_estado'),
      ('owner','ventas.mesas.abrir'),
      ('owner','ventas.mesas.mover_unir'),
      ('owner','ventas.mesas.marcar_pagando'),
      ('owner','ventas.mesas.liberar'),
      ('owner','ventas.orden.ver_total'),
      ('owner','ventas.orden.agregar_item'),
      ('owner','ventas.orden.editar_item'),
      ('owner','ventas.orden.eliminar_item'),
      ('owner','ventas.orden.enviar_cocina'),
      ('owner','ventas.orden.descuento_aplicar'),
      ('owner','ventas.orden.anular'),
      ('owner','ventas.orden.reabrir'),
      ('owner','ventas.cuenta.split_manual'),
      ('owner','ventas.cuenta.split_equiv'),
      ('owner','ventas_rapida.acceso'),
      ('owner','ventas_rapida.crear_orden'),
      ('owner','ventas_rapida.enviar_cocina'),
      ('owner','ventas_rapida.cobrar_inmediato'),
      ('owner','pagos.acceso'),
      ('owner','pagos.cobrar_efectivo'),
      ('owner','pagos.cobrar_tarjeta'),
      ('owner','pagos.cobrar_transferencia'),
      ('owner','pagos.asignar_referencia'),
      ('owner','pagos.anular_pago'),
      ('owner','pagos.reimprimir_recibo'),
      ('owner','caja.apertura'),
      ('owner','caja.cierre'),
      ('owner','caja.movimientos_ver'),
      ('owner','caja.arqueo_ver'),
      ('owner','kds.acceso'),
      ('owner','kds.ver_comandas'),
      ('owner','kds.cambiar_estado'),
      ('owner','kds.reimprimir_comanda'),
      ('owner','clientes.ver'),
      ('owner','clientes.crear_editar'),
      ('owner','clientes.asignar_a_mesa'),
      ('owner','delivery.crear_orden'),
      ('owner','delivery.asignar_repartidor'),
      ('owner','delivery.marcar_entregado'),
      ('owner','inventario.acceso'),
      ('owner','inventario.productos.crear_editar'),
      ('owner','inventario.ajustes.crear'),
      ('owner','compras.proveedores.crear_editar'),
      ('owner','compras.ordenes.crear'),
      ('owner','compras.ordenes.recibir'),
      ('owner','compras.ordenes.anular'),
      ('owner','reportes.ventas'),
      ('owner','reportes.productos'),
      ('owner','reportes.caja'),
      ('owner','reportes.fiscales'),
      ('owner','settings.usuarios.acceso'),
      ('owner','settings.usuarios.ver'),
      ('owner','settings.usuarios.crear'),
      ('owner','settings.usuarios.editar'),
      ('owner','settings.usuarios.desactivar'),
      ('owner','settings.roles.acceso'),
      ('owner','settings.roles.ver'),
      ('owner','settings.roles.crear'),
      ('owner','settings.roles.editar'),
      ('owner','settings.roles.eliminar'),
      ('owner','settings.impresoras.gestionar'),
      ('owner','settings.zonas_mesas.gestionar'),
      ('owner','settings.impuestos_fiscal.gestionar'),
      ('owner','settings.metodos_pago.gestionar'),
      ('owner','settings.descuentos_propinas.gestionar'),
      ('owner','settings.kds.gestionar'),

      ('admin','ventas.mesas.acceso'),
      ('admin','ventas.mesas.ver_estado'),
      ('admin','ventas.mesas.abrir'),
      ('admin','ventas.mesas.mover_unir'),
      ('admin','ventas.mesas.marcar_pagando'),
      ('admin','ventas.mesas.liberar'),
      ('admin','ventas.orden.ver_total'),
      ('admin','ventas.orden.agregar_item'),
      ('admin','ventas.orden.editar_item'),
      ('admin','ventas.orden.eliminar_item'),
      ('admin','ventas.orden.enviar_cocina'),
      ('admin','ventas.orden.descuento_aplicar'),
      ('admin','ventas.orden.anular'),
      ('admin','ventas.orden.reabrir'),
      ('admin','ventas.cuenta.split_manual'),
      ('admin','ventas.cuenta.split_equiv'),
      ('admin','ventas_rapida.acceso'),
      ('admin','ventas_rapida.crear_orden'),
      ('admin','ventas_rapida.enviar_cocina'),
      ('admin','ventas_rapida.cobrar_inmediato'),
      ('admin','pagos.acceso'),
      ('admin','pagos.cobrar_efectivo'),
      ('admin','pagos.cobrar_tarjeta'),
      ('admin','pagos.cobrar_transferencia'),
      ('admin','pagos.asignar_referencia'),
      ('admin','pagos.anular_pago'),
      ('admin','pagos.reimprimir_recibo'),
      ('admin','caja.apertura'),
      ('admin','caja.cierre'),
      ('admin','caja.movimientos_ver'),
      ('admin','caja.arqueo_ver'),
      ('admin','kds.acceso'),
      ('admin','kds.ver_comandas'),
      ('admin','kds.cambiar_estado'),
      ('admin','kds.reimprimir_comanda'),
      ('admin','clientes.ver'),
      ('admin','clientes.crear_editar'),
      ('admin','clientes.asignar_a_mesa'),
      ('admin','delivery.crear_orden'),
      ('admin','delivery.asignar_repartidor'),
      ('admin','delivery.marcar_entregado'),
      ('admin','inventario.acceso'),
      ('admin','inventario.productos.crear_editar'),
      ('admin','inventario.ajustes.crear'),
      ('admin','compras.proveedores.crear_editar'),
      ('admin','compras.ordenes.crear'),
      ('admin','compras.ordenes.recibir'),
      ('admin','compras.ordenes.anular'),
      ('admin','reportes.ventas'),
      ('admin','reportes.productos'),
      ('admin','reportes.caja'),
      ('admin','reportes.fiscales'),
      ('admin','settings.usuarios.acceso'),
      ('admin','settings.usuarios.ver'),
      ('admin','settings.usuarios.crear'),
      ('admin','settings.usuarios.editar'),
      ('admin','settings.usuarios.desactivar'),
      ('admin','settings.roles.acceso'),
      ('admin','settings.roles.ver'),
      ('admin','settings.roles.crear'),
      ('admin','settings.roles.editar'),
      ('admin','settings.roles.eliminar'),
      ('admin','settings.impresoras.gestionar'),
      ('admin','settings.zonas_mesas.gestionar'),
      ('admin','settings.impuestos_fiscal.gestionar'),
      ('admin','settings.metodos_pago.gestionar'),
      ('admin','settings.descuentos_propinas.gestionar'),
      ('admin','settings.kds.gestionar'),

      ('manager','ventas.mesas.acceso'),
      ('manager','ventas.mesas.ver_estado'),
      ('manager','ventas.mesas.abrir'),
      ('manager','ventas.mesas.mover_unir'),
      ('manager','ventas.mesas.marcar_pagando'),
      ('manager','ventas.mesas.liberar'),
      ('manager','ventas.orden.ver_total'),
      ('manager','ventas.orden.agregar_item'),
      ('manager','ventas.orden.editar_item'),
      ('manager','ventas.orden.eliminar_item'),
      ('manager','ventas.orden.enviar_cocina'),
      ('manager','ventas.orden.descuento_aplicar'),
      ('manager','ventas.orden.anular'),
      ('manager','ventas.orden.reabrir'),
      ('manager','ventas.cuenta.split_manual'),
      ('manager','ventas.cuenta.split_equiv'),
      ('manager','ventas_rapida.acceso'),
      ('manager','ventas_rapida.crear_orden'),
      ('manager','ventas_rapida.enviar_cocina'),
      ('manager','ventas_rapida.cobrar_inmediato'),
      ('manager','pagos.acceso'),
      ('manager','pagos.cobrar_efectivo'),
      ('manager','pagos.cobrar_tarjeta'),
      ('manager','pagos.cobrar_transferencia'),
      ('manager','pagos.asignar_referencia'),
      ('manager','pagos.anular_pago'),
      ('manager','pagos.reimprimir_recibo'),
      ('manager','caja.apertura'),
      ('manager','caja.cierre'),
      ('manager','caja.movimientos_ver'),
      ('manager','caja.arqueo_ver'),
      ('manager','kds.acceso'),
      ('manager','kds.ver_comandas'),
      ('manager','kds.cambiar_estado'),
      ('manager','kds.reimprimir_comanda'),
      ('manager','clientes.ver'),
      ('manager','clientes.crear_editar'),
      ('manager','clientes.asignar_a_mesa'),
      ('manager','delivery.crear_orden'),
      ('manager','delivery.asignar_repartidor'),
      ('manager','delivery.marcar_entregado'),
      ('manager','inventario.acceso'),
      ('manager','inventario.productos.crear_editar'),
      ('manager','inventario.ajustes.crear'),
      ('manager','compras.proveedores.crear_editar'),
      ('manager','compras.ordenes.crear'),
      ('manager','compras.ordenes.recibir'),
      ('manager','compras.ordenes.anular'),
      ('manager','reportes.ventas'),
      ('manager','reportes.productos'),
      ('manager','reportes.caja'),
      ('manager','reportes.fiscales'),
      ('manager','settings.usuarios.acceso'),
      ('manager','settings.usuarios.ver'),
      ('manager','settings.impresoras.gestionar'),
      ('manager','settings.zonas_mesas.gestionar'),
      ('manager','settings.descuentos_propinas.gestionar'),
      ('manager','settings.kds.gestionar'),

      ('cashier','ventas.mesas.acceso'),
      ('cashier','ventas.mesas.ver_estado'),
      ('cashier','ventas.orden.ver_total'),
      ('cashier','ventas_rapida.acceso'),
      ('cashier','ventas_rapida.crear_orden'),
      ('cashier','ventas_rapida.cobrar_inmediato'),
      ('cashier','pagos.acceso'),
      ('cashier','pagos.cobrar_efectivo'),
      ('cashier','pagos.cobrar_tarjeta'),
      ('cashier','pagos.cobrar_transferencia'),
      ('cashier','pagos.asignar_referencia'),
      ('cashier','pagos.reimprimir_recibo'),
      ('cashier','caja.apertura'),
      ('cashier','caja.cierre'),
      ('cashier','caja.movimientos_ver'),
      ('cashier','caja.arqueo_ver'),
      ('cashier','clientes.ver'),
      ('cashier','reportes.caja'),
      ('cashier','reportes.ventas'),

      ('waiter','ventas.mesas.acceso'),
      ('waiter','ventas.mesas.ver_estado'),
      ('waiter','ventas.mesas.abrir'),
      ('waiter','ventas.mesas.marcar_pagando'),
      ('waiter','ventas.orden.ver_total'),
      ('waiter','ventas.orden.agregar_item'),
      ('waiter','ventas.orden.editar_item'),
      ('waiter','ventas.orden.eliminar_item'),
      ('waiter','ventas.orden.enviar_cocina'),
      ('waiter','ventas.cuenta.split_manual'),
      ('waiter','ventas.cuenta.split_equiv'),
      ('waiter','clientes.ver'),
      ('waiter','clientes.asignar_a_mesa'),

      ('cook','kds.acceso'),
      ('cook','kds.ver_comandas'),
      ('cook','kds.cambiar_estado'),
      ('cook','kds.reimprimir_comanda'),

      ('delivery','delivery.crear_orden'),
      ('delivery','delivery.asignar_repartidor'),
      ('delivery','delivery.marcar_entregado'),
      ('delivery','clientes.ver'),
      ('delivery','ventas_rapida.acceso'),
      ('delivery','ventas_rapida.crear_orden'),
      ('delivery','ventas.orden.ver_total')
  ) as matrix(role_name, permission_code)
    on matrix.role_name = lower(r.name)
  join public.permissions p on p.code = matrix.permission_code
  where r.business_id = p_business_id
    and r.is_system = true;

  insert into public.user_roles (user_id, role_id, business_id, created_by)
  select
    ub.user_id,
    r.id,
    ub.business_id,
    auth.uid()
  from public.user_businesses ub
  join public.roles r
    on r.business_id = ub.business_id
   and r.is_system = true
   and lower(r.name) = (
     case
       when ub.role in ('owner','admin','manager','cashier','waiter','delivery') then ub.role
       when ub.role in ('cook','chef') then 'cook'
       else 'waiter'
     end
   )
  where ub.business_id = p_business_id
  on conflict do nothing;
end;
$$;

create or replace function public.create_new_user(
  email text,
  password text,
  user_metadata jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  new_user_id uuid := gen_random_uuid();
  full_name text;
begin
  if email is null or trim(email) = '' then
    raise exception 'EMAIL_REQUIRED';
  end if;
  if password is null or length(password) < 6 then
    raise exception 'PASSWORD_TOO_SHORT';
  end if;

  full_name := nullif(trim(
    coalesce(user_metadata->>'full_name', '') || ' ' ||
    coalesce(user_metadata->>'last_name', '')
  ), '');

  if full_name is null or full_name = '' then
    full_name := coalesce(user_metadata->>'full_name', email);
  end if;

  insert into auth.users (
    id,
    instance_id,
    aud,
    role,
    email,
    encrypted_password,
    email_confirmed_at,
    raw_app_meta_data,
    raw_user_meta_data,
    created_at,
    updated_at,
    confirmation_token,
    email_change,
    email_change_token_new,
    recovery_token
  )
  values (
    new_user_id,
    '00000000-0000-0000-0000-000000000000',
    'authenticated',
    'authenticated',
    lower(trim(email)),
    crypt(password, gen_salt('bf')),
    now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    coalesce(user_metadata, '{}'::jsonb),
    now(),
    now(),
    '',
    '',
    '',
    ''
  );

  insert into auth.identities (
    id,
    user_id,
    identity_data,
    provider,
    provider_id,
    last_sign_in_at,
    created_at,
    updated_at
  )
  values (
    gen_random_uuid(),
    new_user_id,
    jsonb_build_object(
      'sub', new_user_id::text,
      'email', lower(trim(email))
    ),
    'email',
    new_user_id::text,
    now(),
    now(),
    now()
  );

  insert into public.profiles (id, email, full_name, created_at, updated_at)
  values (new_user_id, lower(trim(email)), full_name, now(), now())
  on conflict (id) do update
  set email = excluded.email,
      full_name = excluded.full_name,
      updated_at = now();

  return new_user_id;
end;
$$;

create or replace function public.fn_get_user_access_profile(
  p_employee_id uuid,
  p_business_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_employee public.employees;
  v_user_id uuid;
  v_primary_role text;
  v_role_ids uuid[];
  v_effective_codes text[];
begin
  if public.user_business_role(auth.uid(), p_business_id) not in ('owner', 'admin', 'manager') then
    raise exception 'ACCESS_DENIED';
  end if;

  select *
    into v_employee
  from public.employees
  where id = p_employee_id
    and business_id = p_business_id;

  if not found then
    raise exception 'EMPLOYEE_NOT_FOUND';
  end if;

  v_user_id := v_employee.user_id;

  select coalesce(array_agg(er.role_id order by r.name), array[]::uuid[])
    into v_role_ids
  from public.employee_roles er
  join public.roles r on r.id = er.role_id
  where er.employee_id = p_employee_id;

  if v_user_id is not null then
    select ub.role
      into v_primary_role
    from public.user_businesses ub
    where ub.user_id = v_user_id
      and ub.business_id = p_business_id
    limit 1;
  end if;

  if v_primary_role is null then
    select
      case
        when lower(r.name) in ('owner','admin','manager','cashier','waiter','delivery') then lower(r.name)
        when lower(r.name) in ('cook','chef') then 'cook'
        else null
      end
      into v_primary_role
    from public.roles r
    where r.id = any(v_role_ids)
    order by
      case lower(r.name)
        when 'owner' then 1
        when 'admin' then 2
        when 'manager' then 3
        when 'cashier' then 4
        when 'waiter' then 5
        when 'cook' then 6
        when 'delivery' then 7
        else 99
      end
    limit 1;
  end if;

  if v_user_id is not null then
    select coalesce(array_agg(code order by code), array[]::text[])
      into v_effective_codes
    from public.fn_user_effective_permissions(v_user_id, p_business_id)
    where allowed = true;
  else
    select coalesce(array_agg(distinct p.code order by p.code), array[]::text[])
      into v_effective_codes
    from public.role_permissions rp
    join public.permissions p on p.id = rp.permission_id
    where rp.role_id = any(v_role_ids)
      and coalesce(rp.allow, true) = true;
  end if;

  return jsonb_build_object(
    'employee_id', p_employee_id,
    'user_id', v_user_id,
    'has_login', v_user_id is not null,
    'primary_role', coalesce(v_primary_role, 'waiter'),
    'role_ids', coalesce(to_jsonb(v_role_ids), '[]'::jsonb),
    'effective_permissions', coalesce(to_jsonb(v_effective_codes), '[]'::jsonb)
  );
end;
$$;

create or replace function public.fn_save_user_access_profile(
  p_employee_id uuid,
  p_business_id uuid,
  p_role_ids uuid[],
  p_primary_role text,
  p_effective_permission_codes text[]
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_employee public.employees;
  v_user_id uuid;
  v_normalized_role text;
begin
  if public.user_business_role(auth.uid(), p_business_id) not in ('owner', 'admin') then
    raise exception 'ACCESS_DENIED';
  end if;

  select *
    into v_employee
  from public.employees
  where id = p_employee_id
    and business_id = p_business_id;

  if not found then
    raise exception 'EMPLOYEE_NOT_FOUND';
  end if;

  v_user_id := v_employee.user_id;
  v_normalized_role := case
    when lower(coalesce(p_primary_role, '')) in ('owner','admin','manager','cashier','waiter','delivery') then lower(p_primary_role)
    when lower(coalesce(p_primary_role, '')) in ('cook','chef') then 'cook'
    else 'waiter'
  end;

  delete from public.employee_roles where employee_id = p_employee_id;

  if coalesce(array_length(p_role_ids, 1), 0) > 0 then
    insert into public.employee_roles (employee_id, role_id)
    select p_employee_id, role_id
    from unnest(p_role_ids) as role_id
    on conflict do nothing;
  end if;

  if v_user_id is null then
    return;
  end if;

  insert into public.user_businesses (user_id, business_id, role, permissions, created_at)
  values (
    v_user_id,
    p_business_id,
    v_normalized_role,
    case when v_normalized_role in ('owner', 'admin') then array['all']::text[] else array[]::text[] end,
    now()
  )
  on conflict (user_id, business_id) do update
    set role = excluded.role,
        permissions = excluded.permissions;

  delete from public.user_roles
  where user_id = v_user_id
    and business_id = p_business_id;

  if coalesce(array_length(p_role_ids, 1), 0) > 0 then
    insert into public.user_roles (user_id, role_id, business_id, created_by)
    select v_user_id, role_id, p_business_id, auth.uid()
    from unnest(p_role_ids) as role_id
    on conflict do nothing;
  end if;

  delete from public.user_permission_overrides
  where user_id = v_user_id
    and business_id = p_business_id;

  with base_codes as (
    select distinct p.code
    from public.role_permissions rp
    join public.permissions p on p.id = rp.permission_id
    where rp.role_id = any(coalesce(p_role_ids, array[]::uuid[]))
      and coalesce(rp.allow, true) = true
  ),
  desired_codes as (
    select distinct code
    from unnest(coalesce(p_effective_permission_codes, array[]::text[])) as code
  ),
  allow_extra as (
    select d.code
    from desired_codes d
    left join base_codes b on b.code = d.code
    where b.code is null
  ),
  deny_missing as (
    select b.code
    from base_codes b
    left join desired_codes d on d.code = b.code
    where d.code is null
  )
  insert into public.user_permission_overrides (
    user_id,
    permission_id,
    business_id,
    allow,
    created_by
  )
  select v_user_id, p.id, p_business_id, true, auth.uid()
  from allow_extra a
  join public.permissions p on p.code = a.code
  union all
  select v_user_id, p.id, p_business_id, false, auth.uid()
  from deny_missing d
  join public.permissions p on p.code = d.code;
end;
$$;

do $$
declare
  v_business_id uuid;
begin
  for v_business_id in
    select id from public.businesses
  loop
    perform public.fn_seed_business_rbac_defaults(v_business_id);
  end loop;
end $$;

grant execute on function public.fn_seed_business_rbac_defaults(uuid) to authenticated;
grant execute on function public.fn_user_effective_permissions(uuid, uuid) to authenticated;
grant execute on function public.fn_user_in_business(uuid) to authenticated;
grant execute on function public.fn_get_user_access_profile(uuid, uuid) to authenticated;
grant execute on function public.fn_save_user_access_profile(uuid, uuid, uuid[], text, text[]) to authenticated;
grant execute on function public.create_new_user(text, text, jsonb) to authenticated;
grant select on public.me_permissions to authenticated;

commit;
