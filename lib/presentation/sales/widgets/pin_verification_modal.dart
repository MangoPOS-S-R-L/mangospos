import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../services/session/session_controller.dart';

Future<bool> showPinVerificationModal(
  BuildContext context,
  WidgetRef ref, {
  required PinAccessLevel level,
  String title = 'Verificación de PIN',
  String subtitle = 'Ingrese un PIN autorizado para continuar',
}) async {
  final controller = TextEditingController();
  String? localError;

  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setState) {
          Future<void> verify() async {
            final pin = controller.text.trim();
            if (pin.length != 4) {
              setState(() => localError = 'El PIN debe tener 4 dígitos.');
              return;
            }
            final ok = ref
                .read(sessionProvider.notifier)
                .verifyPin(pin: pin, level: level);
            if (!ok) {
              setState(
                () => localError = 'PIN inválido o sin jerarquía requerida.',
              );
              return;
            }
            if (ctx.mounted) Navigator.of(ctx).pop(true);
          }

          return AlertDialog(
            title: Text(title),
            content: SizedBox(
              width: 360,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(subtitle),
                  const SizedBox(height: 12),
                  TextField(
                    controller: controller,
                    keyboardType: TextInputType.number,
                    obscureText: true,
                    maxLength: 4,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: 'PIN',
                      counterText: '',
                    ),
                    onChanged: (_) {
                      if (localError != null) {
                        setState(() => localError = null);
                      }
                    },
                    onSubmitted: (_) => verify(),
                  ),
                  if (localError != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        localError!,
                        style: const TextStyle(color: Colors.red),
                      ),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Cancelar'),
              ),
              FilledButton(onPressed: verify, child: const Text('Verificar')),
            ],
          );
        },
      );
    },
  );

  controller.dispose();
  return result == true;
}
