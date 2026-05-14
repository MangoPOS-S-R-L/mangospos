-- Sprint 1 Inventario quick wins.
--
-- Agrega tres nuevas llaves de permiso al sistema de control de acceso:
--
--   - compras.acceso                       (entrada al modulo de compras)
--   - inventario.transferencias.crear      (enviar stock desde almacen principal)
--   - inventario.transferencias.recibir    (confirmar recepcion en bodega destino)
--
-- Estas llaves ya existen en el catalogo Dart (lib/core/security/access_control_catalog.dart)
-- y la UI las consume. Esta migracion las inserta en `public.permissions`, las
-- propaga a los roles del sistema (owner/admin/manager) de todos los negocios
-- existentes, y actualiza el seeder fn_seed_business_rbac_defaults para que
-- futuros negocios las reciban automaticamente.
--
-- Idempotente.

-- ============================================================================
-- 1. Catalogo: insertar los nuevos codigos (idempotente via ON CONFLICT).
-- ============================================================================

insert into public.permissions (code, name, module, description) values
  ('compras.acceso', 'Acceso a compras', 'inventory',
   'Abre el modulo de compras y permite consultar ordenes y proveedores.'),
  ('inventario.transferencias.crear', 'Crear transferencias de stock', 'inventory',
   'Permite enviar stock desde el almacen principal hacia otras bodegas.'),
  ('inventario.transferencias.recibir', 'Recibir transferencias de stock', 'inventory',
   'Permite confirmar la recepcion de transferencias en la bodega destino.')
on conflict (code) do update
  set name = excluded.name,
      module = excluded.module,
      description = excluded.description;

-- ============================================================================
-- 2. Backfill: anexar los nuevos permisos a roles del sistema (owner/admin/
--    manager) en TODOS los negocios existentes. Idempotente via ON CONFLICT.
--    No toca roles personalizados ni roles operativos (cashier/waiter/cook/
--    delivery) que por diseno no acceden a inventario/compras.
-- ============================================================================

insert into public.role_permissions (role_id, permission_id, allow)
select r.id, p.id, true
from public.roles r
cross join public.permissions p
where r.is_system = true
  and lower(r.name) in ('owner', 'admin', 'manager')
  and p.code in (
    'compras.acceso',
    'inventario.transferencias.crear',
    'inventario.transferencias.recibir'
  )
on conflict (role_id, permission_id) do nothing;

-- ============================================================================
-- 3. Seeder: redefine fn_seed_business_rbac_defaults para que negocios nuevos
--    reciban automaticamente los tres nuevos permisos como parte del seed
--    inicial. El cuerpo replica el de la migracion 20260308_0022 con las tres
--    filas adicionales para owner / admin / manager.
-- ============================================================================

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
      ('owner','inventario.transferencias.crear'),
      ('owner','inventario.transferencias.recibir'),
      ('owner','compras.acceso'),
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
      ('admin','inventario.transferencias.crear'),
      ('admin','inventario.transferencias.recibir'),
      ('admin','compras.acceso'),
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
      ('manager','inventario.transferencias.crear'),
      ('manager','inventario.transferencias.recibir'),
      ('manager','compras.acceso'),
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
