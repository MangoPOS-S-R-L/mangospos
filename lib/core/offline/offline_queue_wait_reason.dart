import 'offline_pos_service.dart';

/// Por qué una operación de la cola sigue sin llegar al servidor, en palabras
/// para el visor. Distingue lo que se resuelve solo (sin conexión, reintento
/// programado, esperando otro producto, imprimiendo) de lo que necesita a una
/// persona (revisión necesaria). Con [now] fijo para pruebas.
String offlineQueueWaitReason(
  Map<String, dynamic> action, {
  required bool online,
  DateTime? now,
}) {
  final at = now ?? DateTime.now();
  final status = action['status']?.toString() ?? 'pending';
  String two(int v) => v.toString().padLeft(2, '0');

  if (status == 'processing') return 'Subiendo ahora';
  if (OfflinePosService.isLocalKitchenRoundClaimed(action)) {
    return 'Imprimiendo la comanda';
  }
  if (action['kitchen_uncertain'] == true) {
    return 'Revisión necesaria: no se confirmó si salió la comanda';
  }
  if (status == 'dead') {
    if (action['payment_resolution'] != null) {
      return 'Revisión necesaria: cobro por decidir';
    }
    if (action['edit_conflict'] == true) {
      return 'Revisión necesaria: otro equipo cambió lo mismo';
    }
    return 'Revisión necesaria';
  }
  final waiting = action[OfflinePosService.kitchenHoldWaitingItemsKey];
  if (waiting is List && waiting.isNotEmpty) {
    return 'Esperando que suba el producto';
  }
  final lastError = action['last_error']?.toString().toLowerCase() ?? '';
  if (action['kitchen_hold'] == true && lastError.contains('migración')) {
    return 'Esperando actualización del servidor';
  }
  if (!online) return 'Sin conexión';
  final retryAt = DateTime.tryParse(action['next_retry_at']?.toString() ?? '');
  if (retryAt != null && retryAt.isAfter(at)) {
    final local = retryAt.toLocal();
    return 'Reintento programado a las '
        '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
  }
  if (status == 'failed') return 'Error del servidor';
  return 'En cola para subir';
}
