import 'package:flutter/foundation.dart';

import '../../storage/storage_service.dart';
import 'hub_op_log_dao.dart';
import 'hub_state_db.dart';

/// Op-log del Hub Local (F3b): el registro append-only, ordenado y
/// deduplicado de operaciones que el Hub recibe de los terminales mientras
/// el local está sin internet.
///
/// Es el corazón de F3:
///   - Asigna un `seq` monotónico a cada op → orden total del local (la
///     consistencia multi-terminal sale de aquí: el Hub serializa).
///   - Idempotente por `op_id` → si un terminal reenvía la misma op (retry,
///     crash), no se duplica; devuelve el `seq` ya asignado.
///   - `since(seq)` devuelve el delta → los terminales (y el KDS) se ponen
///     al día y reconstruyen su vista con la MISMA lógica de acciones que ya
///     usa la app (el Hub no necesita un reducer propio en esta fase).
///   - Es además la cola de uplink: al reconectar, el Hub replaya este log a
///     Supabase con la idempotencia ya existente (op_id/fingerprint).
///
/// **Persistencia (v2): SQLite/drift en nativo** ([HubOpLogDao]), con migración
/// automática desde el formato viejo. La v1 guardaba el log como un array JSON
/// en [StorageService] y cada `append` reescribía el archivo ENTERO tras
/// escanearlo linealmente buscando el `op_id` — siendo el único camino de
/// escritura de todas las cajas del local, eso no escalaba a una noche de
/// servicio y un crash a mitad de escritura podía truncar todo lo no subido.
///
/// En **web** se mantiene el backend de SharedPreferences: drift ahí necesita
/// WASM y setup aparte, y el modo Hub no se recomienda en navegador.
///
/// Esta clase es un facade: la API pública no cambió, así que ni
/// `mobile_print_agent` ni `OfflinePosService` se enteraron del cambio.
class HubOpLog {
  /// [storage] fuerza el backend de SharedPreferences (tests y web).
  /// [dao] inyecta un backend SQLite propio (tests con BD en memoria).
  HubOpLog({StorageService? storage, HubOpLogDao? dao})
      : _injectedStorage = storage,
        _injectedDao = dao;

  final StorageService? _injectedStorage;
  final HubOpLogDao? _injectedDao;

  /// SQLite salvo que nos hayan pasado un `storage` explícito o estemos en web.
  bool get _useSqlite {
    if (_injectedDao != null) return true;
    if (_injectedStorage != null) return false;
    return !kIsWeb;
  }

  HubOpLogDao? _daoCache;
  HubOpLogDao get _dao =>
      _injectedDao ?? (_daoCache ??= HubOpLogDao(HubStateDb.getInstance()));

  Future<StorageService> get _storage async =>
      _injectedStorage ?? await StorageService.getInstance();

  String _key(String businessId) => 'hub_oplog_$businessId';

  /// Agrega una op al log y devuelve su `seq`. Idempotente: si ya existe una
  /// op con el mismo `op_id`, NO se vuelve a agregar y se devuelve su `seq`
  /// previo. La op se enriquece con `seq` y `hub_received_at`.
  Future<int> append(String businessId, Map<String, dynamic> op) async {
    if (_useSqlite) return _dao.append(businessId, op);

    final storage = await _storage;
    final log = await _readLog(businessId);

    final opId = op['op_id']?.toString() ?? op['id']?.toString();
    if (opId != null && opId.isNotEmpty) {
      for (final existing in log) {
        final existingId =
            existing['op_id']?.toString() ?? existing['id']?.toString();
        if (existingId == opId) {
          return (existing['seq'] as num?)?.toInt() ?? 0;
        }
      }
    }

    final nextSeq = _maxSeq(log) + 1;
    final entry = <String, dynamic>{
      ...op,
      'seq': nextSeq,
      if (opId != null) 'op_id': opId,
    };
    entry['hub_received_at'] ??= DateTime.now().toUtc().toIso8601String();
    log.add(entry);
    await storage.writeList(_key(businessId), log);
    return nextSeq;
  }

  /// Guarda una op REPLICADA del Hub primario conservando su `seq`.
  /// Solo disponible con el backend SQLite; en web es no-op.
  Future<bool> appendReplica(String businessId, Map<String, dynamic> op) async {
    if (!_useSqlite) return false;
    return _dao.appendReplica(businessId, op);
  }

  /// Devuelve las ops con `seq` > [seq], en orden ascendente. Con `seq = 0`
  /// (default) devuelve el log completo.
  Future<List<Map<String, dynamic>>> since(
    String businessId, {
    int seq = 0,
  }) async {
    if (_useSqlite) return _dao.since(businessId, seq: seq);

    final log = await _readLog(businessId);
    final delta = log
        .where((e) => ((e['seq'] as num?)?.toInt() ?? 0) > seq)
        .toList(growable: false)
      ..sort((a, b) =>
          ((a['seq'] as num?)?.toInt() ?? 0).compareTo(
              (b['seq'] as num?)?.toInt() ?? 0));
    return delta;
  }

  /// Último `seq` asignado (0 si el log está vacío).
  Future<int> currentSeq(String businessId) async {
    if (_useSqlite) return _dao.currentSeq(businessId);
    final log = await _readLog(businessId);
    return _maxSeq(log);
  }

  /// Cantidad de ops en el log.
  Future<int> length(String businessId) async {
    if (_useSqlite) return _dao.length(businessId);
    final log = await _readLog(businessId);
    return log.length;
  }

  /// Vacía el op-log de un negocio. Se llama tras un uplink exitoso a
  /// Supabase (las ops ya viven en el server) — F3b-3.
  Future<void> clear(String businessId) async {
    if (_useSqlite) return _dao.clear(businessId);
    final storage = await _storage;
    await storage.write(_key(businessId), '[]');
  }

  /// Poda tras un uplink exitoso: conserva SOLO las ops cuyo `order_id` está en
  /// [keepOrderIds] (las mesas AÚN ABIERTAS que las cajas cliente siguen
  /// proyectando por `/hub/salon` y `/hub/order`). Elimina el resto —órdenes ya
  /// cerradas/anuladas y ops sin `order_id` (caja/inventario) ya subidas—. A
  /// diferencia de [clear], NO borra el estado vivo del salón. Devuelve cuántas
  /// ops quedaron.
  Future<int> retainOrders(String businessId, Set<String> keepOrderIds) async {
    if (_useSqlite) return _dao.retainOrders(businessId, keepOrderIds);

    final storage = await _storage;
    final log = await _readLog(businessId);
    final kept = log.where((e) {
      final oid = e['order_id']?.toString() ?? '';
      return oid.isNotEmpty && keepOrderIds.contains(oid);
    }).toList(growable: false);
    if (kept.length == log.length) return kept.length; // nada que podar
    await storage.writeList(_key(businessId), kept);
    return kept.length;
  }

  Future<List<Map<String, dynamic>>> _readLog(String businessId) async {
    final storage = await _storage;
    final raw = await storage.readList(_key(businessId)) ?? const [];
    return raw
        .whereType<Object?>()
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList(growable: true);
  }

  int _maxSeq(List<Map<String, dynamic>> log) {
    var max = 0;
    for (final e in log) {
      final s = (e['seq'] as num?)?.toInt() ?? 0;
      if (s > max) max = s;
    }
    return max;
  }
}

/// Cache opcional para debug.
@visibleForTesting
String debugHubOpLogKey(String businessId) => 'hub_oplog_$businessId';
