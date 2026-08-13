-- Empleados ACTIVOS que perderán funciones al desplegar los gates nuevos.
-- Cada fila = alguien con una denegación explícita (allow=false) sobre un
-- permiso que hasta ahora se ignoraba y ahora sí se respeta.
-- Reemplaza TU_BUSINESS_ID. `employees` usa `status`, no `is_active`.
select e.first_name,
       e.last_name,
       e.status,
       p.code,
       o.allow
from public.employees e
join public.user_permission_overrides o on o.employee_id = e.id
join public.permissions p on p.id = o.permission_id
where e.business_id = 'TU_BUSINESS_ID'::uuid
  and e.status = 'active'
  and o.allow = false
  and p.code in (
    'settings.usuarios.crear','settings.usuarios.editar','settings.usuarios.desactivar',
    'compras.ordenes.crear','compras.ordenes.recibir','compras.proveedores.crear_editar',
    'inventario.ajustes.crear','inventario.productos.crear_editar',
    'inventario.transferencias.crear','inventario.transferencias.recibir',
    'productos.crear','productos.editar','productos.eliminar',
    'categorias.crear','categorias.editar','categorias.eliminar',
    'contabilidad.asientos.crear','contabilidad.asientos.anular',
    'contabilidad.catalogo.gestionar','contabilidad.periodos.cerrar','contabilidad.reportes',
    'creditos.abonar','clientes.crear_editar','clientes.asignar_a_mesa',
    'ventas_rapida.crear_orden','ventas_rapida.cobrar_inmediato'
  )
order by e.first_name, e.last_name, p.code;
