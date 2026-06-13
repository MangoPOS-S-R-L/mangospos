import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'hub/hub_client.dart';
import 'ncf_offline_allocator.dart';
import 'ncf_range_service.dart';

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

/// Composición lista-para-usar del [OfflineNcfService] para el modelo (b):
/// serie central + Hub como asignador único en la LAN. Centraliza el armado
/// para que los viewmodels de cobro (single y split) no lo dupliquen.
///
/// Devuelve el NCF asignado, o null (→ el caller entrega recibo PROVISIONAL)
/// cuando: F4 está apagado, el tipo no es de PAPEL (B0x; e-CF se difiere al
/// sync), no hay serie/rango, o no hay Hub alcanzable (caja aislada). NO asigna
/// localmente sin Hub: sin coordinador habría riesgo de huecos/duplicados.
Future<NcfAssignment?> allocateOfflineNcfPaper({
  required SupabaseClient client,
  required String businessId,
  required String? ncfType,
  required bool Function() isConnected,
}) async {
  if (!kOfflineNcfEnabled) return null;
  if (ncfType == null || !ncfType.toUpperCase().startsWith('B')) return null;

  final hubClient = HubClient();
  try {
    final svc = OfflineNcfService(
      isConnected: isConnected,
      resolveRange: () => NcfRangeService(client)
          .resolveBusinessSeries(businessId: businessId, ncfType: ncfType),
      allocateViaHub: (range) async {
        final url = await hubClient.findReachableHub(businessId: businessId);
        if (url == null) return null;
        return hubClient.allocateNcf(url, businessId: businessId, range: range);
      },
      allocateLocal: (_) async => null,
    );
    return await svc.allocate();
  } catch (e) {
    debugPrint('F4: no se pudo asignar NCF offline: $e');
    return null;
  } finally {
    hubClient.dispose();
  }
}
