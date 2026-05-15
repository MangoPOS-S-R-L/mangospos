// Destinos compartidos entre `MainShell` (desktop/tablet, topbar horizontal)
// y `MobileShell` (móvil, drawer + bottom nav). Cambiar el menú principal
// implica solo tocar este archivo.

import 'package:flutter/material.dart';

import '../../app/router/routes.dart';

class ShellDestination {
  final String label;
  final String route;
  final String? svgAsset;
  final IconData? materialIcon;
  final String? permissionCode;
  final List<String>? inactivePaths;

  const ShellDestination({
    required this.label,
    required this.route,
    this.svgAsset,
    this.materialIcon,
    this.permissionCode,
    this.inactivePaths,
  }) : assert(
          svgAsset != null || materialIcon != null,
          'Debe proporcionarse svgAsset o materialIcon',
        );
}

/// Orden y configuración de los destinos principales del shell.
/// Compartido por el topbar (desktop) y el drawer (móvil).
const List<ShellDestination> kPrimaryDestinations = [
  ShellDestination(
    label: 'Dashboard',
    route: AppRoutes.dashboard,
    svgAsset: 'assets/icons/dashboard.svg',
    permissionCode: 'dashboard.acceso',
  ),
  ShellDestination(
    label: 'Ventas',
    route: AppRoutes.sales,
    svgAsset: 'assets/icons/ventas_principal.svg',
    permissionCode: 'ventas.mesas.acceso',
  ),
  ShellDestination(
    label: 'Caja',
    route: AppRoutes.cashier,
    svgAsset: 'assets/icons/caja_principal.svg',
    permissionCode: 'caja.apertura',
  ),
  ShellDestination(
    label: 'Cocina',
    route: AppRoutes.kitchen,
    svgAsset: 'assets/icons/cocina_principal.svg',
    permissionCode: 'kds.acceso',
  ),
  ShellDestination(
    label: 'Productos',
    route: AppRoutes.products,
    svgAsset: 'assets/icons/productos_principal.svg',
    permissionCode: 'productos.acceso',
  ),
  ShellDestination(
    label: 'Reportes',
    route: AppRoutes.reports,
    svgAsset: 'assets/icons/reportes_principal.svg',
    permissionCode: 'reportes.ventas',
  ),
  ShellDestination(
    label: 'Más Opciones',
    route: AppRoutes.settings,
    svgAsset: 'assets/icons/masajustes.svg',
    permissionCode: 'settings.usuarios.acceso',
    inactivePaths: [
      AppRoutes.purchasesList,
      AppRoutes.inventoryHome,
    ],
  ),
];

/// Decide si un destino está "activo" para una ruta actual dada.
bool isDestinationActive(ShellDestination d, String currentLocation) {
  final excluded =
      d.inactivePaths?.any((p) => currentLocation.startsWith(p)) ?? false;
  if (excluded) return false;
  if (currentLocation == d.route) return true;
  if (d.route != '/' && currentLocation.startsWith(d.route)) return true;
  if (d.route == AppRoutes.settings &&
      currentLocation.startsWith(AppRoutes.menu)) {
    return true;
  }
  return false;
}
