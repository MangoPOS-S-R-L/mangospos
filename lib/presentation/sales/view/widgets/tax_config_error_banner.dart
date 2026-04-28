import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../viewmodel/sales_viewmodel.dart';

/// Banner persistente que se muestra cuando la configuración fiscal del
/// negocio activo no se pudo cargar. Mientras se muestra, los pagos están
/// bloqueados (ver `PaymentViewModel.processPayment`).
///
/// Producto del PRD 1 (Stop-the-Bleeding): se reemplazó el comportamiento
/// fail-silent (asumir 18%/10%) por fail-loud visible al operador.
class TaxConfigErrorBanner extends ConsumerWidget {
  const TaxConfigErrorBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final error = ref.watch(
      currentOrderProvider.select((s) => s.taxConfigError),
    );

    if (error == null || error.isEmpty) {
      return const SizedBox.shrink();
    }

    return Material(
      color: Colors.red.shade50,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline, color: Colors.red.shade700),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Configuración fiscal no disponible. Los pagos están bloqueados.',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: Colors.red.shade900,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    error,
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.red.shade800,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            TextButton(
              onPressed: () =>
                  ref.read(currentOrderProvider.notifier).reloadTaxConfiguration(),
              style: TextButton.styleFrom(
                foregroundColor: Colors.red.shade900,
              ),
              child: const Text('Reintentar'),
            ),
          ],
        ),
      ),
    );
  }
}
