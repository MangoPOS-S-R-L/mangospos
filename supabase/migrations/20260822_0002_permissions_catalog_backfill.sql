-- =============================================================================
-- 20260822_0002_permissions_catalog_backfill.sql
--
-- Fix: permisos que se marcan, "guardan bien" y al reabrir la pantalla
-- aparecen apagados. Reportado con los tres de Créditos (CxC / CxP).
--
-- CAUSA:
--   `fn_save_user_access_profile` inserta los overrides así:
--
--       insert into public.user_permission_overrides (...)
--       select ... from allow_extra a
--       join public.permissions p on p.code = a.code   -- <== acá
--
--   El join descarta EN SILENCIO cualquier código que no exista como fila
--   en `public.permissions`. No hay error: el RPC devuelve void, la UI
--   cierra el diálogo y muestra "guardado". Al reabrir, la lectura
--   (`fn_get_user_access_profile` → `fn_user_effective_permissions`) sale
--   del mismo catálogo, así que el código nunca vuelve → checkbox apagado.
--
--   Es la misma clase de bug que arregló `20260515_0002` en mayo. Desde
--   entonces se agregaron módulos nuevos (Créditos, Conteo físico,
--   Producción, aprobación de transferencias, compra a crédito) al
--   catálogo Dart `lib/core/security/access_control_catalog.dart` sin
--   sembrar sus códigos en la tabla. Son 13 códigos huérfanos.
--
-- ENTREGA:
--   Backfill de los 13 códigos faltantes, con el mismo label/módulo/
--   descripción que muestra la UI. `module` usa los mismos valores que el
--   `categoryId` del catálogo Dart (restaurant / finance / inventory / ...).
--
-- IDEMPOTENTE: `on conflict (code) do nothing`.
--
-- VERIFICADO EN PROD 2026-08-22: de los 13, la BD viva ya tenía 9 (los de
--   Conteo físico, Producción y `inventario.transferencias.aprobar`, que
--   entraron por fuera de las migraciones del repo — divergencia conocida).
--   Faltaban SOLO los 4 de crédito: `creditos.acceso`, `creditos.vender`,
--   `creditos.abonar` y `compras.ordenes.credito`. Los otros 9 quedan como
--   no-op y dejan el repo alineado para instancias nuevas.
--
-- SIN RIESGO DE PISAR NADA: solo INSERT en el catálogo. No toca funciones,
--   no toca overrides existentes, no toca RLS.
-- =============================================================================

begin;

insert into public.permissions (code, name, module, description) values
  -- Créditos (CxC / CxP) — el caso reportado.
  ('creditos.acceso', 'Ver créditos (CxC / CxP)', 'finance',
   'Acceso a la sección de Créditos: cuentas por cobrar y por pagar.'),
  ('creditos.vender', 'Vender a crédito', 'finance',
   'Habilita el método de pago Crédito en el cobro (requiere cliente con crédito habilitado).'),
  ('creditos.abonar', 'Registrar abonos de crédito', 'finance',
   'Registra abonos a cuentas por cobrar y pagos a cuentas por pagar.'),

  -- Compras a crédito (genera cuenta por pagar).
  ('compras.ordenes.credito', 'Comprar a crédito', 'inventory',
   'Permite registrar una compra a crédito, que genera una cuenta por pagar. Sin este permiso toda compra se registra al contado.'),

  -- Transferencias con flujo de aprobación.
  ('inventario.transferencias.aprobar', 'Aprobar transferencias de stock', 'inventory',
   'Permite aprobar transferencias pendientes cuando el negocio tiene el flujo de aprobación activo.'),

  -- Conteo físico.
  ('inventario.conteo.acceso', 'Acceso a conteo físico', 'inventory',
   'Abre el módulo de conteo físico y ve las sesiones.'),
  ('inventario.conteo.crear', 'Crear sesiones de conteo físico', 'inventory',
   'Inicia nuevas sesiones de conteo, congela el snapshot y registra cantidades contadas.'),
  ('inventario.conteo.completar', 'Completar conteo físico', 'inventory',
   'Aplica los ajustes resultantes del conteo. Genera movimientos en el kardex y modifica el stock.'),
  ('inventario.conteo.anular', 'Anular conteo físico', 'inventory',
   'Cancela una sesión de conteo en draft o in_progress sin aplicar ajustes.'),

  -- Producción.
  ('produccion.acceso', 'Acceso a producción', 'inventory',
   'Abre el módulo de producción y ve las órdenes existentes.'),
  ('produccion.crear', 'Crear órdenes de producción', 'inventory',
   'Crea nuevas órdenes para transformar materias primas en productos terminados.'),
  ('produccion.completar', 'Completar órdenes de producción', 'inventory',
   'Marca una orden como completada. Genera movimientos en el kardex y recalcula el costo del producto terminado.'),
  ('produccion.anular', 'Anular órdenes de producción', 'inventory',
   'Cancela órdenes en draft o in_progress sin afectar stock.')
on conflict (code) do nothing;

commit;

-- =============================================================================
-- VERIFICACIÓN (correr después; debe devolver 13 filas)
--
--   select code, name, module
--   from public.permissions
--   where code in (
--     'creditos.acceso','creditos.vender','creditos.abonar',
--     'compras.ordenes.credito','inventario.transferencias.aprobar',
--     'inventario.conteo.acceso','inventario.conteo.crear',
--     'inventario.conteo.completar','inventario.conteo.anular',
--     'produccion.acceso','produccion.crear','produccion.completar',
--     'produccion.anular'
--   )
--   order by module, code;
--
-- OJO: los permisos que ya se habían "guardado" antes de esta migration se
-- perdieron (nunca llegaron a existir como override). Hay que volver a
-- marcarlos en la pantalla de Usuarios una vez aplicada.
-- =============================================================================
