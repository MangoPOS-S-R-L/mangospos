import 'package:flutter/material.dart';

import '../state/sales_state.dart' show EditConflictNotice;

/// T04 (20261010_0006): otro equipo cambió lo que el operador editaba y su
/// cambio no se aplicó. Muestra qué quería hacer y lo que hay ahora, y deja
/// decidir: quedarse con lo de ahora o aplicar su cambio encima.
///
/// Devuelve true si eligió aplicar su cambio. [canApplyMine] es false cuando
/// ya no hay sobre qué aplicarlo (cuenta cerrada, producto quitado o cobrado)
/// o el cambio quedaría a medias.
Future<bool> showEditConflictDialog(
  BuildContext context, {
  required EditConflictNotice notice,
  required bool canApplyMine,
}) async {
  final applyMine = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Otro equipo cambió esta cuenta'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(notice.message),
          if (notice.detail != null) ...[
            const SizedBox(height: 8),
            Text(
              notice.detail!,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ],
          const SizedBox(height: 12),
          Text(
            canApplyMine
                ? 'La cuenta ya muestra lo que hay ahora. Puedes dejarla así o '
                      'aplicar tu cambio encima.'
                : 'La cuenta ya muestra lo que hay ahora. Revísala y vuelve a '
                      'hacer el cambio si todavía aplica.',
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: Text(canApplyMine ? 'Quedarme con lo de ahora' : 'Entendido'),
        ),
        if (canApplyMine)
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Aplicar mi cambio'),
          ),
      ],
    ),
  );
  return applyMine == true;
}
