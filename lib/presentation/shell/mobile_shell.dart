// Shell móvil (<600dp): AppBar compacto + Drawer con menú completo +
// Bottom navigation bar de 4 destinos rápidos.
//
// Se activa automáticamente desde `MainShell` cuando el ancho es compacto.
// Reutiliza `kPrimaryDestinations` para mantener un único catálogo de menú.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';

import '../../app/router/routes.dart';
import '../../app/theme/mango_colors.dart';
import '../../core/business/business_features_provider.dart';
import '../../core/offline/offline_queue_status_provider.dart';
import '../../core/utils/app_toast.dart';
import '../../data/repositories/pos_settings_repository.dart';
import 'offline_logout_guard.dart';
import '../../services/session/session_controller.dart';
import '../inventory/viewmodel/expiring_lots_badge_provider.dart';
import '../inventory/viewmodel/low_stock_badge_provider.dart';
import '../sales/viewmodel/sales_viewmodel.dart';
import 'shell_destinations.dart';
import 'update_available_banner.dart';

class MobileShell extends ConsumerStatefulWidget {
  final Widget child;
  const MobileShell({super.key, required this.child});

  @override
  ConsumerState<MobileShell> createState() => _MobileShellState();
}

class _MobileShellState extends ConsumerState<MobileShell> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  static const List<_BottomDest> _bottomDestinations = [
    _BottomDest(
      label: 'Inicio',
      route: AppRoutes.dashboard,
      icon: Icons.home_rounded,
      iconOutlined: Icons.home_outlined,
      permission: 'dashboard.acceso',
    ),
    _BottomDest(
      label: 'Inventario',
      route: AppRoutes.inventoryHome,
      icon: Icons.inventory_2_rounded,
      iconOutlined: Icons.inventory_2_outlined,
      permission: 'inventario.acceso',
    ),
    _BottomDest(
      label: 'Reportes',
      route: AppRoutes.reports,
      icon: Icons.bar_chart_rounded,
      iconOutlined: Icons.bar_chart_outlined,
      permission: 'reportes.ventas',
    ),
    _BottomDest(
      label: 'Más',
      route: '__drawer__',
      icon: Icons.menu_rounded,
      iconOutlined: Icons.menu_outlined,
    ),
  ];

  int _activeIndex(String loc) {
    for (var i = 0; i < _bottomDestinations.length; i++) {
      final d = _bottomDestinations[i];
      if (d.route == '__drawer__') continue;
      if (loc == d.route || loc.startsWith('${d.route}/')) return i;
    }
    return -1;
  }

  @override
  Widget build(BuildContext context) {
    final loc = GoRouterState.of(context).uri.toString();
    final activeIdx = _activeIndex(loc);

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: const Color(0xFFFBFAF9),
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: MangoColors.darkGray,
        elevation: 0,
        scrolledUnderElevation: 0,
        shape: const Border(
          bottom: BorderSide(color: Color(0xFFE5E7EB)),
        ),
        leading: IconButton(
          icon: const Icon(Icons.menu_rounded),
          onPressed: () => _scaffoldKey.currentState?.openDrawer(),
          tooltip: 'Abrir menú',
        ),
        title: Image.asset(
          'assets/images/Logo Completo.png',
          height: 28,
          fit: BoxFit.contain,
        ),
        centerTitle: true,
        actions: const [
          _AppBarOfflineQueueBadge(),
          _AppBarExpiringLotsBadge(),
          SizedBox(width: 4),
          _AppBarLowStockBadge(),
          SizedBox(width: 8),
        ],
      ),
      drawer: _MobileDrawer(currentLocation: loc),
      body: Column(
        children: [
          // Banner de actualización (solo web, solo si hay deploy nuevo).
          const UpdateAvailableBanner(),
          Expanded(child: widget.child),
        ],
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(top: BorderSide(color: Color(0xFFE5E7EB))),
          ),
          child: BottomNavigationBar(
            type: BottomNavigationBarType.fixed,
            backgroundColor: Colors.white,
            elevation: 0,
            currentIndex: activeIdx == -1 ? 0 : activeIdx,
            selectedItemColor: MangoColors.primaryOrange,
            unselectedItemColor: const Color(0xFF6B7280),
            selectedFontSize: 11,
            unselectedFontSize: 11,
            showUnselectedLabels: true,
            onTap: (i) {
              final d = _bottomDestinations[i];
              if (d.route == '__drawer__') {
                _scaffoldKey.currentState?.openDrawer();
                return;
              }
              if (d.permission != null) {
                final ok = ref
                    .read(sessionProvider.notifier)
                    .hasPermission(d.permission!);
                if (!ok) {
                  AppToast.info(context, 'No tienes permiso para acceder.');
                  return;
                }
              }
              if (loc != d.route) context.go(d.route);
            },
            items: _bottomDestinations
                .map((d) => BottomNavigationBarItem(
                      icon: Icon(d.iconOutlined),
                      activeIcon: Icon(d.icon),
                      label: d.label,
                    ))
                .toList(growable: false),
          ),
        ),
      ),
    );
  }
}

class _BottomDest {
  final String label;
  final String route;
  final IconData icon;
  final IconData iconOutlined;
  final String? permission;
  const _BottomDest({
    required this.label,
    required this.route,
    required this.icon,
    required this.iconOutlined,
    this.permission,
  });
}

// =============================================================================
// Drawer
// =============================================================================

class _MobileDrawer extends ConsumerWidget {
  final String currentLocation;
  const _MobileDrawer({required this.currentLocation});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    final ctrl = ref.read(sessionProvider.notifier);
    final role = session.activeRole;
    final roleLabel = role?.label ?? 'Sin rol';
    final businessName =
        session.activeBusinessName?.trim().isNotEmpty == true
            ? session.activeBusinessName!.trim()
            : 'Negocio';
    final isAdminLevel = role == PosRole.administrador;
    final canOpenSettings = ctrl.hasPermission('settings.usuarios.acceso');
    final canSwitchBranch = session.availableBusinesses.length > 1;

    return Drawer(
      backgroundColor: Colors.white,
      child: SafeArea(
        child: Column(
          children: [
            _DrawerHeader(
              userName: session.userName ?? 'Usuario',
              businessName: businessName,
              roleLabel: roleLabel,
            ),
            Expanded(
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  const _DrawerSectionTitle('Módulos'),
                  // Filtramos por:
                  //   1) Permiso del rol del empleado.
                  //   2) Config del business (`header_destinations_disabled`)
                  //      — el owner puede ocultar destinos a todos los
                  //      empleados sin tocar permisos por rol.
                  ...() {
                    final disabledAsync = ref.watch(
                      headerDestinationsDisabledProvider(
                        session.activeBusinessId ?? '',
                      ),
                    );
                    final disabledRoutes =
                        disabledAsync.valueOrNull ?? const <String>[];
                    final features = ref.watchBusinessFeatures();
                    return kPrimaryDestinations.where((d) {
                      final code = d.permissionCode;
                      final hasPerm =
                          code == null || ctrl.hasPermission(code);
                      final hidden = disabledRoutes.contains(d.route);
                      final featureOk =
                          isDestinationFeatureEnabled(d, features);
                      return hasPerm && !hidden && featureOk;
                    }).map(
                      (d) => _DrawerNavTile(
                        destination: d,
                        currentLocation: currentLocation,
                        onTap: () {
                          Navigator.of(context).pop();
                          if (currentLocation != d.route) {
                            context.go(d.route);
                          }
                        },
                      ),
                    );
                  }(),
                  const Divider(height: 24),
                  const _DrawerSectionTitle('Cuenta'),
                  if (canSwitchBranch)
                    _DrawerActionTile(
                      icon: Icons.swap_horiz_rounded,
                      label: 'Cambiar sucursal',
                      iconColor: const Color(0xFF059669),
                      bg: const Color(0xFFEAFBF3),
                      onTap: () async {
                        Navigator.of(context).pop();
                        await Future<void>.delayed(
                          const Duration(milliseconds: 80),
                        );
                        if (!context.mounted) return;
                        final selected =
                            await _showBranchPicker(context, session, ctrl);
                        if (selected != null && context.mounted) {
                          context.go(AppRoutes.dashboard);
                        }
                      },
                    ),
                  if (isAdminLevel)
                    _DrawerActionTile(
                      icon: Icons.apartment_rounded,
                      label: 'Gestionar sucursales',
                      iconColor: MangoColors.primaryOrange,
                      bg: const Color(0xFFFFF0D9),
                      onTap: () {
                        Navigator.of(context).pop();
                        context.go(AppRoutes.settingsBranches);
                      },
                    ),
                  if (isAdminLevel)
                    _DrawerActionTile(
                      icon: Icons.rocket_launch_rounded,
                      label: 'Mejorar plan',
                      iconColor: MangoColors.primaryOrange,
                      bg: const Color(0xFFFFF0D9),
                      onTap: () {
                        Navigator.of(context).pop();
                        context.go(AppRoutes.settingsPlan);
                      },
                    ),
                  if (canOpenSettings)
                    _DrawerActionTile(
                      icon: Icons.settings_rounded,
                      label: 'Ajustes del sistema',
                      iconColor: const Color(0xFF2563EB),
                      bg: const Color(0xFFEAF0FF),
                      onTap: () {
                        Navigator.of(context).pop();
                        context.go(AppRoutes.settings);
                      },
                    ),
                  const Divider(height: 24),
                  _DrawerActionTile(
                    icon: Icons.logout_rounded,
                    label: 'Cerrar sesión',
                    iconColor: const Color(0xFFDC2626),
                    bg: const Color(0xFFFFE7E7),
                    textColor: const Color(0xFFDC2626),
                    onTap: () async {
                      final proceed = await confirmLogoutDiscardingOffline(
                          context, session.activeBusinessId);
                      if (!proceed || !context.mounted) return;
                      Navigator.of(context).pop();
                      await ctrl.signOut();
                      if (!context.mounted) return;
                      context.go(AppRoutes.login);
                    },
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                    child: Text(
                      'versión ${const String.fromEnvironment('APP_VERSION', defaultValue: '1.0.0')}',
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFF94A3B8),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DrawerHeader extends StatelessWidget {
  final String userName;
  final String businessName;
  final String roleLabel;
  const _DrawerHeader({
    required this.userName,
    required this.businessName,
    required this.roleLabel,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFFF97316), Color(0xFFFBAA16)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 22,
                backgroundColor: Colors.white.withValues(alpha: 0.18),
                child: const Icon(Icons.person, color: Colors.white),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Hola, $userName',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      roleLabel,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.9),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.storefront_rounded,
                  color: Colors.white,
                  size: 14,
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    businessName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DrawerSectionTitle extends StatelessWidget {
  final String text;
  const _DrawerSectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 6),
      child: Text(
        text.toUpperCase(),
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.6,
          color: Color(0xFF94A3B8),
        ),
      ),
    );
  }
}

class _DrawerNavTile extends ConsumerWidget {
  final ShellDestination destination;
  final String currentLocation;
  final VoidCallback onTap;
  const _DrawerNavTile({
    required this.destination,
    required this.currentLocation,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(sessionProvider);
    final hasAccess = destination.permissionCode == null ||
        ref
            .read(sessionProvider.notifier)
            .hasPermission(destination.permissionCode!);
    final active = isDestinationActive(destination, currentLocation);

    final accent = active
        ? MangoColors.primaryOrange
        : (hasAccess
            ? const Color(0xFF374151)
            : const Color(0xFF94A3B8));
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: hasAccess ? onTap : null,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          decoration: BoxDecoration(
            color: active
                ? const Color(0xFFFFF7ED)
                : Colors.transparent,
            border: Border(
              left: BorderSide(
                color: active ? MangoColors.primaryOrange : Colors.transparent,
                width: 3,
              ),
            ),
          ),
          child: Row(
            children: [
              if (destination.svgAsset != null)
                SvgPicture.asset(
                  destination.svgAsset!,
                  width: 22,
                  height: 22,
                  colorFilter: ColorFilter.mode(accent, BlendMode.srcIn),
                )
              else
                Icon(destination.materialIcon, size: 22, color: accent),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  destination.label,
                  style: TextStyle(
                    color: accent,
                    fontWeight:
                        active ? FontWeight.w800 : FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
              ),
              if (!hasAccess)
                const Icon(
                  Icons.lock_outline,
                  size: 14,
                  color: Color(0xFF94A3B8),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DrawerActionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color iconColor;
  final Color bg;
  final Color? textColor;
  final VoidCallback onTap;
  const _DrawerActionTile({
    required this.icon,
    required this.label,
    required this.iconColor,
    required this.bg,
    required this.onTap,
    this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, size: 18, color: iconColor),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    color: textColor ?? const Color(0xFF374151),
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: (textColor ?? const Color(0xFF9CA3AF))
                    .withValues(alpha: 0.8),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// AppBar badges (móvil)
// =============================================================================

class _AppBarLowStockBadge extends ConsumerWidget {
  const _AppBarLowStockBadge();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(lowStockBadgeCountProvider);
    final count = async.maybeWhen(data: (v) => v, orElse: () => 0);
    final hasAlerts = count > 0;
    return IconButton(
      tooltip: hasAlerts
          ? '$count alerta(s) de stock bajo'
          : 'Sin alertas activas',
      onPressed: () => context.go(AppRoutes.inventoryLowStock),
      icon: Stack(
        clipBehavior: Clip.none,
        children: [
          Icon(
            hasAlerts
                ? Icons.notifications_active_rounded
                : Icons.notifications_none,
            color: hasAlerts
                ? const Color(0xFFDC2626)
                : const Color(0xFF6B7280),
          ),
          if (hasAlerts)
            Positioned(
              top: -4,
              right: -4,
              child: Container(
                constraints:
                    const BoxConstraints(minWidth: 16, minHeight: 16),
                padding: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFFDC2626),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: Colors.white, width: 1.5),
                ),
                alignment: Alignment.center,
                child: Text(
                  count > 99 ? '99+' : '$count',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 9,
                    fontWeight: FontWeight.w800,
                    height: 1,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _AppBarOfflineQueueBadge extends ConsumerWidget {
  const _AppBarOfflineQueueBadge();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(offlineQueueStatusProvider);
    final count = status.pending;
    final dead = status.dead;
    final hasPending = count > 0;
    final hasDead = dead > 0;
    // Visible con pendientes O con dead-letter: si todo lo pendiente
    // murió, igual hay que avisar (en rojo). Rojo = requiere acción,
    // ámbar = solo espera conexión.
    if (!hasPending && !hasDead) return const SizedBox.shrink();
    final total = count + dead;
    final accent =
        hasDead ? const Color(0xFFB91C1C) : const Color(0xFFB45309);
    return IconButton(
      tooltip: hasDead
          ? '$dead sin resolver (requieren revisión)'
              '${hasPending ? ' · $count pendiente(s)' : ''}'
          : '$count operación(es) offline pendiente(s)',
      onPressed: () => ref
          .read(currentOrderProvider.notifier)
          .syncPendingOfflineActions(force: true),
      icon: Stack(
        clipBehavior: Clip.none,
        children: [
          Icon(
            hasDead ? Icons.error_outline_rounded : Icons.cloud_off_rounded,
            color: accent,
          ),
          Positioned(
            top: -4,
            right: -4,
            child: Container(
              constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
              padding: const EdgeInsets.symmetric(horizontal: 4),
              decoration: BoxDecoration(
                color: accent,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: Colors.white, width: 1.5),
              ),
              alignment: Alignment.center,
              child: Text(
                total > 99 ? '99+' : '$total',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 9,
                  fontWeight: FontWeight.w800,
                  height: 1,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AppBarExpiringLotsBadge extends ConsumerWidget {
  const _AppBarExpiringLotsBadge();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(expiringLotsBadgeCountProvider);
    final count = async.maybeWhen(data: (v) => v, orElse: () => 0);
    final hasAlerts = count > 0;
    return IconButton(
      tooltip: hasAlerts
          ? '$count lote(s) próximos a vencer'
          : 'Sin lotes próximos a vencer',
      onPressed: () => context.go(AppRoutes.inventoryLots),
      icon: Stack(
        clipBehavior: Clip.none,
        children: [
          Icon(
            hasAlerts
                ? Icons.event_busy_rounded
                : Icons.event_note_outlined,
            color: hasAlerts
                ? const Color(0xFFC2410C)
                : const Color(0xFF6B7280),
          ),
          if (hasAlerts)
            Positioned(
              top: -4,
              right: -4,
              child: Container(
                constraints:
                    const BoxConstraints(minWidth: 16, minHeight: 16),
                padding: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFFC2410C),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: Colors.white, width: 1.5),
                ),
                alignment: Alignment.center,
                child: Text(
                  count > 99 ? '99+' : '$count',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 9,
                    fontWeight: FontWeight.w800,
                    height: 1,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// =============================================================================
// Branch picker (reutilizado del MainShell pero local)
// =============================================================================

Future<SessionBusiness?> _showBranchPicker(
  BuildContext context,
  SessionState session,
  SessionController ctrl,
) async {
  return showModalBottomSheet<SessionBusiness>(
    context: context,
    backgroundColor: Colors.white,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFFF97316), Color(0xFFFBAA16)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Cambiar sucursal',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      'Cada sucursal trabaja con sus propios datos.',
                      style: TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final branch in session.availableBusinesses)
                      Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: branch.id == session.activeBusinessId
                                ? const Color(0xFFFED7AA)
                                : const Color(0xFFE5E7EB),
                          ),
                        ),
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor: branch.id == session.activeBusinessId
                                ? const Color(0xFFFFE8D6)
                                : const Color(0xFFF3F4F6),
                            child: Icon(
                              branch.id == session.activeBusinessId
                                  ? Icons.check_rounded
                                  : Icons.storefront_rounded,
                              color: branch.id == session.activeBusinessId
                                  ? MangoColors.primaryOrange
                                  : const Color(0xFF6B7280),
                            ),
                          ),
                          title: Text(
                            branch.name,
                            style:
                                const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          subtitle: Text(
                            branch.companyName ?? branch.roleLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: branch.id == session.activeBusinessId
                              ? const Text(
                                  'Actual',
                                  style: TextStyle(
                                    color: Color(0xFF059669),
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                  ),
                                )
                              : const Icon(Icons.chevron_right_rounded),
                          onTap: () async {
                            await ctrl.switchBusiness(branch.id);
                            if (!context.mounted) return;
                            Navigator.of(context).pop(branch);
                          },
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
