import 'package:go_router/go_router.dart';
import 'package:flutter/material.dart';
import '../../presentation/auth/login/login_view.dart';
import '../../presentation/auth/register/register_step1_view.dart';
import '../../presentation/auth/register/register_step2_view.dart';
import '../../presentation/dashboard/dashboard_view.dart';
import '../../presentation/shell/main_shell.dart';
import 'routes.dart';

class AppRouter {
  static GoRouter router = GoRouter(
    initialLocation: AppRoutes.login,
    routes: [
      GoRoute(path: AppRoutes.login, builder: (_, __) => const LoginView()),
      GoRoute(path: AppRoutes.register, builder: (_, __) => const RegisterStep1View()),
      GoRoute(path: AppRoutes.registerStep2, builder: (_, __) => const RegisterStep2View()),

      // Todo lo autenticado vive dentro del Shell
      ShellRoute(
        builder: (_, __, child) => MainShell(child: child),
        routes: [
          GoRoute(path: AppRoutes.dashboard,    builder: (_, __) => const DashboardView()),
          GoRoute(path: AppRoutes.sales,        builder: (_, __) => const _Placeholder('Sales')),
          GoRoute(path: AppRoutes.cashier,      builder: (_, __) => const _Placeholder('Cashier')),
          GoRoute(path: AppRoutes.kitchen,      builder: (_, __) => const _Placeholder('Kitchen')),
          GoRoute(path: AppRoutes.reservations, builder: (_, __) => const _Placeholder('Tables/Reservations')),
          GoRoute(path: AppRoutes.customers,    builder: (_, __) => const _Placeholder('Customers')),
          GoRoute(path: AppRoutes.products,     builder: (_, __) => const _Placeholder('Products')),
          GoRoute(path: AppRoutes.reports,      builder: (_, __) => const _Placeholder('Reports')),
          GoRoute(path: AppRoutes.settings,      builder: (_, __) => const _Placeholder('Herramientas')),
        ],
      ),
    ],
  );
}

// Placeholder temporal para compilar mientras llenamos cada módulo
class _Placeholder extends StatelessWidget {
  final String label;
  const _Placeholder(this.label, {super.key});
  @override
  Widget build(BuildContext context) => Center(child: Text(label));
}
