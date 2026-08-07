// DAO de la cola offline.
//
// Expone una API "lookup-shape" con List<Map<String,dynamic>> idéntica a
// la que usa offline_pos_service hoy con SharedPreferences. Internamente
// usa drift/sqlite. Esto deja el resto del sync logic (compactación,
// retry, fingerprint dedup) sin cambios — solo cambia el backend.
//
// Fase 6 — alcance acotado: cola + completed_ops + fingerprints. El
// resto del cache (snapshots, mappings, catalog, inventory) se queda
// en SharedPreferences porque son writes pequeños/infrecuentes.

import 'dart:convert';

import 'package:drift/drift.dart';

import '../../security/secure_blob_cipher.dart';
import 'offline_queue_db.dart';

class OfflineQueueDao {
  OfflineQueueDao(this._db, {SecureBlobCipher? cipher})
      : _cipher = cipher ?? SecureBlobCipher.instance;

  final OfflineQueueDb _db;

  /// Cifra/descifra el `payloadJson` (datos sensibles de la op: montos, RNC,
  /// productos, notas) a nivel de columna con AES-GCM (G9b). Las columnas
  /// estructuradas (id, tipo, estado, timestamps) quedan en claro para poder
  /// consultarlas. La BD sigue siendo sqlite plano — sin SQLCipher.
  ///
  /// Se sella con `sealDurable` (no `seal`): el cuerpo de la op tiene que
  /// sobrevivir al reinicio para que el replay pueda reproducir la venta. Si
  /// el Keychain no está disponible y la clave de sesión es efímera, el
  /// cipher guarda en claro antes que dejar la operación ilegible para
  /// siempre — ver [SecureBlobCipher.sealDurable].
  final SecureBlobCipher _cipher;

  /// Lee toda la cola de un business en orden cronológico (FIFO).
  /// Reemplaza `storage.readList(offline_queue_{businessId})`.
  Future<List<Map<String, dynamic>>> readQueue(String businessId) async {
    final query = _db.select(_db.queueActions)
      ..where((t) => t.businessId.equals(businessId))
      ..orderBy([(t) => OrderingTerm(expression: t.queuedAt)]);
    final rows = await query.get();
    return Future.wait(rows.map(_rowToActionMap));
  }

  /// Reemplaza la cola completa (transacción atómica DELETE + INSERT).
  /// Reemplaza `storage.writeList(offline_queue_{businessId}, list)`.
  /// La semántica espejo del SP write es: la lista nueva es la verdad
  /// completa. Cualquier fila previa para ese business que no esté en
  /// `actions` se borra.
  /// UPSERT puntual de una sola action por id. Usado por el loop de
  /// sync para no reescribir la lista completa (O(n²)) en cada paso
  /// del replay. `writeQueue` se usa solo en enqueue/prune donde la
  /// reescritura completa es necesaria para mantener orden tras
  /// compactación.
  Future<void> upsertAction(
    String businessId,
    Map<String, dynamic> action,
  ) async {
    final id = action['id']?.toString();
    if (id == null || id.isEmpty) return;
    await _db.into(_db.queueActions).insertOnConflictUpdate(
          await _actionMapToCompanion(businessId, action),
        );
  }

  /// Borra TODAS las acciones de la cola de este business (pendientes y
  /// failed). NO toca completed_ops/fingerprints — esos son marcadores
  /// para evitar replay de acciones que ya se aplicaron en server. Usado
  /// por el boton "Limpiar cola" cuando el cajero quiere descartar
  /// operaciones bloqueadas por bugs anteriores o conflictos irresolubles.
  /// Devuelve cuantas filas se borraron.
  Future<int> deleteAllPending(String businessId) async {
    final deleted = await (_db.delete(_db.queueActions)
          ..where((t) => t.businessId.equals(businessId)))
        .go();
    return deleted;
  }

  /// Borra SOLO las acciones ya `completed` de este business, conservando las
  /// NO sincronizadas (pending/processing/failed/dead). Se usa en logout para
  /// no perder operaciones offline sin subir. Devuelve cuántas se borraron.
  Future<int> deleteCompletedActions(String businessId) async {
    final deleted = await (_db.delete(_db.queueActions)
          ..where((t) =>
              t.businessId.equals(businessId) & t.status.equals('completed')))
        .go();
    return deleted;
  }

  Future<void> writeQueue(
    String businessId,
    List<Map<String, dynamic>> actions,
  ) async {
    // Guard: si una action llega sin id (bug río arriba en
    // _normalizeAction), no la insertamos. Sin esto dos actions
    // sin-id chocarían en la PK string vacía y la segunda sobrescribe
    // a la primera silenciosamente.
    final safeActions = actions
        .where((a) => (a['id']?.toString() ?? '').isNotEmpty)
        .toList(growable: false);
    await _db.transaction(() async {
      await (_db.delete(_db.queueActions)
            ..where((t) => t.businessId.equals(businessId)))
          .go();
      for (final action in safeActions) {
        await _db.into(_db.queueActions).insertOnConflictUpdate(
              await _actionMapToCompanion(businessId, action),
            );
      }
    });
  }

  /// Set de op_ids completados para un business. Usado por
  /// `_isCompleted` y el guard de re-enqueue en sync.
  Future<Set<String>> readCompletedOps(String businessId) async {
    final query = _db.select(_db.completedOps)
      ..where((t) => t.businessId.equals(businessId));
    final rows = await query.get();
    return rows.map((r) => r.opId).toSet();
  }

  Future<void> markOpCompleted({
    required String businessId,
    required String opId,
  }) async {
    await _db.into(_db.completedOps).insertOnConflictUpdate(
          CompletedOpsCompanion.insert(
            opId: opId,
            businessId: businessId,
            completedAt: DateTime.now(),
          ),
        );
  }

  Future<Set<String>> readCompletedFingerprints(String businessId) async {
    final query = _db.select(_db.completedFingerprints)
      ..where((t) => t.businessId.equals(businessId));
    final rows = await query.get();
    return rows.map((r) => r.fingerprint).toSet();
  }

  Future<void> markFingerprintCompleted({
    required String businessId,
    required String fingerprint,
  }) async {
    await _db.into(_db.completedFingerprints).insertOnConflictUpdate(
          CompletedFingerprintsCompanion.insert(
            fingerprint: fingerprint,
            businessId: businessId,
            completedAt: DateTime.now(),
          ),
        );
  }

  /// Borra registros de completed_ops y completed_fingerprints más
  /// viejos que [olderThan]. Mantiene la tabla acotada — sin esto crece
  /// para siempre. Llamada como nice-to-have al final de cada sync.
  Future<void> pruneCompletedOlderThan(Duration olderThan) async {
    final cutoff = DateTime.now().subtract(olderThan);
    await _db.transaction(() async {
      await (_db.delete(_db.completedOps)
            ..where((t) => t.completedAt.isSmallerThanValue(cutoff)))
          .go();
      await (_db.delete(_db.completedFingerprints)
            ..where((t) => t.completedAt.isSmallerThanValue(cutoff)))
          .go();
    });
  }

  // ---------------------------------------------------------------------
  // Row ↔ Map conversion.
  //
  // El payload original es Map<String,dynamic> con un montón de keys
  // específicas por tipo de action (order_id, item_id, paid_at, etc.).
  // Las columnas tipadas (id, business_id, type, status, attempts,
  // queued_at, completed_at, fingerprint, last_error, next_retry_at,
  // processing_started_at) se extraen como columnas SQL para query;
  // el resto del payload va en `payload_json` como bag of properties.
  //
  // Al leer reconstruimos el Map original mezclando ambos lados — el
  // shape resultante es idéntico al que producía StorageService.readList.
  // ---------------------------------------------------------------------

  static const Set<String> _structuredKeys = {
    'id',
    'business_id',
    'type',
    'status',
    'attempts',
    'queued_at',
    'completed_at',
    'fingerprint',
    'last_error',
    'next_retry_at',
    'processing_started_at',
  };

  Future<Map<String, dynamic>> _rowToActionMap(QueueActionRow row) async {
    // Descifra el payload (tolera filas legacy en texto plano vía
    // SecureBlobCipher.open). Si el descifrado falla, tratamos los extras
    // como vacíos — las columnas estructuradas igual reconstruyen la op.
    final plain = await _cipher.open(row.payloadJson) ?? '{}';
    final extras = (jsonDecode(plain) as Map?) ?? const {};
    final merged = <String, dynamic>{
      ...Map<String, dynamic>.from(extras),
      'id': row.id,
      'type': row.type,
      'status': row.status,
      'attempts': row.attempts,
      'queued_at': row.queuedAt.toIso8601String(),
      if (row.fingerprint != null) 'fingerprint': row.fingerprint,
      if (row.completedAt != null)
        'completed_at': row.completedAt!.toIso8601String(),
      if (row.lastError != null) 'last_error': row.lastError,
      if (row.nextRetryAt != null)
        'next_retry_at': row.nextRetryAt!.toIso8601String(),
      if (row.processingStartedAt != null)
        'processing_started_at': row.processingStartedAt!.toIso8601String(),
    };
    return merged;
  }

  Future<QueueActionsCompanion> _actionMapToCompanion(
    String businessId,
    Map<String, dynamic> action,
  ) async {
    final payloadExtras = <String, dynamic>{};
    for (final entry in action.entries) {
      if (_structuredKeys.contains(entry.key)) continue;
      payloadExtras[entry.key] = entry.value;
    }
    return QueueActionsCompanion.insert(
      id: action['id']?.toString() ?? '',
      businessId: businessId,
      type: action['type']?.toString() ?? 'unknown',
      payloadJson: await _cipher.sealDurable(jsonEncode(payloadExtras)),
      status: Value(action['status']?.toString() ?? 'pending'),
      attempts:
          Value((action['attempts'] as num?)?.toInt() ?? 0),
      queuedAt: _parseDate(action['queued_at']) ?? DateTime.now(),
      completedAt: Value(_parseDate(action['completed_at'])),
      fingerprint: Value(action['fingerprint']?.toString()),
      lastError: Value(action['last_error']?.toString()),
      nextRetryAt: Value(_parseDate(action['next_retry_at'])),
      processingStartedAt: Value(_parseDate(action['processing_started_at'])),
    );
  }

  DateTime? _parseDate(dynamic value) {
    if (value == null) return null;
    if (value is DateTime) return value;
    final raw = value.toString();
    if (raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }
}
