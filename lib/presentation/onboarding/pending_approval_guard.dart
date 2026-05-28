// Guard global del shell autenticado: bloquea el acceso al POS si el
// business activo está en status='pending' (recién registrado, todavía
// no aprobado por el equipo interno). El guard sustituye el contenido
// del shell por PendingApprovalScreen hasta que el status pase a
// 'active'.
//
// Rutas exentas (donde el usuario está justamente intentando resolver
// o navegar fuera del bloqueo):
//   - /register/*           — pasos del registro inicial (caso edge si
//                             el guard se monta durante el flujo)
//   - /onboarding/*         — landing post-registro
//   - /login                — por si el usuario cierra sesión desde la
//                             screen y rebuild antes de que sessionProvider
//                             se vacíe
//
// Failure mode: si el fetch del status falla, dejamos pasar el child
// (no atrapamos al usuario en pantalla sin salida). El error queda en
// logs; cualquier acción real chocará contra RLS si la cuenta sigue
// pending. Mismo criterio que BillingGuard.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme/mango_colors.dart';
import '../../services/session/session_controller.dart';
import 'pending_approval_provider.dart';
import 'pending_approval_screen.dart';

class PendingApprovalGuard extends ConsumerWidget {
  final Widget child;
  const PendingApprovalGuard({super.key, required this.child});

  static const _exemptPathPrefixes = <String>[
    '/register',
    '/onboarding',
    '/login',
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final businessId = ref.watch(sessionProvider).activeBusinessId;
    if (businessId == null || businessId.isEmpty) return child;

    final currentPath = GoRouterState.of(context).uri.path;
    if (_exemptPathPrefixes.any(currentPath.startsWith)) {
      return child;
    }

    final statusAsync = ref.watch(businessStatusProvider(businessId));

    return statusAsync.when(
      skipLoadingOnRefresh: true,
      loading: () => const _PendingBootstrapLoading(),
      error: (_, _) => child,
      data: (status) {
        if (status == 'pending') {
          return PendingApprovalScreen(businessId: businessId);
        }
        return child;
      },
    );
  }
}

class _PendingBootstrapLoading extends StatelessWidget {
  const _PendingBootstrapLoading();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFBFAF9),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: MangoColors.primaryOrange,
                borderRadius: BorderRadius.circular(18),
                boxShadow: [
                  BoxShadow(
                    color: MangoColors.primaryOrange.withValues(alpha: 0.22),
                    blurRadius: 18,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: const Icon(
                Icons.point_of_sale_rounded,
                color: MangoColors.white,
                size: 32,
              ),
            ),
            const SizedBox(height: 24),
            const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: MangoColors.primaryOrange,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Preparando tu cuenta…',
              style: TextStyle(
                fontSize: 13,
                color: MangoColors.muted,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.3,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
