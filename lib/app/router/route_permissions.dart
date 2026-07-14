// Mapeo ruta → permiso requerido. Lo usa el redirect global del go_router
// para bloquear navegación directa a pantallas que el rol del usuario no
// debería ver. Hasta esta capa, los permisos solo apagaban botones en el
// UI: cualquier autenticado podía escribir la URL y entrar igual.
//
// Reglas:
//   - El match es por *prefijo más largo* sobre el path. Una ruta sin
//     entry en el mapa NO requiere permiso adicional (solo autenticación).
//   - Los permisos vienen del catálogo en
//     `lib/core/security/access_control_catalog.dart`. Si agregás una
//     ruta nueva y querés gatearla, agregá la entry acá.
//   - Si el usuario no tiene el permiso, el router redirige a su
//     "homeRoute" según rol (definido en `session_controller.homeRoute`).

const Map<String, String> routePermissions = <String, String>{
  // --- Dashboard / inicio ---
  '/dashboard': 'dashboard.acceso',

  // --- Ventas (salón + venta rápida) ---
  '/sales': 'ventas.mesas.acceso',
  '/ventas': 'ventas.mesas.acceso',

  // --- Caja: el sub-flujo de arqueos requiere ver arqueos ---
  '/cashier/closures': 'caja.arqueo_ver',
  '/cashier/history': 'caja.movimientos_ver',
  '/cashier/income-expense': 'caja.movimientos_ver',

  // --- KDS / cocina ---
  '/kitchen': 'kds.acceso',
  '/cocina': 'kds.acceso',

  // --- Reservas (add-on; el módulo además se gatea por business_modules) ---
  '/reservations': 'reservas.acceso',

  // --- Clientes ---
  '/customers': 'clientes.ver',
  '/clientes': 'clientes.ver',

  // --- Productos / menú ---
  '/products': 'productos.acceso',
  '/productos': 'productos.acceso',
  '/menu': 'productos.acceso',

  // --- Reportes (granular por sub-reporte) ---
  '/reports/sales': 'reportes.ventas',
  '/reports/sales-by-waiter': 'reportes.ventas',
  '/reports/finances': 'reportes.caja',
  '/reports/inventory': 'inventario.acceso',
  '/reports/purchases': 'compras.acceso',
  '/reports/taxes': 'reportes.fiscales',
  '/reports/fiscal': 'reportes.fiscales',
  '/reports': 'reportes.ventas',
  '/reportes': 'reportes.ventas',

  // --- Inventario ---
  '/inventory': 'inventario.acceso',
  '/inventory/production': 'produccion.acceso',
  '/inventory/physical-count': 'inventario.conteo.acceso',
  '/inventory/reorder': 'inventario.acceso',
  '/settings/inventory-kardex': 'inventario.acceso',
  '/settings/inventory-requirements': 'inventario.acceso',
  '/settings/inventory-outflow': 'inventario.acceso',
  '/settings/inventory-reconciliation': 'inventario.acceso',
  '/settings/inventory-low-stock': 'inventario.acceso',
  '/settings/inventory-lots': 'inventario.acceso',
  '/settings/inventory-valuation': 'inventario.acceso',
  '/settings/inventory-rotation': 'inventario.acceso',

  // --- Compras ---
  '/settings/purchases': 'compras.acceso',

  // --- Créditos (CxC / CxP) ---
  '/credits': 'creditos.acceso',

  // --- Promos / descuentos ---
  '/settings/promos': 'settings.descuentos_propinas.gestionar',

  // --- Settings sensibles ---
  '/settings/users': 'settings.usuarios.acceso',
  '/settings/waiters': 'settings.usuarios.acceso',
  '/settings/roles': 'settings.roles.acceso',
  '/settings/printing': 'settings.impresoras.gestionar',
  '/settings/zones-tables': 'settings.zonas_mesas.gestionar',
  '/settings/taxes': 'settings.impuestos_fiscal.gestionar',
  '/settings/fiscal-receipts': 'settings.impuestos_fiscal.gestionar',
  '/settings/payment-methods': 'settings.metodos_pago.gestionar',

  // NOTA: routes /settings/business-profile, /settings/branches,
  // /settings/cash-registers, /settings/cash-close-mode,
  // /settings/business-features, /settings/currencies, /settings/regional,
  // /settings/plan no tienen permiso específico en el catálogo. Quedan
  // accesibles a cualquier autenticado en Fase 1; si necesitamos
  // restringirlas, agregamos un permiso al catálogo y mapeamos acá.
};

/// Devuelve el permiso requerido para `path`, o `null` si la ruta no
/// está gateada (acceso libre a cualquier usuario autenticado).
///
/// Hace match por prefijo más largo: `/settings/printing/areas` matchea
/// `/settings/printing` aunque no esté listado explícitamente.
String? requiredPermissionForPath(String path) {
  String? best;
  var bestLen = 0;
  for (final entry in routePermissions.entries) {
    final prefix = entry.key;
    if (path == prefix || path.startsWith('$prefix/')) {
      if (prefix.length > bestLen) {
        bestLen = prefix.length;
        best = entry.value;
      }
    }
  }
  return best;
}
