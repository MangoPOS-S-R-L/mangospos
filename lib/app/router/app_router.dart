import 'package:go_router/go_router.dart';
import 'package:flutter/material.dart';
import '../../presentation/auth/login/login_view.dart';
import '../../presentation/auth/register/register_step1_view.dart';
import '../../presentation/auth/register/register_step2_view.dart';
import '../../presentation/dashboard/dashboard_view.dart';
import '../../presentation/shell/main_shell.dart';

class AppRouter {
  static GoRouter router = GoRouter(
    initialLocation: '/login',
    routes: [
      GoRoute(path: '/login', builder: (_, __) => const LoginView()),

      // Registro en dos pasos
      GoRoute(path: '/register', builder: (_, __) => const RegisterStep1View()),
      GoRoute(path: '/register/branch', builder: (_, __) => const RegisterStep2View()),

      // Shell autenticado (placeholder)
      ShellRoute(
        builder: (_, __, child) => MainShell(child: child),
        routes: [
          GoRoute(path: '/dashboard', builder: (_, __) => const DashboardView()),
        ],
      ),
    ],
  );
}
