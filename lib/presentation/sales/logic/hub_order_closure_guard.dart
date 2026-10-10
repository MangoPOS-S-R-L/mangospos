import 'package:supabase_flutter/supabase_flutter.dart';

/// El estado cerrado del servidor no demuestra que el contenido del Hub haya
/// llegado: el barrido puede cerrar una cuenta que todavía está vacía allí.
class HubClosureReconciliation {
  const HubClosureReconciliation({
    this.confirmed = const {},
    this.conflicts = const {},
  });

  final Map<String, String> confirmed;
  final Set<String> conflicts;
}

Future<Map<String, String>> fetchClosedHubOrderStatuses(
  SupabaseClient client, {
  required String businessId,
  required Iterable<String> orderIds,
}) async {
  final ids = orderIds.toSet().toList(growable: false);
  final closed = <String, String>{};
  for (var i = 0; i < ids.length; i += 100) {
    final end = (i + 100).clamp(0, ids.length);
    // La sesión es la pertenencia canónica al negocio, también en schemas
    // que no tienen orders.business_id o en filas legacy sin ese valor.
    final found = await client
        .from('orders')
        .select('id, status_ext, table_sessions!inner(business_id)')
        .eq('table_sessions.business_id', businessId)
        .inFilter('id', ids.sublist(i, end))
        .inFilter('status_ext', ['paid', 'void']);
    for (final row in found) {
      final id = row['id']?.toString();
      final status = row['status_ext']?.toString();
      if (id != null && (status == 'paid' || status == 'void')) {
        closed[id] = status!;
      }
    }
  }
  return closed;
}

Future<HubClosureReconciliation> reconcileHubOrderClosures({
  required Map<String, String> remoteClosures,
  required Map<String, String> remoteOrderIds,
  required Set<String> ordersWithHubContent,
  required bool canVerifyHubUploads,
  required Future<List<Map<String, dynamic>>> Function() readQueueActions,
  required Future<List<Map<String, dynamic>>> Function() readHubActions,
  required Future<String?> Function(String) mappedOrderId,
}) async {
  if (remoteClosures.isEmpty) return const HubClosureReconciliation();
  try {
    final sources = await Future.wait([readQueueActions(), readHubActions()]);
    final aliases = <String, String>{...remoteOrderIds};
    for (final source in sources) {
      for (final action in source) {
        final id = action['order_id']?.toString();
        if (id == null || id.isEmpty) {
          if (_isOrderContent(action)) {
            throw StateError('Operación pendiente sin identidad de orden.');
          }
          continue;
        }
        if (!id.startsWith('local-order-') || aliases.containsKey(id)) continue;
        final remoteId = await mappedOrderId(id);
        if (remoteId == null || remoteId.isEmpty) {
          // No podemos demostrar que este contenido local pertenece a otra
          // cuenta. Conservamos las proyecciones hasta poder conciliarlo.
          if (_isOrderContent(action)) {
            throw StateError('No se pudo conciliar una identidad local.');
          }
        } else {
          aliases[id] = remoteId;
        }
      }
    }

    final confirmed = <String, String>{};
    final conflicts = <String>{};
    for (final entry in remoteClosures.entries) {
      final orderId = entry.key;
      final remoteId = remoteOrderIds[orderId] ?? orderId;
      final relevantSources = sources.map(
        (source) => source
            .where((action) {
              final id = action['order_id']?.toString();
              return id == orderId || id == remoteId || aliases[id] == remoteId;
            })
            .toList(growable: false),
      );
      var pendingContent = false;
      var explicitVoid = false;
      for (final source in relevantSources) {
        var sourcePending = false;
        for (final action in source) {
          if (entry.value == 'void' &&
              action['type'] == 'void_order' &&
              action['status'] != 'dead') {
            // Una anulación pedida por el operador sigue anulando la cuenta.
            // release_empty_order es tentativo y NO descarta contenido.
            sourcePending = false;
            explicitVoid = true;
          } else if (_isOrderContent(action)) {
            sourcePending = true;
          }
        }
        pendingContent |= sourcePending;
      }
      final unknownHubContent =
          !canVerifyHubUploads &&
          ordersWithHubContent.contains(orderId) &&
          !explicitVoid;
      if (pendingContent || unknownHubContent) {
        conflicts.add(orderId);
      } else {
        confirmed[orderId] = entry.value;
      }
    }
    return HubClosureReconciliation(confirmed: confirmed, conflicts: conflicts);
  } catch (_) {
    // Fallar la lectura o el mapping jamás equivale a una cola vacía.
    return HubClosureReconciliation(conflicts: remoteClosures.keys.toSet());
  }
}

bool _isOrderContent(Map<String, dynamic> action) {
  switch (action['type']) {
    case 'void_order':
    case 'release_empty_order':
    case 'open_cash_session':
    case 'close_cash_session':
    case 'cash_transaction':
    case 'inventory_adjust':
    case 'inventory_movement':
      return false;
    default:
      // Incluye pagos pendientes y tipos nuevos: no esconder dinero que no
      // tiene confirmación durable. Los dead también requieren revisión.
      return true;
  }
}
