import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import '../../storage/storage_service.dart';
import 'hub_state_db.dart';

/// Implementación SQLite del op-log del Hub. Misma semántica exacta que la
/// versión de SharedPreferences que reemplaza — `seq` monotónico y contiguo por
/// negocio, `append` idempotente por `op_id`, `since` como delta ordenado — pero
/// sin reescribir el log entero en cada escritura.
///
/// Lo que cambia bajo el capó:
///   - `append`: antes leía todo el array, lo escaneaba linealmente buscando el
///     `op_id` y volvía a serializarlo completo. Ahora es un INSERT con un
///     índice único haciendo la deduplicación.
///   - `since`: antes parseaba el log completo y filtraba en memoria. Ahora es
///     un rango indexado.
///   - `retainOrders`: antes reescribía el array con los sobrevivientes. Ahora
///     es un DELETE.
class HubOpLogDao {
  HubOpLogDao(this._db);

  final HubStateDb _db;

  /// Negocios cuya cola legacy ya se revisó en esta sesión, para no consultar
  /// SharedPreferences en cada llamada.
  final Set<String> _migrated = <String>{};

  String _legacyKey(String businessId) => 'hub_oplog_$businessId';

  /// Importa el op-log legacy de SharedPreferences la primera vez que se toca
  /// un negocio, y borra la llave vieja. Idempotente y best-effort: si algo
  /// falla, la llave legacy se queda donde está (no se pierde nada) y se
  /// reintenta en el próximo arranque.
  ///
  /// Es el mismo patrón que ya usó la cola offline al migrarse a drift.
  Future<void> _migrateLegacyIfNeeded(String businessId) async {
    if (_migrated.contains(businessId)) return;
    _migrated.add(businessId);

    try {
      final storage = await StorageService.getInstance();
      final raw = await storage.readList(_legacyKey(businessId));
      if (raw == null || raw.isEmpty) return;

      final legacy = raw
          .whereType<Object?>()
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList(growable: false)
        ..sort((a, b) => _seqOf(a).compareTo(_seqOf(b)));

      // Solo importamos si el negocio aún no tiene nada en SQLite. Si ya tiene,
      // la migración corrió antes y esta llave es un residuo.
      // Se consulta `_maxLiveSeq` y no `currentSeq` a propósito: `currentSeq`
      // vuelve a entrar aquí, y aunque el guard de `_migrated` corta el ciclo,
      // depender de eso sería frágil.
      final existing = await _maxLiveSeq(businessId);
      if (existing == 0) {
        await _db.batch((b) {
          for (final op in legacy) {
            final seq = _seqOf(op);
            if (seq <= 0) continue;
            b.insert(
              _db.hubOps,
              HubOpsCompanion.insert(
                businessId: businessId,
                seq: seq,
                opId: Value(_opIdOf(op)),
                orderId: Value(_orderIdOf(op)),
                payloadJson: jsonEncode(op),
                receivedAt: _receivedAtOf(op),
              ),
              mode: InsertMode.insertOrIgnore,
            );
          }
        });
      }

      await storage.delete(_legacyKey(businessId));
      debugPrint(
        '[HubOpLogDao] op-log legacy de $businessId migrado a SQLite '
        '(${legacy.length} ops).',
      );
    } catch (e) {
      // Deliberadamente no relanzamos: perder el Hub por un problema de
      // migración sería peor que arrastrar la llave legacy un rato más.
      debugPrint('[HubOpLogDao] migración legacy de $businessId falló: $e');
    }
  }

  static int _seqOf(Map<String, dynamic> op) =>
      (op['seq'] as num?)?.toInt() ?? 0;

  static String? _opIdOf(Map<String, dynamic> op) {
    final id = op['op_id']?.toString() ?? op['id']?.toString();
    return (id == null || id.isEmpty) ? null : id;
  }

  static String? _orderIdOf(Map<String, dynamic> op) {
    final id = op['order_id']?.toString();
    return (id == null || id.isEmpty) ? null : id;
  }

  static DateTime _receivedAtOf(Map<String, dynamic> op) {
    final raw = op['hub_received_at']?.toString();
    return DateTime.tryParse(raw ?? '')?.toUtc() ?? DateTime.now().toUtc();
  }

  /// Agrega una op y devuelve su `seq`. Idempotente por `op_id`: si ya existe,
  /// devuelve el `seq` que se le asignó antes sin insertar de nuevo.
  ///
  /// Todo dentro de una transacción: leer el MAX y luego insertar serían dos
  /// pasos con una carrera entre ellos, y dos cajas mandando al Hub a la vez es
  /// exactamente el caso normal.
  Future<int> append(String businessId, Map<String, dynamic> op) async {
    await _migrateLegacyIfNeeded(businessId);

    final opId = _opIdOf(op);

    return _db.transaction(() async {
      if (opId != null) {
        final existing = await (_db.select(_db.hubOps)
              ..where((t) => t.businessId.equals(businessId))
              ..where((t) => t.opId.equals(opId))
              ..limit(1))
            .getSingleOrNull();
        if (existing != null) return existing.seq;
      }

      final nextSeq = await _nextSeq(businessId);

      final entry = <String, dynamic>{
        ...op,
        'seq': nextSeq,
        if (opId != null) 'op_id': opId,
      };
      final receivedAt = DateTime.now().toUtc();
      entry['hub_received_at'] ??= receivedAt.toIso8601String();

      await _db.into(_db.hubOps).insert(
            HubOpsCompanion.insert(
              businessId: businessId,
              seq: nextSeq,
              opId: Value(opId),
              orderId: Value(_orderIdOf(entry)),
              payloadJson: jsonEncode(entry),
              receivedAt: _receivedAtOf(entry),
            ),
          );
      return nextSeq;
    });
  }

  /// `seq` más alto de las filas VIVAS. Solo sirve para la migración legacy y
  /// como piso de la marca de agua; NO para numerar (ver [_nextSeq]).
  Future<int> _maxLiveSeq(String businessId) async {
    final max = _db.hubOps.seq.max();
    final row = await (_db.selectOnly(_db.hubOps)
          ..addColumns([max])
          ..where(_db.hubOps.businessId.equals(businessId)))
        .getSingle();
    return row.read(max) ?? 0;
  }

  /// Marca de agua persistida: el último `seq` ENTREGADO, aunque su fila ya se
  /// haya podado.
  Future<int> _watermark(String businessId) async {
    final row = await (_db.select(_db.hubMeta)
          ..where((t) => t.businessId.equals(businessId))
          ..limit(1))
        .getSingleOrNull();
    return row?.lastSeq ?? 0;
  }

  /// Reserva y persiste el siguiente `seq`. Se llama SIEMPRE dentro de la
  /// transacción de [append].
  ///
  /// El piso es el máximo entre la marca de agua y el `seq` más alto vivo: lo
  /// segundo cubre el estado importado desde el op-log legacy, que llega con
  /// sus `seq` ya asignados y sin marca de agua.
  Future<int> _nextSeq(String businessId) async {
    final floor = await _watermark(businessId);
    final live = await _maxLiveSeq(businessId);
    final next = (floor > live ? floor : live) + 1;
    await _db.into(_db.hubMeta).insertOnConflictUpdate(
          HubMetaRow(businessId: businessId, lastSeq: next),
        );
    return next;
  }

  /// Ops con `seq` > [seq], en orden ascendente. Con `seq = 0` (default),
  /// el log completo.
  Future<List<Map<String, dynamic>>> since(
    String businessId, {
    int seq = 0,
  }) async {
    await _migrateLegacyIfNeeded(businessId);
    final rows = await (_db.select(_db.hubOps)
          ..where((t) => t.businessId.equals(businessId))
          ..where((t) => t.seq.isBiggerThanValue(seq))
          ..orderBy([(t) => OrderingTerm.asc(t.seq)]))
        .get();
    return rows.map(_decode).whereType<Map<String, dynamic>>().toList();
  }

  Map<String, dynamic>? _decode(HubOpRow row) {
    try {
      final decoded = jsonDecode(row.payloadJson);
      if (decoded is! Map) return null;
      return Map<String, dynamic>.from(decoded);
    } catch (e) {
      debugPrint('[HubOpLogDao] op ${row.seq} ilegible, se omite: $e');
      return null;
    }
  }

  /// Último `seq` asignado (0 si nunca se asignó ninguno).
  ///
  /// Es la marca de agua, NO el máximo de las filas vivas: los clientes anotan
  /// este número como "ya estoy al día hasta acá", así que después de una poda
  /// no puede retroceder o volverían a pedir un rango que ya consumieron.
  Future<int> currentSeq(String businessId) async {
    await _migrateLegacyIfNeeded(businessId);
    final mark = await _watermark(businessId);
    final live = await _maxLiveSeq(businessId);
    return mark > live ? mark : live;
  }

  /// Cantidad de ops en el log.
  Future<int> length(String businessId) async {
    await _migrateLegacyIfNeeded(businessId);
    final count = _db.hubOps.seq.count();
    final row = await (_db.selectOnly(_db.hubOps)
          ..addColumns([count])
          ..where(_db.hubOps.businessId.equals(businessId)))
        .getSingle();
    return row.read(count) ?? 0;
  }

  /// Vacía el op-log de un negocio. Se llama tras un uplink exitoso.
  Future<void> clear(String businessId) async {
    _migrated.add(businessId); // ya no hay nada legacy que valga la pena traer
    await (_db.delete(_db.hubOps)
          ..where((t) => t.businessId.equals(businessId)))
        .go();
    try {
      final storage = await StorageService.getInstance();
      await storage.delete(_legacyKey(businessId));
    } catch (_) {/* residuo legacy, no crítico */}
  }

  /// Poda tras un uplink exitoso: conserva SOLO las ops cuyo `order_id` está en
  /// [keepOrderIds] (las mesas AÚN ABIERTAS que las cajas siguen proyectando por
  /// `/hub/salon`). Borra el resto — órdenes ya cerradas o anuladas, y ops sin
  /// `order_id` (caja, inventario) que ya subieron. Devuelve cuántas quedaron.
  Future<int> retainOrders(
    String businessId,
    Set<String> keepOrderIds,
  ) async {
    await _migrateLegacyIfNeeded(businessId);

    if (keepOrderIds.isEmpty) {
      await clear(businessId);
      return 0;
    }

    await (_db.delete(_db.hubOps)
          ..where((t) => t.businessId.equals(businessId))
          ..where((t) => t.orderId.isNull() | t.orderId.isNotIn(keepOrderIds)))
        .go();

    return length(businessId);
  }
}
