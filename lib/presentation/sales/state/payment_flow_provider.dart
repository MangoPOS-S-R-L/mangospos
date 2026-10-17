import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Un solo cobro visible por sesión, incluso entre distintas vistas o cuentas.
final paymentFlowProvider = NotifierProvider<PaymentFlowController, bool>(
  PaymentFlowController.new,
);

class PaymentFlowController extends Notifier<bool> {
  @override
  bool build() => false;

  /// Adquiere el bloqueo antes de cargar la cuenta y lo conserva hasta que
  /// cierre el modal y termine el flujo posterior al pago. No expira mientras
  /// el cajero elige el método o espera la impresión.
  Future<void> run(Future<void> Function() action) async {
    if (state) return;
    state = true;
    try {
      await action();
    } finally {
      if (ref.mounted) state = false;
    }
  }
}
