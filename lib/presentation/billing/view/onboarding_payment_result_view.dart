// Landing al regresar del Payment Page de Azul.
//
// El callback Edge Function redirige acá con `?result=approved|declined|cancelled|error`
// (y opcionalmente `&reason=...` cuando declined). La pantalla:
//   - Muestra estado visual del resultado.
//   - Si fue approved: invita a continuar a la pantalla de mi suscripción.
//   - Si declined/cancelled: invita a reintentar.
//   - Si error/tampered: muestra mensaje genérico de soporte.

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/routes.dart';
import '../../../app/theme/mango_colors.dart';

class OnboardingPaymentResultView extends StatelessWidget {
  final String? result;
  final String? reason;
  const OnboardingPaymentResultView({super.key, this.result, this.reason});

  _ResultPresentation get _presentation {
    switch (result) {
      case 'approved':
        return _ResultPresentation(
          icon: Icons.check_circle_rounded,
          color: MangoColors.successGreen,
          title: '¡Tarjeta verificada!',
          body: 'Tu método de pago quedó registrado de forma segura. '
              'Cobramos RD\$1.00 que será reembolsado automáticamente. '
              'Cuando inicie tu suscripción, te avisaremos antes del primer cobro.',
          primaryAction: _PrimaryAction(
            label: 'Ver mi suscripción',
            route: AppRoutes.settingsBilling,
          ),
          secondaryAction: null,
        );
      case 'declined':
        return _ResultPresentation(
          icon: Icons.cancel_rounded,
          color: const Color(0xFFB91C1C),
          title: 'Tu banco declinó la tarjeta',
          body: reason != null && reason!.isNotEmpty
              ? 'Motivo: $reason\n\nIntenta con otra tarjeta o consulta con tu banco.'
              : 'Intenta con otra tarjeta o consulta con tu banco antes de reintentar.',
          primaryAction: _PrimaryAction(
            label: 'Probar otra tarjeta',
            route: AppRoutes.settingsBillingPaymentMethod,
          ),
          secondaryAction: _PrimaryAction(
            label: 'Volver a mi suscripción',
            route: AppRoutes.settingsBilling,
          ),
        );
      case 'cancelled':
        return _ResultPresentation(
          icon: Icons.info_outline_rounded,
          color: MangoColors.muted,
          title: 'Cancelaste la operación',
          body: 'No se realizó ningún cargo. Puedes intentar de nuevo cuando quieras.',
          primaryAction: _PrimaryAction(
            label: 'Reintentar',
            route: AppRoutes.settingsBillingPaymentMethod,
          ),
          secondaryAction: _PrimaryAction(
            label: 'Volver a mi suscripción',
            route: AppRoutes.settingsBilling,
          ),
        );
      case 'error':
      default:
        return _ResultPresentation(
          icon: Icons.error_outline_rounded,
          color: const Color(0xFFB45309),
          title: 'Algo salió mal',
          body: 'No pudimos completar la operación. Si el problema persiste, '
              'escríbenos a soporte@mangopos.do indicando la fecha y hora.',
          primaryAction: _PrimaryAction(
            label: 'Volver a mi suscripción',
            route: AppRoutes.settingsBilling,
          ),
          secondaryAction: null,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _presentation;
    return Scaffold(
      backgroundColor: const Color(0xFFF7F7F7),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Container(
                padding: const EdgeInsets.all(28),
                decoration: BoxDecoration(
                  color: MangoColors.white,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: const [
                    BoxShadow(color: Color(0x14000000), blurRadius: 24, offset: Offset(0, 6)),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      width: 80,
                      height: 80,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: p.color.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(40),
                      ),
                      child: Icon(p.icon, color: p.color, size: 44),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      p.title,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                        color: p.color,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      p.body,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14,
                        height: 1.5,
                        color: MangoColors.darkGray.withValues(alpha: 0.85),
                      ),
                    ),
                    const SizedBox(height: 24),
                    FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: MangoColors.primaryOrange,
                        foregroundColor: MangoColors.white,
                        minimumSize: const Size.fromHeight(48),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                      onPressed: () => context.go(p.primaryAction.route),
                      child: Text(
                        p.primaryAction.label,
                        style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                      ),
                    ),
                    if (p.secondaryAction != null) ...[
                      const SizedBox(height: 10),
                      TextButton(
                        onPressed: () => context.go(p.secondaryAction!.route),
                        child: Text(
                          p.secondaryAction!.label,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            color: MangoColors.muted,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ResultPresentation {
  final IconData icon;
  final Color color;
  final String title;
  final String body;
  final _PrimaryAction primaryAction;
  final _PrimaryAction? secondaryAction;

  _ResultPresentation({
    required this.icon,
    required this.color,
    required this.title,
    required this.body,
    required this.primaryAction,
    required this.secondaryAction,
  });
}

class _PrimaryAction {
  final String label;
  final String route;
  const _PrimaryAction({required this.label, required this.route});
}
