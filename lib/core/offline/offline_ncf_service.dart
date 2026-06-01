import 'ncf_offline_allocator.dart';

typedef NcfRangeResolver = Future<NcfRange?> Function();
typedef NcfAllocateFn = Future<NcfAssignment?> Function(NcfRange range);

/// Orquestador de la asignación de NCF en un cobro (F4). Decide, en un solo
/// punto, de dónde sale el comprobante para que el flujo de cobro tenga UNA
/// sola llamada.
///
/// Reglas (en orden):
///   1. Si F4 está apagado ([enabled] = `kOfflineNcfEnabled`) → null: el cobro
///      se comporta como hoy (sin NCF offline; el server lo emite al sync).
///   2. Si hay internet → null: el server emite el NCF (camino actual).
///   3. Sin internet: se resuelve el rango/serie. Sin rango asignado → null
///      → el caller entrega recibo PROVISIONAL sin NCF.
///   4. Con rango y Hub alcanzable → el Hub asigna (asignador único en LAN →
///      secuencial, sin huecos).
///   5. Con rango pero sin Hub (caja aislada) → asignación local desde el
///      sub-rango del dispositivo (fallback). Si el rango se agotó → null →
///      recibo provisional.
///
/// `null` siempre significa "no hay NCF offline para este cobro" — el caller
/// decide entre dejar que el server lo emita (online) o entregar provisional.
///
/// Diseñado con colaboradores inyectados (funciones) para ser testeable sin
/// red/BD. La composición real los arma desde HubClient / NcfRangeService /
/// NcfOfflineAllocator / ConnectivityService.
class OfflineNcfService {
  OfflineNcfService({
    required this.isConnected,
    required this.resolveRange,
    required this.allocateViaHub,
    required this.allocateLocal,
    this.enabled = kOfflineNcfEnabled,
  });

  final bool Function() isConnected;
  final NcfRangeResolver resolveRange;

  /// Pide el NCF al Hub (asignador único). Devuelve null si no hay Hub o no
  /// respondió → se cae al fallback local.
  final NcfAllocateFn allocateViaHub;

  /// Asignación local desde el sub-rango del dispositivo (caja aislada).
  final NcfAllocateFn allocateLocal;

  final bool enabled;

  Future<NcfAssignment?> allocate() async {
    if (!enabled) return null; // F4 apagado → comportamiento de hoy
    if (isConnected()) return null; // online → el server emite el NCF

    final range = await resolveRange();
    if (range == null) return null; // sin rango → recibo provisional

    final viaHub = await allocateViaHub(range);
    if (viaHub != null) return viaHub; // Hub asignó (sin huecos)

    return allocateLocal(range); // caja aislada → sub-rango local (o null si agotado)
  }
}
