import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http; // ✅ check internet
import 'package:google_fonts/google_fonts.dart';

import 'package:mangopos/core/services/fullscreen/fullscreen_service.dart';
import 'package:mangopos/utils/responsive_utils.dart';
import 'package:mangopos/services/session/session_controller.dart';

import '../../app/theme/mango_colors.dart';
import '../../app/router/routes.dart';

class MainShell extends ConsumerWidget {
  final Widget child;
  const MainShell({super.key, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const topBarHeight = 64.0;
    const horizontalPadding = 16.0;
    const navGap = 16.0;

    return Scaffold(
      backgroundColor: const Color(0xFFFBFAF9),
      body: SafeArea(
        child: Column(
          children: [
            // ======= APP BAR =======
            Container(
              height: topBarHeight,
              width: double.infinity,
              padding: const EdgeInsets.symmetric(
                horizontal: horizontalPadding,
              ),
              decoration: const BoxDecoration(
                color: Colors.white,
                border: Border(bottom: BorderSide(color: Color(0xFFE5E7EB))),
                boxShadow: [
                  BoxShadow(
                    color: Color(0x0F000000), // Shadow soft
                    blurRadius: 4,
                    offset: Offset(0, 2),
                  ),
                ],
              ),
              child: Row(
                children: [
                  const SizedBox(width: 12),
                  const _Logo(),
                  const SizedBox(width: 32),

                  // Menú principal (Centro) - scroll horizontal cuando no cabe
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      physics: const BouncingScrollPhysics(),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                            const _TopNavItem(
                              label: 'Dashboard',
                              route: AppRoutes.dashboard,
                              asset: 'assets/icons/dashboard.svg',
                              permissionCode: 'dashboard.acceso',
                            ),
                            const SizedBox(width: navGap),
                            const _TopNavItem(
                              label: 'Ventas',
                              route: AppRoutes.sales,
                              asset: 'assets/icons/ventas_principal.svg',
                              permissionCode: 'ventas.mesas.acceso',
                            ),
                            const SizedBox(width: navGap),
                            const _TopNavItem(
                              label: 'Caja',
                              route: AppRoutes.cashier,
                              asset: 'assets/icons/caja_principal.svg',
                              permissionCode: 'caja.apertura',
                            ),
                            const SizedBox(width: navGap),
                            const _TopNavItem(
                              label: 'Cocina',
                              route: AppRoutes.kitchen,
                              asset: 'assets/icons/cocina_principal.svg',
                              permissionCode: 'kds.acceso',
                            ),
                            const SizedBox(width: navGap),

                            const _TopNavItem(
                              label: 'Productos',
                              route: AppRoutes.products,
                              asset: 'assets/icons/productos_principal.svg',
                              permissionCode: 'inventario.acceso',
                            ),
                            const SizedBox(width: navGap),
                            const _TopNavItem(
                              label: 'Reportes',
                              route: AppRoutes.reports,
                              asset: 'assets/icons/reportes_principal.svg',
                              permissionCode: 'reportes.ventas',
                            ),
                            const SizedBox(width: navGap),
                            const _TopNavItem(
                              label: 'Más Opciones',
                              route: AppRoutes.settings,
                              asset: 'assets/icons/masajustes.svg',
                              permissionCode: 'settings.usuarios.acceso',
                            ),
                          ],
                        ),
                      ),
                    ),

                  // Sección derecha (Acciones)
                  Row(
                    children: [
                      // Pantalla completa
                      const _FullscreenButton(),

                      const SizedBox(width: 12),

                      // Notificaciones
                      const _NotificationButton(),

                      const SizedBox(width: 16),

                      // Divider
                      Container(height: 32, width: 1, color: Colors.grey[300]),

                      const SizedBox(width: 16),

                      // User Info
                      const _UserInfo(),
                    ],
                  ),
                ],
              ),
            ),

            // ======= CONTENIDO =======
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}

// ===== ITEM DEL MENÚ (PILL SHAPE) =====
class _TopNavItem extends ConsumerStatefulWidget {
  final String label;
  final String route;
  final String asset;
  final String? permissionCode;
  const _TopNavItem({
    required this.label,
    required this.route,
    required this.asset,
    this.permissionCode,
  });

  @override
  ConsumerState<_TopNavItem> createState() => _TopNavItemState();
}

class _TopNavItemState extends ConsumerState<_TopNavItem> {
  bool _isHovering = false;

  @override
  Widget build(BuildContext context) {
    ref.watch(sessionProvider);
    final hasAccess =
        widget.permissionCode == null ||
        ref
            .read(sessionProvider.notifier)
            .hasPermission(widget.permissionCode!);
    final loc = GoRouterState.of(context).uri.toString();
    final active =
        loc == widget.route ||
        (widget.route != '/' && loc.startsWith(widget.route)) ||
        (widget.route == AppRoutes.settings && loc.startsWith(AppRoutes.menu));

    final showLabel = MediaQuery.of(context).size.width >= 768;
    final iconColor = hasAccess
        ? (active ? Colors.white : Colors.grey[600]!)
        : Colors.grey[500]!;
    final labelColor = hasAccess
        ? (active ? Colors.white : Colors.grey[700]!)
        : Colors.grey[500]!;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovering = true),
      onExit: (_) => setState(() => _isHovering = false),
      cursor: hasAccess
          ? SystemMouseCursors.click
          : SystemMouseCursors.forbidden,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: hasAccess ? () => context.go(widget.route) : null,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: hasAccess
                ? (active
                      ? MangoColors.primaryOrange
                      : (_isHovering
                            ? const Color(0xFFF7F7F9)
                            : Colors.transparent))
                : const Color(0xFFF7F7F9),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SvgPicture.asset(
                widget.asset,
                width: 22,
                height: 22,
                colorFilter: ColorFilter.mode(iconColor, BlendMode.srcIn),
              ),
              if (showLabel) ...[
                const SizedBox(width: 8),
                Text(
                  widget.label,
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 15,
                    fontWeight: active && hasAccess
                        ? FontWeight.bold
                        : FontWeight.w600,
                    color: labelColor,
                  ),
                ),
              ],
              if (!hasAccess) ...[
                const SizedBox(width: 6),
                const Icon(Icons.lock_outline, size: 14, color: Colors.grey),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ===== FULLSCREEN BUTTON =====
class _FullscreenButton extends StatefulWidget {
  const _FullscreenButton();

  @override
  State<_FullscreenButton> createState() => _FullscreenButtonState();
}

class _FullscreenButtonState extends State<_FullscreenButton> {
  final FullscreenService _service = createFullscreenService();
  bool _supported = false;
  bool _fullscreen = false;

  @override
  void initState() {
    super.initState();
    _loadState();
  }

  Future<void> _loadState() async {
    final supported = await _service.isSupported();
    final fullscreen = supported ? await _service.isFullscreen() : false;
    if (!mounted) return;
    setState(() {
      _supported = supported;
      _fullscreen = fullscreen;
    });
  }

  Future<void> _toggle() async {
    if (!_supported) return;
    await _service.toggleFullscreen();
    await _loadState();
  }

  @override
  Widget build(BuildContext context) {
    if (!_supported) {
      return const SizedBox.shrink();
    }

    return Tooltip(
      message: _fullscreen ? 'Salir de pantalla completa' : 'Pantalla completa',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: _toggle,
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: Colors.grey[100],
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Icon(
              _fullscreen ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded,
              color: Colors.grey[700],
            ),
          ),
        ),
      ),
    );
  }
}

// ===== NOTIFICATION BUTTON (New) =====
class _NotificationButton extends StatelessWidget {
  const _NotificationButton();

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () {
          // TODO show notifications
        },
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: Colors.grey[100],
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: Icon(Icons.notifications_none, color: Colors.grey[600]),
        ),
      ),
    );
  }
}

// ===== Caja cuadrada para el icono =====
class _SquareIconBox extends StatelessWidget {
  final Widget child;
  final double size;
  const _SquareIconBox({required this.child, this.size = 36});

  @override
  Widget build(BuildContext context) {
    final resolvedSize = context.iconSizeOf(size);
    return Container(
      width: resolvedSize,
      height: resolvedSize,
      decoration: BoxDecoration(
        color: const Color(0xFFF7F7F9),
        border: Border.all(color: const Color(0xFFEAEAEA)),
        borderRadius: BorderRadius.circular(15),
      ),
      alignment: Alignment.center,
      child: child,
    );
  }
}

// ===== Indicador de conexión (solo icono) =====
class _ConnectionIndicator extends StatefulWidget {
  const _ConnectionIndicator();

  @override
  State<_ConnectionIndicator> createState() => _ConnectionIndicatorState();
}

class _ConnectionIndicatorState extends State<_ConnectionIndicator> {
  bool _online = true;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _checkNow();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _checkNow());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _checkNow() async {
    final ok = await _hasInternet();
    if (mounted && ok != _online) setState(() => _online = ok);
  }

  Future<bool> _hasInternet() async {
    try {
      final res = await http
          .head(Uri.parse('https://www.gstatic.com/generate_204'))
          .timeout(const Duration(seconds: 2));
      return res.statusCode == 204 || res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = _online ? MangoColors.successGreen : Colors.redAccent;
    final iconSize = context.iconSizeOf(26);

    return _SquareIconBox(
      size: 44,
      child: SvgPicture.asset(
        'assets/icons/conexion.svg',
        width: iconSize,
        height: iconSize,
        colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
      ),
    );
  }
}

// ===== LOGO =====
class _Logo extends StatelessWidget {
  const _Logo();

  @override
  Widget build(BuildContext context) {
    // final logoHeight = context.hp(context.isMobile ? 6 : 5);
    return Image.asset(
      'assets/images/Logo Completo.png',
      height: 32, // Más compacto y elegante para el Dashboard
      fit: BoxFit.contain,
    );
  }
}

// ===== USER INFO =====
class _UserInfo extends ConsumerWidget {
  const _UserInfo();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    final ctrl = ref.read(sessionProvider.notifier);
    final role = session.activeRole;
    final roleLabel = role?.label ?? 'Sin rol';
    final businessName = session.activeBusinessName?.trim().isNotEmpty == true
        ? session.activeBusinessName!.trim()
        : 'Negocio';

    return Row(
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              'Hola, ${session.userName ?? 'Usuario'}',
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 15,
                color: Color(0xFF1F2937),
              ),
            ),
            const SizedBox(height: 4),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                InkWell(
                  onTap: session.availableRoles.length > 1
                      ? () async {
                          final selected = await showMenu<PosRole>(
                            context: context,
                            position: const RelativeRect.fromLTRB(0, 64, 24, 0),
                            items: session.availableRoles
                                .map(
                                  (r) => PopupMenuItem<PosRole>(
                                    value: r,
                                    child: Row(
                                      children: [
                                        if (r == role)
                                          const Padding(
                                            padding: EdgeInsets.only(right: 8),
                                            child: Icon(Icons.check, size: 14),
                                          ),
                                        Text(r.label),
                                      ],
                                    ),
                                  ),
                                )
                                .toList(),
                          );
                          if (selected != null) {
                            ctrl.switchRole(selected);
                          }
                        }
                      : null,
                  borderRadius: BorderRadius.circular(999),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF1F5F9),
                      border: Border.all(color: const Color(0xFFE2E8F0)),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      roleLabel,
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFF475569),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(width: 8),
        PopupMenuButton<_UserMenuAction>(
          tooltip: 'Menu de usuario',
          color: Colors.white,
          surfaceTintColor: Colors.white,
          shadowColor: const Color(0x14000000),
          elevation: 10,
          constraints: const BoxConstraints(minWidth: 300, maxWidth: 300),
          menuPadding: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: const BorderSide(color: Color(0xFFE5E7EB)),
          ),
          style: const ButtonStyle(
            overlayColor: WidgetStatePropertyAll(Colors.transparent),
            splashFactory: NoSplash.splashFactory,
          ),
          offset: const Offset(0, 12),
          onSelected: (value) async {
            switch (value) {
              case _UserMenuAction.switchBranch:
                final selected = await _showBranchPicker(context, session, ctrl);
                if (selected != null && context.mounted) {
                  context.go(AppRoutes.dashboard);
                }
                break;
              case _UserMenuAction.manageBranches:
                context.go(AppRoutes.settingsBranches);
                break;
              case _UserMenuAction.plan:
                context.go(AppRoutes.settingsPlan);
                break;
              case _UserMenuAction.settings:
                context.go(AppRoutes.settings);
                break;
              case _UserMenuAction.logout:
                await ctrl.signOut();
                if (!context.mounted) return;
                context.go(AppRoutes.login);
                break;
            }
          },
          itemBuilder: (_) => [
            PopupMenuItem<_UserMenuAction>(
              enabled: false,
              padding: EdgeInsets.zero,
              height: 88,
              child: Container(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
                child: Row(
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFF0E7),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(
                        Icons.storefront_rounded,
                        color: MangoColors.primaryOrange,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            businessName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 15,
                              color: Color(0xFF1F2937),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Sesion activa como $roleLabel',
                            style: const TextStyle(
                              fontSize: 12,
                              color: Color(0xFF6B7280),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const PopupMenuDivider(height: 1),
            PopupMenuItem<_UserMenuAction>(
              value: _UserMenuAction.switchBranch,
              padding: EdgeInsets.zero,
              height: 56,
              enabled: session.availableBusinesses.length > 1,
              child: _UserMenuTile(
                icon: Icons.swap_horiz_rounded,
                label: session.availableBusinesses.length > 1
                    ? 'Cambiar sucursal'
                    : 'Solo tienes una sucursal',
                accent: const Color(0xFFEAFBF3),
                iconColor: const Color(0xFF059669),
              ),
            ),
            const PopupMenuItem<_UserMenuAction>(
              value: _UserMenuAction.manageBranches,
              padding: EdgeInsets.zero,
              height: 56,
              child: _UserMenuTile(
                icon: Icons.apartment_rounded,
                label: 'Gestionar sucursales',
                accent: Color(0xFFFFF0D9),
                iconColor: MangoColors.primaryOrange,
              ),
            ),
            const PopupMenuItem<_UserMenuAction>(
              value: _UserMenuAction.plan,
              padding: EdgeInsets.zero,
              height: 56,
              child: _UserMenuTile(
                icon: Icons.rocket_launch_rounded,
                label: 'Mejorar plan',
                accent: Color(0xFFFFF0D9),
                iconColor: MangoColors.primaryOrange,
              ),
            ),
            const PopupMenuItem<_UserMenuAction>(
              value: _UserMenuAction.settings,
              padding: EdgeInsets.zero,
              height: 56,
              child: _UserMenuTile(
                icon: Icons.settings_rounded,
                label: 'Ajustes del sistema',
                accent: Color(0xFFEAF0FF),
                iconColor: Color(0xFF2563EB),
              ),
            ),
            const PopupMenuDivider(height: 1),
            const PopupMenuItem<_UserMenuAction>(
              value: _UserMenuAction.logout,
              padding: EdgeInsets.zero,
              height: 56,
              child: _UserMenuTile(
                icon: Icons.logout_rounded,
                label: 'Cerrar sesion',
                accent: Color(0xFFFFE7E7),
                iconColor: Color(0xFFDC2626),
                textColor: Color(0xFFDC2626),
              ),
            ),
            const PopupMenuDivider(height: 1),
            const PopupMenuItem<_UserMenuAction>(
              enabled: false,
              padding: EdgeInsets.zero,
              height: 40,
              child: ColoredBox(
                color: Color(0xFFF8FAFC),
                child: Center(
                  child: Text(
                    'version ${String.fromEnvironment('APP_VERSION', defaultValue: '1.0.0')}',
                    style: TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
                  ),
                ),
              ),
            ),
          ],
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const LinearGradient(
                colors: [Color(0xFFF97316), Color(0xFFFFB74D)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x1FF97316),
                  blurRadius: 12,
                  offset: Offset(0, 4),
                ),
              ],
            ),
            child: const Icon(Icons.person, color: Colors.white, size: 20),
          ),
        ),
      ],
    );
  }
}

Future<SessionBusiness?> _showBranchPicker(
  BuildContext context,
  SessionState session,
  SessionController ctrl,
) async {
  return showModalBottomSheet<SessionBusiness>(
    context: context,
    backgroundColor: Colors.white,
    showDragHandle: true,
    builder: (context) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFFF97316), Color(0xFFFBAA16)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(22),
                ),
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Cambiar sucursal',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                      ),
                    ),
                    SizedBox(height: 6),
                    Text(
                      'Cada sucursal trabaja con sus propios datos. Cambiar aquí cambia el negocio activo del panel.',
                      style: TextStyle(color: Colors.white, fontSize: 13),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              for (final branch in session.availableBusinesses)
                Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: branch.id == session.activeBusinessId
                          ? const Color(0xFFFED7AA)
                          : const Color(0xFFE5E7EB),
                    ),
                  ),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 4,
                    ),
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
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    subtitle: Text(branch.companyName ?? branch.roleLabel),
                    trailing: branch.id == session.activeBusinessId
                        ? Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFECFDF5),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: const Text(
                              'Actual',
                              style: TextStyle(
                                color: Color(0xFF059669),
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
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
      );
    },
  );
}

enum _UserMenuAction { switchBranch, manageBranches, plan, settings, logout }

class _UserMenuTile extends StatelessWidget {
  const _UserMenuTile({
    required this.icon,
    required this.label,
    required this.accent,
    required this.iconColor,
    this.textColor,
  });

  final IconData icon;
  final String label;
  final Color accent;
  final Color iconColor;
  final Color? textColor;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: accent,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 18, color: iconColor),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: textColor ?? const Color(0xFF374151),
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Icon(
            Icons.chevron_right_rounded,
            size: 18,
            color: (textColor ?? const Color(0xFF9CA3AF)).withValues(
              alpha: 0.8,
            ),
          ),
        ],
      ),
    );
  }
}
