import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http; // ✅ check internet
import 'package:supabase_flutter/supabase_flutter.dart';

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
    final isWide = MediaQuery.of(context).size.width >= 1100;

    return Scaffold(
      backgroundColor: const Color(0xFFF2F2F2),
      body: Column(
        children: [
          // ======= APP BAR =======
          Container(
            height: 84,
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            decoration: const BoxDecoration(
              color: MangoColors.white,
              boxShadow: [
                BoxShadow(
                  color: Color(0x1A000000),
                  blurRadius: 6,
                  offset: Offset(0, 2),
                ),
              ],
            ),
            child: Row(
              children: [
                // Logo
                const _Logo(),
                const SizedBox(width: 24),

                // Menú principal
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    physics: const BouncingScrollPhysics(),
                    child: Row(
                      children: const [
                        _TopNavItem(
                          label: 'Home',
                          route: AppRoutes.dashboard,
                          asset: 'assets/icons/dashboard.svg',
                          iconSize: 24,
                        ),
                        SizedBox(width: 20),
                        _TopNavItem(
                          label: 'Ventas',
                          route: AppRoutes.sales,
                          asset: 'assets/icons/ventas_principal.svg',
                          iconSize: 24,
                        ),
                        SizedBox(width: 20),
                        _TopNavItem(
                          label: 'Caja',
                          route: AppRoutes.cashier,
                          asset: 'assets/icons/caja_principal.svg',
                          iconSize: 24,
                        ),
                        SizedBox(width: 20),
                        _TopNavItem(
                          label: 'Cocina',
                          route: AppRoutes.kitchen,
                          asset: 'assets/icons/cocina_principal.svg',
                          iconSize: 24,
                        ),
                        SizedBox(width: 20),
                        _TopNavItem(
                          label: 'Clientes',
                          route: AppRoutes.customers,
                          asset: 'assets/icons/clientes_principal.svg',
                          iconSize: 24,
                        ),
                        SizedBox(width: 20),
                        _TopNavItem(
                          label: 'Productos',
                          route: AppRoutes.products,
                          asset: 'assets/icons/productos_principal.svg',
                          iconSize: 24,
                        ),
                        SizedBox(width: 20),
                        _TopNavItem(
                          label: 'Reportes',
                          route: AppRoutes.reports,
                          asset: 'assets/icons/reportes_principal.svg',
                          iconSize: 24,
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(width: 24),

                // Sección derecha
                Row(
                  children: [
                    // Mas Ajustes
                    const _SettingsButton(),

                    // Divisor
                    if (isWide) ...[
                      SizedBox(
                        height: 32,
                        child: VerticalDivider(
                          thickness: 1,
                          width: 32,
                          color: Colors.grey[300],
                        ),
                      ),

                      // Chip de FECHA
                      _Chip(
                        child: Row(
                          children: [
                            const Icon(
                              Icons.event_available_outlined,
                              size: 16,
                              color: MangoColors.primaryOrange,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              _fmtDate(_now),
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(width: 8),

                      // ✅ Indicador de Conexión (reemplaza la hora)
                      const _ConnectionIndicator(),

                      // Divisor antes del usuario
                      SizedBox(
                        height: 32,
                        child: VerticalDivider(
                          thickness: 1,
                          width: 32,
                          color: Colors.grey[300],
                        ),
                      ),
                    ] else ...[
                      const SizedBox(width: 20),
                    ],

                    // Usuario
                    const _UserInfo(),
                  ],
                ),
              ],
            ),
          ),

          // ======= CONTENIDO =======
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Container(color: MangoColors.white, child: widget.child),
              ),
            ),
          ),
        ],
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

// ===== ITEM DEL MENÚ =====
class _TopNavItem extends StatelessWidget {
  final String label;
  final String route;
  final String asset;
  final double iconSize;
  const _TopNavItem({
    required this.label,
    required this.route,
    required this.asset,
    this.iconSize = 26,
  });

  @override
  Widget build(BuildContext context) {
    final loc = GoRouterState.of(context).uri.toString();
    final active = loc == route || (route != '/' && loc.startsWith(route));

    final iconColor = active ? MangoColors.primaryOrange : Colors.grey[600]!;
    final textColor = active ? MangoColors.darkGray : Colors.grey[700]!;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        splashColor: MangoColors.primaryOrange.withOpacity(0.1),
        highlightColor: MangoColors.primaryOrange.withOpacity(0.05),
        onTap: () => context.go(route),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
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
              ColorFiltered(
                colorFilter: ColorFilter.mode(iconColor, BlendMode.srcIn),
                child: SvgPicture.asset(
                  asset,
                  width: iconSize,
                  height: iconSize,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: textColor,
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
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

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        splashColor: MangoColors.primaryOrange.withOpacity(0.1),
        highlightColor: MangoColors.primaryOrange.withOpacity(0.05),
        onTap: () => context.go(AppRoutes.settings),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
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
                width: 24,
                height: 24,
                colorFilter: ColorFilter.mode(iconColor, BlendMode.srcIn),
              ),
              const SizedBox(height: 6),
              Text(
                'Mas Ajustes',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: textColor,
                ),
              ),
              const SizedBox(height: 8),
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
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
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
    return Container(
      width: size,
      height: size,
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

    return _SquareIconBox(
      size: 44,
      child: SvgPicture.asset(
        'assets/icons/conexion.svg',
        width: 26,
        height: 26,
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
    return Image.asset(
      'assets/images/logo.png',
      height: 60,
      fit: BoxFit.contain,
    );
  }
}

// ===== USER INFO =====
class _UserInfo extends StatelessWidget {
  const _UserInfo();

  Future<_UserData> _loadUserInfo() async {
    final supabase = Supabase.instance.client;
    final user = supabase.auth.currentUser;

    if (user == null) {
      return const _UserData(
        fullName: 'Invitado',
        uid: '—',
        businessId: '—',
        role: 'guest',
        permissions: <String>[],
      );
    }

    String fullName = 'Usuario';
    try {
      final profile = await supabase
          .from('profiles')
          .select('full_name')
          .eq('id', user.id)
          .maybeSingle();
      final pName = profile?['full_name']?.toString().trim();
      if (pName != null && pName.isNotEmpty) fullName = pName;
    } catch (_) {}

    String businessId = '—';
    String role = 'user';
    List<dynamic> rawPerms = const [];
    try {
      final ub = await supabase
          .from('user_businesses')
          .select('business_id, role, permissions')
          .eq('user_id', user.id)
          .order('created_at', ascending: true)
          .limit(1)
          .maybeSingle();
      if (ub != null) {
        if (ub['business_id'] != null) {
          businessId = ub['business_id'].toString();
        }
        if (ub['role'] != null) role = ub['role'].toString().toLowerCase();
        if (ub['permissions'] != null) rawPerms = (ub['permissions'] as List);
      }
    } catch (_) {}

    final permissions = rawPerms
        .map((e) => e.toString())
        .toList(growable: false);

    return _UserData(
      fullName: fullName,
      uid: user.id,
      businessId: businessId,
      role: role,
      permissions: permissions,
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_UserData>(
      future: _loadUserInfo(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Row(
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 8),
              Text('Cargando...'),
            ],
          );
        }
        if (snap.hasError || snap.data == null) {
          return const Text(
            'Error al cargar usuario',
            style: TextStyle(color: Colors.red),
          );
        }

        final info = snap.data!;
        final initials = _initialsFromFullName(info.fullName);

        return Row(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  info.fullName,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: MangoColors.darkGray,
                  ),
                ),
                const SizedBox(height: 4),
                if (info.role == 'admin' || info.role == 'owner')
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: MangoColors.successGreen,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Text(
                      'Administrador',
                      style: TextStyle(
                        color: MangoColors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 12),
            CircleAvatar(
              radius: 20,
              backgroundColor: MangoColors.primaryOrange.withOpacity(0.12),
              child: Text(
                initials,
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 14,
                  color: MangoColors.primaryOrange,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  static String _initialsFromFullName(String fullName) {
    final parts = fullName.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty) return 'U';
    if (parts.length == 1) return parts.first[0].toUpperCase();
    return (parts.first[0] + parts.last[0]).toUpperCase();
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
