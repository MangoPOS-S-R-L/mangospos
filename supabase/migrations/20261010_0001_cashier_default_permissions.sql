-- =============================================================================
-- 20261010_0001 — El rol Cajero trae por defecto el flujo de mesa
-- =============================================================================
--
-- Las migraciones de permisos (20260308_0022, 20260514_0003) le dieron al rol
-- `cashier` de cada negocio solo «ver total», Venta Rápida y acceso a mesas. La
-- app sí espera que el cajero trabaje una mesa (su preset en
-- access_control_catalog.dart) y valida `ventas.orden.agregar_item` al tocar un
-- producto: en TODOS los negocios el cajero tocaba el producto y no pasaba
-- nada (la pantalla de la mesa no mostraba el error). Verificado en prod el
-- 2026-10-10: ningún rol cajero tenía agregar/editar/enviar a cocina.
--
-- Decisión del dueño (2026-10-10): flujo de mesa + operación. NO incluye
-- anular, aplicar descuento, reabrir, créditos ni movimientos de caja: esos los
-- da el dueño por usuario o por rol si quiere.
--
-- Solo agrega:
--   1. Los códigos que falten en public.permissions (no pisa nombres).
--   2. En el rol `cashier` de cada negocio, los permisos que no tiene. Si un
--      dueño quitó uno a propósito (fila con allow = false), NO se toca.
--   3. Los negocios nuevos: un trigger AFTER INSERT en public.roles le da lo
--      mismo al rol `cashier` recién creado. No reemplaza
--      fn_seed_business_rbac_defaults (la BD viva puede diferir del repo); su
--      propio insert de role_permissions usa ON CONFLICT DO NOTHING.
-- =============================================================================

begin;

create or replace function public.fn_cashier_default_permission_codes()
returns text[]
language sql
immutable
as $$
  select array[
    -- Flujo de mesa
    'ventas.mesas.abrir',
    'ventas.orden.agregar_item',
    'ventas.orden.editar_item',
    'ventas.orden.enviar_cocina',
    'ventas_rapida.enviar_cocina',
    'ventas.mesas.marcar_pagando',
    -- Operación
    'kds.acceso',
    'kds.ver_comandas',
    'kds.cambiar_estado',
    'kds.reimprimir_comanda',
    'ventas.cuenta.split_equiv',
    'ventas.cuenta.split_manual',
    'ventas.mesas.mover_unir',
    'ventas.mesas.liberar',
    'ventas.mesas.reasignar_mesero',
    'ventas.ordenes.ver',
    'ventas.orden.agotar_producto'
  ]::text[];
$$;

-- 1. Catálogo: solo los códigos que falten (nombres del catálogo de la app).
insert into public.permissions (code, name, module, description)
values
  ('ventas.mesas.abrir', 'Abrir mesas', 'restaurant', 'Crea o retoma una cuenta en mesa.'),
  ('ventas.orden.agregar_item', 'Agregar productos a la orden', 'restaurant',
   'Permite agregar productos, combos y recetas a la cuenta.'),
  ('ventas.orden.editar_item', 'Editar lineas de orden', 'restaurant',
   'Permite cambiar cantidad, notas y takeout de una linea.'),
  ('ventas.orden.enviar_cocina', 'Enviar Pedido', 'kds',
   'Confirma items pendientes y los envia a cocina/KDS.'),
  ('ventas_rapida.enviar_cocina', 'Enviar venta rapida a cocina', 'kds',
   'Envia ventas rapidas pendientes al KDS.'),
  ('ventas.mesas.marcar_pagando', 'Marcar mesa pagando', 'operations',
   'Marca una mesa en proceso de cobro.'),
  ('kds.acceso', 'Acceso a cocina', 'kds', 'Abre la pantalla de cocina.'),
  ('kds.ver_comandas', 'Ver comandas', 'kds', 'Consulta comandas activas en cocina.'),
  ('kds.cambiar_estado', 'Cambiar estado de comanda', 'kds',
   'Permite pasar items a preparando, listo o servido.'),
  ('kds.reimprimir_comanda', 'Reimprimir comanda', 'kds', 'Reimprime comandas de cocina.'),
  ('ventas.cuenta.split_equiv', 'Dividir cuenta equitativa', 'operations',
   'Reparte la cuenta automaticamente entre comensales.'),
  ('ventas.cuenta.split_manual', 'Dividir cuenta manual', 'operations',
   'Mueve lineas entre subcuentas manualmente.'),
  ('ventas.mesas.mover_unir', 'Mover o unir mesas', 'operations',
   'Permite mover una cuenta a otra mesa o fusionar mesas.'),
  ('ventas.mesas.liberar', 'Liberar mesa', 'operations',
   'Libera una mesa despues de cerrar la cuenta.'),
  ('ventas.mesas.reasignar_mesero', 'Asignar una mesa a otro mesero', 'operations',
   'Cambia a que mesero pertenece una mesa ya abierta.'),
  ('ventas.ordenes.ver', 'Pedidos de canales externos', 'operations',
   'Recibe el aviso de los pedidos que entran por canales externos.'),
  ('ventas.orden.agotar_producto', 'Agotar producto (86) desde la orden', 'operations',
   'Marca un producto como agotado desde la linea de la orden.')
on conflict (code) do nothing;

-- 2. Negocios existentes: lo que le falte al rol cashier. Una fila existente
--    (aunque sea allow = false, quitada a propósito) no se toca.
insert into public.role_permissions (role_id, permission_id, allow)
select r.id, p.id, true
from public.roles r
join public.permissions p
  on p.code = any (public.fn_cashier_default_permission_codes())
where r.name = 'cashier'
on conflict (role_id, permission_id) do nothing;

-- 3. Negocios nuevos: el rol cashier nace con lo mismo.
create or replace function public.fn_roles_cashier_defaults()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.name = 'cashier' then
    insert into public.role_permissions (role_id, permission_id, allow)
    select new.id, p.id, true
    from public.permissions p
    where p.code = any (public.fn_cashier_default_permission_codes())
    on conflict (role_id, permission_id) do nothing;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_roles_cashier_defaults on public.roles;
create trigger trg_roles_cashier_defaults
  after insert on public.roles
  for each row execute function public.fn_roles_cashier_defaults();

revoke all on function public.fn_roles_cashier_defaults() from public, anon, authenticated;
revoke all on function public.fn_cashier_default_permission_codes() from public, anon;

commit;
