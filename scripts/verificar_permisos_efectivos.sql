-- Qué permisos NUEVOS le faltan a cada empleado activo con acceso al sistema.
-- Usa la misma función que la app (fn_user_effective_permissions), así que
-- refleja exactamente lo que verá el POS tras desplegar los gates.
-- Reemplaza TU_BUSINESS_ID.
with nuevos(code) as (values
  ('settings.usuarios.crear'),('settings.usuarios.editar'),
  ('settings.usuarios.desactivar'),
  ('compras.ordenes.crear'),('compras.ordenes.recibir'),
  ('compras.proveedores.crear_editar'),
  ('inventario.ajustes.crear'),('inventario.productos.crear_editar'),
  ('inventario.transferencias.crear'),('inventario.transferencias.recibir'),
  ('productos.crear'),('productos.editar'),('productos.eliminar'),
  ('categorias.crear'),('categorias.editar'),('categorias.eliminar'),
  ('contabilidad.asientos.crear'),('contabilidad.asientos.anular'),
  ('contabilidad.catalogo.gestionar'),('contabilidad.periodos.cerrar'),
  ('contabilidad.reportes'),
  ('creditos.abonar'),('clientes.crear_editar'),('clientes.asignar_a_mesa'),
  ('ventas_rapida.crear_orden'),('ventas_rapida.cobrar_inmediato')
),
emp as (
  select e.id, e.first_name, e.last_name, e.user_id, ub.role
  from public.employees e
  join public.user_businesses ub
    on ub.user_id = e.user_id and ub.business_id = e.business_id
  where e.business_id = 'TU_BUSINESS_ID'::uuid
    and e.status = 'active'
    and e.user_id is not null
)
select emp.first_name,
       emp.last_name,
       emp.role,
       count(*) filter (where fp.code is null or fp.allowed is not true)
         as permisos_que_le_faltan,
       string_agg(n.code, ', ' order by n.code)
         filter (where fp.code is null or fp.allowed is not true)
         as detalle
from emp
cross join nuevos n
left join lateral public.fn_user_effective_permissions(
           emp.user_id, 'TU_BUSINESS_ID'::uuid) fp
       on fp.code = n.code
-- owner/admin tienen wildcard en la app; no hace falta revisarlos
where emp.role not in ('owner','admin')
group by emp.first_name, emp.last_name, emp.role
having count(*) filter (where fp.code is null or fp.allowed is not true) > 0
order by 4 desc, 1;
