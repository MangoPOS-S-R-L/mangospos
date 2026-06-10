// Bottom sheet para tokenizar una tarjeta vía Azul. Envuelve el form
// reutilizable [AzulCardForm]; se usa en flujos donde el usuario cambia/agrega
// la tarjeta después del registro (p.ej. Suscripción → método de pago).
//
// Para el Step 4 del registro la captura va inline en la página (no sheet).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/repositories/billing_repository.dart';
import 'azul_card_form.dart';

class AzulCardFormSheet extends ConsumerWidget {
  final String businessId;
  final bool makeDefault;

  const AzulCardFormSheet({
    super.key,
    required this.businessId,
    this.makeDefault = true,
  });

  /// Abre el sheet y devuelve el método de pago tokenizado, o `null` si se cerró
  /// sin completar.
  static Future<TokenizedCardResult?> show(
    BuildContext context, {
    required String businessId,
    bool makeDefault = true,
  }) {
    return showModalBottomSheet<TokenizedCardResult>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: AzulCardFormSheet(businessId: businessId, makeDefault: makeDefault),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: theme.dividerColor,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Text('Registrar tarjeta',
              style: theme.textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(
            'Verificaremos tu tarjeta con una autorización temporal de RD\$1 que se libera al instante. Tus datos viajan cifrados a Azul; guardamos solo un token, nunca tu número.',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
          ),
          const SizedBox(height: 20),
          AzulCardForm(
            businessId: businessId,
            makeDefault: makeDefault,
            submitLabel: 'Guardar tarjeta',
            onSuccess: (result) => Navigator.of(context).pop(result),
          ),
        ],
      ),
    );
  }
}
