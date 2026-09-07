import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'hub_state_db.dart';

/// Captura y sirve el BASELINE del Hub: la foto de las órdenes que ya estaban
/// abiertas antes de que se cayera internet (paso 6 del plan offline).
///
/// Por qué hace falta: los proyectores solo reconstruyen órdenes CREADAS
/// durante la ventana offline —son las únicas cuyas ops están en el op-log—.
/// Una mesa que otra caja abrió mientras había internet vive solo en Supabase,
/// así que al caer la red el Hub no sabía qué tenía dentro: la mesa se veía
/// ocupada en el grid (eso ya lo cubre el cache de estado de zonas) pero al
/// abrirla salía vacía.
///
/// Cuándo se captura: mientras el equipo es el Hub Y tiene internet. Es la
/// misma idea de la bajada proactiva de F6 — bajar lo que se va a necesitar
/// ANTES de que haga falta, porque cuando hace falta ya no hay red.
///
/// La foto se guarda como ops sintéticas para que la proyección sea
/// `projector([...baseline, ...log])`: lo que se hizo offline se apila encima
/// usando el proyector ya probado, sin lógica de mezcla nueva.
class HubBaselineService {
  HubBaselineService({HubStateDb? db, SupabaseClient? client})
    : _injectedDb = db,
      _injectedClient = client;

  final HubStateDb? _injectedDb;
  final SupabaseClient? _injectedClient;

  HubStateDb get _db => _injectedDb ?? HubStateDb.getInstance();
  SupabaseClient get _client => _injectedClient ?? Supabase.instance.client;

  /// PostgREST arma la URL con los ids en el query string, así que un `in`
  /// gigante revienta con 414. Se trocea igual que en el resto del repo.
  static const int _inFilterBatch = 150;

  /// Ítems que siguen "en la mesa". `void` está anulado y `draft` todavía no se
  /// mandó a cocina desde el equipo que lo tecleó — ninguno de los dos debe
  /// aparecer en la orden que ve otra caja.
  static const List<String> _liveItemStatuses = [
    'pending',
    'preparing',
    'ready',
    'served',
  ];

  /// Baja de Supabase las órdenes abiertas del negocio y guarda la foto.
  ///
  /// Requiere internet: se llama desde el camino online del Hub. Best-effort —
  /// si algo falla, se conserva la foto anterior (vieja es infinitamente mejor
  /// que ninguna) y se reintenta en la próxima pasada.
  ///
  /// Devuelve cuántas órdenes quedaron en la foto, o `null` si falló.
  Future<int?> capture(String businessId) async {
    try {
      final ops = await _buildOps(businessId);
      await _db
          .into(_db.hubBaseline)
          .insertOnConflictUpdate(
            HubBaselineCompanion.insert(
              businessId: businessId,
              capturedAt: DateTime.now().toUtc(),
              opsJson: jsonEncode(ops),
              // `insert` exige los required; el resto queda por defecto.
            ),
          );
      final orders = ops.where((o) => o['type'] == 'open_table').length;
      debugPrint(
        '[HubBaseline] foto de $businessId: $orders órdenes, '
        '${ops.length} ops sintéticas.',
      );
      return orders;
    } catch (e) {
      debugPrint('[HubBaseline] captura de $businessId falló: $e');
      return null;
    }
  }

  /// Ops sintéticas de la foto guardada, listas para plegar ANTES del op-log.
  /// Lista vacía si nunca se capturó.
  Future<List<Map<String, dynamic>>> ops(String businessId) async {
    try {
      final row =
          await (_db.select(_db.hubBaseline)
                ..where((t) => t.businessId.equals(businessId))
                ..limit(1))
              .getSingleOrNull();
      if (row == null) return const [];
      final decoded = jsonDecode(row.opsJson);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList(growable: false);
    } catch (e) {
      debugPrint('[HubBaseline] lectura de $businessId falló: $e');
      return const [];
    }
  }

  /// Cuándo se tomó la foto. `null` si no hay foto.
  Future<DateTime?> capturedAt(String businessId) async {
    try {
      final row =
          await (_db.select(_db.hubBaseline)
                ..where((t) => t.businessId.equals(businessId))
                ..limit(1))
              .getSingleOrNull();
      return row?.capturedAt;
    } catch (_) {
      return null;
    }
  }

  /// Huella de la foto, para que el cache de proyección sepa que cambió.
  ///
  /// Se calcula del CONTENIDO y no de `capturedAt` por una razón concreta:
  /// drift guarda `DateTime` con resolución de SEGUNDOS, así que dos capturas
  /// dentro del mismo segundo son indistinguibles por su marca de tiempo y el
  /// cache seguiría sirviendo la foto vieja. Con el contenido, además, dos
  /// capturas idénticas NO invalidan — que es justo lo correcto: si nada
  /// cambió, no hay nada que reproyectar.
  ///
  /// `'0'` cuando no hay foto.
  Future<String> revision(String businessId) async {
    try {
      final row =
          await (_db.select(_db.hubBaseline)
                ..where((t) => t.businessId.equals(businessId))
                ..limit(1))
              .getSingleOrNull();
      if (row == null) return '0';
      return '${row.opsJson.length}.${row.opsJson.hashCode}';
    } catch (_) {
      return '0';
    }
  }

  /// Borra la foto de un negocio.
  Future<void> clear(String businessId) async {
    await (_db.delete(
      _db.hubBaseline,
    )..where((t) => t.businessId.equals(businessId))).go();
  }

  // ─────────────────────────────────────────────────────────────────────
  // Construcción de la foto
  // ─────────────────────────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> _buildOps(String businessId) async {
    // 1) Sesiones de mesa abiertas → mesa por sesión.
    final sessions = await _client
        .from('table_sessions')
        .select('id, table_id')
        .eq('business_id', businessId)
        .isFilter('closed_at', null);

    final tableBySession = <String, String>{};
    for (final row in (sessions as List).cast<Map<String, dynamic>>()) {
      final sessionId = row['id']?.toString();
      final tableId = row['table_id']?.toString();
      if (sessionId == null || tableId == null || tableId.isEmpty) continue;
      tableBySession[sessionId] = tableId;
    }
    if (tableBySession.isEmpty) return const [];

    // 2) Órdenes vivas de esas sesiones.
    final orderRows = <Map<String, dynamic>>[];
    for (final chunk in _chunks(tableBySession.keys.toList())) {
      final rows = await _client
          .from('orders')
          .select('id, session_id, status_ext')
          .inFilter('session_id', chunk)
          .inFilter('status_ext', [
            'open',
            'sent_to_kitchen',
            'partially_paid',
          ]);
      orderRows.addAll((rows as List).cast<Map<String, dynamic>>());
    }
    if (orderRows.isEmpty) return const [];

    final tableByOrder = <String, String>{};
    for (final row in orderRows) {
      final orderId = row['id']?.toString();
      final sessionId = row['session_id']?.toString();
      if (orderId == null || sessionId == null) continue;
      final tableId = tableBySession[sessionId];
      if (tableId == null) continue;
      tableByOrder[orderId] = tableId;
    }
    if (tableByOrder.isEmpty) return const [];

    // 3) Ítems vivos de esas órdenes.
    final itemRows = <Map<String, dynamic>>[];
    for (final chunk in _chunks(tableByOrder.keys.toList())) {
      final rows = await _client
          .from('order_items')
          .select(
            'id, order_id, product_name, qty, quantity, unit_price, '
            'check_id, is_takeout, notes, status, created_at, '
            'started_at, ready_at',
          )
          .inFilter('order_id', chunk)
          .inFilter('status', _liveItemStatuses);
      itemRows.addAll((rows as List).cast<Map<String, dynamic>>());
    }

    // 4) A ops sintéticas: primero abrir cada mesa, después sus ítems.
    final ops = <Map<String, dynamic>>[];
    for (final entry in tableByOrder.entries) {
      ops.add({
        'type': 'open_table',
        'order_id': entry.key,
        'table_id': entry.value,
        'baseline': true,
      });
    }
    // `hub_received_at` lleva la fecha REAL de la BD, no la de la captura: los
    // dos proyectores la usan como reloj (`_stamp`), y sin ella una comanda que
    // lleva 20 minutos en cocina aparecería recién llegada.
    final firstItemAt = <String, String>{};
    for (final item in itemRows) {
      final orderId = item['order_id']?.toString();
      final itemId = item['id']?.toString();
      if (orderId == null || itemId == null) continue;
      final tableId = tableByOrder[orderId];
      if (tableId == null) continue;

      final createdAt = item['created_at']?.toString();
      if (createdAt != null) {
        final prev = firstItemAt[orderId];
        if (prev == null || createdAt.compareTo(prev) < 0) {
          firstItemAt[orderId] = createdAt;
        }
      }

      ops.add({
        'type': 'add_item',
        'order_id': orderId,
        'table_id': tableId,
        'item_id': itemId,
        'product_name': item['product_name']?.toString() ?? 'Producto',
        'qty': (item['qty'] as num?) ?? (item['quantity'] as num?) ?? 1,
        'unit_price': (item['unit_price'] as num?) ?? 0,
        // El proyector agrupa subcuentas por `check_pos`; en la BD la columna
        // es `check_id`.
        'check_pos': item['check_id']?.toString(),
        'notes': item['notes']?.toString(),
        'is_takeout': item['is_takeout'] == true,
        if (createdAt != null) 'hub_received_at': createdAt,
        'baseline': true,
      });
    }

    // El proyector de cocina SOLO muestra órdenes con `sent = true`
    // (hub_kitchen_projector.dart:136). Sin este op, las comandas que ya
    // estaban en la cocina antes del corte no aparecían en el KDS — el
    // "LÍMITE (baseline)" documentado en ese archivo.
    //
    // Todo ítem de la foto ya pasó por cocina: los `draft` se filtraron en la
    // consulta, y draft es justamente "tecleado pero no enviado".
    for (final orderId in firstItemAt.keys) {
      ops.add({
        'type': 'send_to_kitchen',
        'order_id': orderId,
        'table_id': tableByOrder[orderId],
        'hub_received_at': firstItemAt[orderId],
        'baseline': true,
      });
    }

    // Estado real de cada ítem en cocina. Sin esto todos nacerían `pending` y
    // el KDS perdería en qué va cada uno. Los `served` se emiten a propósito:
    // el proyector los usa para SACARLOS de la pantalla, que es lo correcto —
    // en la cuenta siguen (por eso arriba sí van como `add_item`).
    for (final item in itemRows) {
      final status = item['status']?.toString();
      if (status == null || status == 'pending') continue;
      final orderId = item['order_id']?.toString();
      final itemId = item['id']?.toString();
      if (orderId == null || itemId == null) continue;
      if (!tableByOrder.containsKey(orderId)) continue;
      ops.add({
        'type': 'kds_item_status',
        'order_id': orderId,
        'item_id': itemId,
        'status': status,
        'hub_received_at':
            (status == 'ready' ? item['ready_at'] : item['started_at'])
                ?.toString(),
        'baseline': true,
      });
    }

    return assignBaselineSeq(ops);
  }

  /// Numera las ops de la foto con `seq` NEGATIVO, conservando su orden.
  ///
  /// El proyector pliega ordenando por `seq` (hub_order_projector.dart:88), y
  /// el op-log real numera desde 1. Si el baseline usara 1..N las dos series se
  /// intercalarían y un `delete_item` hecho offline podría aplicarse ANTES del
  /// `add_item` de la foto que pretende borrar. Con negativos, la foto siempre
  /// queda completa por debajo y lo que pasó offline se apila encima.
  @visibleForTesting
  static List<Map<String, dynamic>> assignBaselineSeq(
    List<Map<String, dynamic>> ops,
  ) {
    final total = ops.length;
    for (var i = 0; i < total; i++) {
      ops[i]['seq'] = i - total; // -total … -1
    }
    return ops;
  }

  Iterable<List<String>> _chunks(List<String> ids) sync* {
    for (var i = 0; i < ids.length; i += _inFilterBatch) {
      yield ids.sublist(
        i,
        i + _inFilterBatch > ids.length ? ids.length : i + _inFilterBatch,
      );
    }
  }
}
