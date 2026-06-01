import 'package:flutter/material.dart';

import '../../core/offline/offline_pos_service.dart';

/// Confirma el cierre de sesión advirtiendo si hay operaciones offline sin
/// sincronizar que se perderán. El logout limpia los datos transaccionales
/// del negocio (snapshots, cola, mappings) para que el siguiente cajero no
/// vea ventas del anterior — pero eso descarta lo que no alcanzó a subir.
///
/// Devuelve `true` si se puede proceder con el logout (no había pendientes,
/// o el cajero confirmó descartarlas), `false` si canceló.
///
/// Compartido por [main_shell] y [mobile_shell] para no duplicar la lógica.
Future<bool> confirmLogoutDiscardingOffline(
  BuildContext context,
  String? businessId,
) async {
  if (businessId == null || businessId.isEmpty) return true;

  final service = OfflinePosService();
  int pending;
  int dead;
  try {
    pending = await service.pendingActionsCount(businessId);
    dead = await service.deadActionsCount(businessId);
  } catch (_) {
    // Si no podemos contar la cola, no bloqueamos el logout — pero tampoco
    // mentimos: dejamos pasar (el wipe en signOut es best-effort).
    return true;
  }

  final total = pending + dead;
  if (total == 0) return true;
  if (!context.mounted) return false;

  final detail = StringBuffer();
  if (pending > 0) detail.write('$pending pendiente(s) de sincronizar');
  if (dead > 0) {
    if (detail.isNotEmpty) detail.write(' y ');
    detail.write('$dead sin resolver');
  }

  final ok = await showDialog<bool>(
    context: context,
    builder: (_) => AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.warning_amber_rounded, color: Color(0xFFEF4444)),
          SizedBox(width: 8),
          Expanded(child: Text('Cerrar sesión con operaciones sin subir')),
        ],
      ),
      content: Text(
        'Tienes $detail. Si cierras sesión ahora, esas operaciones se '
        'descartarán y NO se enviarán al servidor.\n\n'
        'Conéctate y sincroniza antes de salir para no perder ventas. '
        '¿Cerrar sesión de todas formas?',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancelar'),
        ),
        TextButton(
          style: TextButton.styleFrom(foregroundColor: const Color(0xFFEF4444)),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Cerrar sesión'),
        ),
      ],
    ),
  );

  return ok == true;
}
