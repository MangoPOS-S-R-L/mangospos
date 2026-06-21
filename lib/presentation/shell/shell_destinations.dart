// Destinos compartidos entre `MainShell` (desktop/tablet, topbar horizontal)
// y `MobileShell` (móvil, drawer + bottom nav). Cambiar el menú principal
// implica solo tocar este archivo.

import 'package:flutter/material.dart';

import '../../app/router/routes.dart';
import '../../data/repositories/pos_settings_repository.dart';

class ShellDestination {
  final String label;
  final String route;
  final String? svgAsset;
  final IconData? materialIcon;
  final String? permissionCode;
  final List<String>? inactivePaths;

  /// Feature flag de negocio que debe estar prendido para mostrar el destino.
  /// `null` = siempre visible (solo gateado por permiso de rol). Se evalúa con
  /// [isDestinationFeatureEnabled]. Ej.: 'kitchen' oculta Cocina/KDS en retail.
  final String? requiresFeature;

  /// Add-on de pago que la PLATAFORMA debe haber activado para el negocio
  /// (fila en `business_modules`). `null` = no es add-on. Se evalúa con
  /// [isDestinationModuleEnabled] contra el set de módulos activos. A
  /// diferencia de [requiresFeature] (que el dueño controla en Ajustes), esto
  /// solo lo activa MangoPOS desde el panel administrativo. Ej.: 'reservations'.
  final String? requiresModule;

  const ShellDestination({
    required this.label,
    required this.route,
    this.svgAsset,
    this.materialIcon,
    this.permissionCode,
    this.inactivePaths,
    this.requiresFeature,
    this.requiresModule,
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
    requiresFeature: 'kitchen',
  ),
  // Add-on: solo visible si la plataforma activó 'reservations' para el
  // negocio (business_modules) Y el rol tiene 'reservas.acceso'.
  ShellDestination(
    label: 'Reservas',
    route: AppRoutes.reservations,
    materialIcon: Icons.event_seat,
    permissionCode: 'reservas.acceso',
    requiresModule: 'reservations',
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

/// ¿El destino está habilitado según los feature flags del negocio?
/// Destinos sin `requiresFeature` siempre pasan. Mientras la config carga,
/// [features] son los defaults (todo prendido) — comportamiento histórico.
bool isDestinationFeatureEnabled(
    ShellDestination d, BusinessFeatures features) {
  switch (d.requiresFeature) {
    case 'kitchen':
      return features.kitchenEnabled;
    default:
      return true;
  }
}

/// ¿El destino está habilitado según los add-ons activados por la plataforma?
/// Destinos sin `requiresModule` siempre pasan. [enabledModules] es el set de
/// claves activas en `business_modules`; mientras carga es `{}` → el add-on
/// queda OCULTO (un módulo de pago no se muestra hasta confirmar activación).
bool isDestinationModuleEnabled(
    ShellDestination d, Set<String> enabledModules) {
  final required = d.requiresModule;
  if (required == null) return true;
  return enabledModules.contains(required);
}

/// Decide si un destino está "activo" para una ruta actual dada.
bool isDestinationActive(ShellDestination d, String currentLocation) {
  final excluded =
      d.inactivePaths?.any((p) => currentLocation.startsWith(p)) ?? false;
  if (excluded) return false;
  if (currentLocation == d.route) return true;
  if (d.route != '/' && currentLocation.startsWith(d.route)) return true;
  // Ventas vive en DOS rutas: '/sales' (+ subrutas) y '/ventas' (salesReact),
  // que es el shell por defecto al que '/sales' redirige. Sin esto, al entrar
  // a Ventas la ubicación queda en '/ventas' y el item no se marcaba activo.
  if (d.route == AppRoutes.sales &&
      currentLocation.startsWith(AppRoutes.salesReact)) {
    return true;
  }
  if (d.route == AppRoutes.settings &&
      currentLocation.startsWith(AppRoutes.menu)) {
    return true;
  }
  return false;
}
