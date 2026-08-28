// Banner de aviso/gracia — el escalón previo al bloqueo.
//
// Se muestra ENCIMA del POS sin quitarle la operación al cajero: puede seguir
// cobrando mientras el dueño resuelve el pago. La regresiva es la parte que
// importa — "te quedan 3 días" mueve más que "tienes un pago pendiente".
//
// Dos intensidades:
//   warning → ámbar, compacto, descartable por sesión.
//   grace   → rojo, no descartable (ya venció; la próxima parada es el bloqueo).

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/routes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../data/models/account_access_state.dart';

class AccessBanner extends StatelessWidget {
  const AccessBanner({
    super.key,
    required this.state,
    this.onDismiss,
  });

  final AccountAccessState state;

  /// Solo se ofrece en `warning`. En `grace` el banner no se puede quitar.
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final critical = state.level == AccessLevel.grace;
    final fg = critical ? AppColors.destructive : AppColors.warning;
    final bg = critical
        ? AppColors.destructive.withValues(alpha: 0.08)
        : AppColors.warningSurface;
    final countdown = state.countdownLabel;

    return Material(
      color: bg,
      child: Container(
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: fg.withValues(alpha: 0.35))),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Icon(
              critical ? Icons.error_rounded : Icons.info_rounded,
              color: fg,
              size: 20,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    countdown != null
                        ? '${state.title} · te quedan $countdown'
                        : state.title,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w800,
                      color: fg,
                    ),
                  ),
                  if (state.body.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      state.body,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12.5,
                        height: 1.35,
                        color: AppColors.mutedForeground,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
            TextButton(
              onPressed: () => context.go(AppRoutes.settingsBillingPaymentMethod),
              style: TextButton.styleFrom(
                foregroundColor: fg,
                padding: const EdgeInsets.symmetric(horizontal: 14),
              ),
              child: const Text(
                'Resolver',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            if (onDismiss != null)
              IconButton(
                tooltip: 'Ocultar por ahora',
                onPressed: onDismiss,
                icon: Icon(Icons.close_rounded, size: 18, color: fg),
                visualDensity: VisualDensity.compact,
              ),
          ],
        ),
      ),
    );
  }
}
