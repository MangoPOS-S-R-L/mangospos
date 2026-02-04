import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http; // ✅ check internet
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:mangopos/utils/responsive_utils.dart';
import 'package:mangopos/widgets/responsive/responsive_icon.dart';

import '../../app/theme/mango_colors.dart';
import '../../app/router/routes.dart';

class MainShell extends StatefulWidget {
  final Widget child;
  const MainShell({super.key, required this.child});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  late Timer _tick;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(minutes: 1), (_) {
      setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _tick.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
                  // Logo
                  const _Logo(),
                  const SizedBox(width: 32),

                  // Menú principal (Centro)
                  Expanded(
                    child: Center(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        physics: const BouncingScrollPhysics(),
                        child: Row(
                          children: [
                            const _TopNavItem(
                              label: 'Home',
                              route: AppRoutes.dashboard,
                              asset: 'assets/icons/dashboard.svg',
                            ),
                            const SizedBox(width: navGap),
                            const _TopNavItem(
                              label: 'Ventas',
                              route: AppRoutes.sales,
                              asset: 'assets/icons/ventas_principal.svg',
                            ),
                            const SizedBox(width: navGap),
                            const _TopNavItem(
                              label: 'Caja',
                              route: AppRoutes.cashier,
                              asset: 'assets/icons/caja_principal.svg',
                            ),
                            const SizedBox(width: navGap),
                            const _TopNavItem(
                              label: 'Cocina',
                              route: AppRoutes.kitchen,
                              asset: 'assets/icons/cocina_principal.svg',
                            ),
                            const SizedBox(width: navGap),

                            const _TopNavItem(
                              label: 'Productos',
                              route: AppRoutes.products,
                              asset: 'assets/icons/productos_principal.svg',
                            ),
                            const SizedBox(width: navGap),
                            const _TopNavItem(
                              label: 'Reportes',
                              route: AppRoutes.reports,
                              asset: 'assets/icons/reportes_principal.svg',
                            ),
                            const SizedBox(width: navGap),
                            const _TopNavItem(
                              label: 'Más Ajustes',
                              route: AppRoutes.settings,
                              asset: 'assets/icons/masajustes.svg',
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),

                  // Sección derecha (Acciones)
                  Row(
                    children: [
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
            Expanded(child: widget.child),
          ],
        ),
      ),
    );
  }

  static String _fmtDate(DateTime d) {
    const wk = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const mo = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${wk[d.weekday - 1]}, ${d.day} ${mo[d.month - 1]} ${d.year}';
  }
}

// ===== ITEM DEL MENÚ (PILL SHAPE) =====
class _TopNavItem extends StatefulWidget {
  final String label;
  final String route;
  final String asset;
  final double iconSize;
  const _TopNavItem({
    required this.label,
    required this.route,
    required this.asset,
    this.iconSize = 20.0,
  });

  @override
  State<_TopNavItem> createState() => _TopNavItemState();
}

class _TopNavItemState extends State<_TopNavItem> {
  bool _isHovering = false;

  @override
  Widget build(BuildContext context) {
    final loc = GoRouterState.of(context).uri.toString();
    final active =
        loc == widget.route ||
        (widget.route != '/' && loc.startsWith(widget.route));

    final showLabel = MediaQuery.of(context).size.width >= 1024;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovering = true),
      onExit: (_) => setState(() => _isHovering = false),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => context.go(widget.route),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: active
                  ? MangoColors.primaryOrange
                  : (_isHovering
                        ? const Color(0xFFF7F7F9)
                        : Colors.transparent),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ColorFiltered(
                  colorFilter: ColorFilter.mode(
                    active ? Colors.white : Colors.grey[600]!,
                    BlendMode.srcIn,
                  ),
                  child: SvgPicture.asset(
                    widget.asset,
                    width: widget.iconSize,
                    height: widget.iconSize,
                  ),
                ),
                if (showLabel) ...[
                  const SizedBox(width: 8),
                  Text(
                    widget.label,
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 15,
                      fontWeight: active ? FontWeight.bold : FontWeight.w600,
                      color: active ? Colors.white : Colors.grey[700]!,
                    ),
                  ),
                ],
              ],
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
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: Colors.grey[100],
        shape: BoxShape.circle,
      ),
      child: IconButton(
        icon: Icon(Icons.notifications_none, color: Colors.grey[600]),
        onPressed: () {
          // TODO show notifications
        },
      ),
    );
  }
}

// ===== BOTÓN MAS AJUSTES =====
class _SettingsButton extends StatelessWidget {
  const _SettingsButton();

  @override
  Widget build(BuildContext context) {
    final loc = GoRouterState.of(context).uri.toString();
    final active =
        loc == AppRoutes.settings || loc.startsWith(AppRoutes.settings);

    final iconColor = active ? MangoColors.primaryOrange : Colors.grey[600]!;
    final textColor = active ? MangoColors.darkGray : Colors.grey[700]!;
    final iconSize = context.iconSizeOf(24);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        splashColor: MangoColors.primaryOrange.withOpacity(0.1),
        highlightColor: MangoColors.primaryOrange.withOpacity(0.05),
        onTap: () => context.go(AppRoutes.settings),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: EdgeInsets.symmetric(
            horizontal: context.wp(context.isDesktop ? 1.2 : 2),
            vertical: context.hp(context.isMobile ? 0.6 : 0.4),
          ),
          decoration: BoxDecoration(
            color: active
                ? MangoColors.primaryOrange.withOpacity(0.08)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: active
                  ? MangoColors.primaryOrange.withOpacity(0.2)
                  : Colors.transparent,
              width: 1,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SvgPicture.asset(
                'assets/icons/masajustes.svg',
                width: iconSize,
                height: iconSize,
                colorFilter: ColorFilter.mode(iconColor, BlendMode.srcIn),
              ),
              SizedBox(height: context.hp(context.isMobile ? 0.6 : 0.4)),
              Text(
                'Mas Ajustes',
                style: TextStyle(
                  fontSize: context.sp(12),
                  fontWeight: FontWeight.w600,
                  color: textColor,
                ),
              ),
              SizedBox(height: context.hp(context.isMobile ? 0.8 : 0.5)),
            ],
          ),
        ),
      ),
    );
  }
}

// ===== CHIP (para fecha) =====
class _Chip extends StatelessWidget {
  final Widget child;
  const _Chip({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: context.wp(context.isDesktop ? 1.4 : 3),
        vertical: context.hp(context.isMobile ? 0.8 : 0.6),
      ),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F7F9),
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: const Color(0xFFEAEAEA)),
      ),
      child: child,
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
      'assets/images/logo.png',
      height: 40, // Height fijo para que se vea correctamente
      fit: BoxFit.contain,
    );
  }
}

// ===== USER INFO =====
class _UserInfo extends StatelessWidget {
  const _UserInfo();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisAlignment: MainAxisAlignment.center,
          children: const [
            Text(
              'Admin',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 14,
                color: Color(0xFF1F2937),
              ),
            ),
            Text(
              'Caja #001',
              style: TextStyle(fontSize: 11, color: Color(0xFF6B7280)),
            ),
          ],
        ),
        const SizedBox(width: 12),
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: const LinearGradient(
              colors: [Color(0xFFF7941A), Color(0xFFFFB74D)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: const Icon(Icons.person, color: Colors.white, size: 20),
        ),
      ],
    );
  }
}

class _UserData {
  final String fullName;
  final String uid;
  final String businessId;
  final String role;
  final List<String> permissions;

  const _UserData({
    required this.fullName,
    required this.uid,
    required this.businessId,
    required this.role,
    required this.permissions,
  });
}
