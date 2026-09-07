import 'dart:async';

import 'package:flutter/foundation.dart';

import 'hub_baseline_service.dart';
import 'hub_op_log.dart';
import 'hub_order_projector.dart';

/// Memoiza la lectura y la proyección del op-log del Hub (paso 5b).
///
/// El problema que resuelve: cada op que el Hub difunde por WebSocket dispara
/// un `loadZoneStatus` en TODAS las cajas conectadas, y cada una pide
/// `GET /hub/salon`. Los cinco consumidores del op-log (`/hub/salon`,
/// `/hub/order`, `localHubSalon`, `localHubOrder`, `getLocalHubOps`) hacían
/// cada uno un `since(seq: 0)` — traer TODAS las filas, decodificar el JSON de
/// cada una y plegar el log entero. Con N cajas eso son N lecturas completas y
/// N proyecciones **por cada op**: el trabajo crece con el cuadrado del
/// servicio.
///
/// Qué hace: guarda las ops decodificadas y el salón ya proyectado, con la
/// *revisión* del log como llave. Mientras nadie escriba, todas las peticiones
/// se sirven de memoria. Cuando llega una op, se recalcula UNA vez y las N
/// cajas que preguntan después comparten ese resultado.
///
/// Deliberadamente NO materializa `hub_orders`/`hub_order_items`/`hub_tables`
/// aplicando cada op incrementalmente, que era el diseño original. Eso
/// obligaría a reimplementar las ~318 líneas de semántica de
/// [HubOrderProjector] (open_table, move_item_to_check, cobro por subcuenta vs
/// full-order, void…) como actualizaciones incrementales, con dos copias de
/// esas reglas que pueden divergir en silencio — y sin hardware multi-caja
/// para detectarlo. Memoizar reusa el proyector YA probado y captura la parte
/// grande del costo (las N lecturas por op se vuelven una). Materializar de
/// verdad queda como paso posterior, si el perfil en hardware lo pide.
class HubProjectionCache {
  HubProjectionCache({HubOpLog? log, HubBaselineService? baseline})
      : _log = log ?? HubOpLog(),
        _baseline = baseline ?? HubBaselineService();

  /// Instancia compartida: si cada consumidor tuviera la suya, no se
  /// aprovecharían entre ellos y volveríamos a N cálculos por op.
  static HubProjectionCache instance = HubProjectionCache();

  /// Para tests.
  @visibleForTesting
  static void resetInstance({HubOpLog? log, HubBaselineService? baseline}) {
    instance = HubProjectionCache(log: log, baseline: baseline);
  }

  final HubOpLog _log;
  final HubBaselineService _baseline;
  final Map<String, _Entry> _entries = <String, _Entry>{};
  final Map<String, Future<_Entry>> _inFlight = <String, Future<_Entry>>{};

  /// Ops del negocio, decodificadas y en orden de `seq`.
  Future<List<Map<String, dynamic>>> ops(String businessId) async {
    final entry = await _entryFor(businessId);
    return entry.ops;
  }

  /// Salón proyectado, en el mismo shape que devuelve `/hub/salon`.
  Future<List<Map<String, dynamic>>> salon(String businessId) async {
    final entry = await _entryFor(businessId);
    return entry.salon ??= HubOrderProjector.projectSalon(entry.ops)
        .map((t) => t.toJson())
        .toList(growable: false);
  }

  /// Descarta lo memoizado de un negocio. No hace falta llamarlo en el flujo
  /// normal —la revisión detecta sola los cambios—, pero sirve para tests y
  /// para forzar una relectura tras una operación fuera de banda.
  void invalidate(String businessId) {
    _entries.remove(businessId);
    _inFlight.remove(businessId);
  }

  /// Devuelve la entrada vigente, recalculándola solo si el log cambió.
  ///
  /// El `_inFlight` es la mitad importante: sin él, las N cajas que preguntan
  /// justo después de una op entrarían todas a recalcular a la vez y no
  /// habríamos ganado nada. Con él, la primera calcula y las demás esperan ese
  /// mismo future.
  Future<_Entry> _entryFor(String businessId) async {
    final revision = await _revisionOf(businessId);

    final cached = _entries[businessId];
    if (cached != null && cached.revision == revision) return cached;

    final pending = _inFlight[businessId];
    if (pending != null) {
      final entry = await pending;
      // Si mientras esperábamos entró otra op, el resultado ya nació viejo;
      // se reintenta con la revisión nueva.
      if (entry.revision == revision) return entry;
      return _entryFor(businessId);
    }

    final future = _rebuild(businessId, revision);
    _inFlight[businessId] = future;
    try {
      final entry = await future;
      _entries[businessId] = entry;
      return entry;
    } finally {
      _inFlight.remove(businessId);
    }
  }

  /// La foto del baseline se pliega ANTES del op-log (sus `seq` son negativos),
  /// para que las mesas que ya estaban abiertas cuando se cayó internet existan
  /// y lo que se hizo offline se apile encima. Ver [HubBaselineService].
  Future<_Entry> _rebuild(String businessId, String revision) async {
    final baseline = await _baseline.ops(businessId);
    final logOps = await _log.since(businessId, seq: 0);
    return _Entry(
      revision: revision,
      ops: baseline.isEmpty ? logOps : [...baseline, ...logOps],
    );
  }

  /// Huella barata del estado del log: dos consultas indexadas, contra traer y
  /// decodificar todas las filas.
  ///
  /// Van las DOS porque ninguna sola alcanza: `currentSeq` es una marca de agua
  /// que NO retrocede, así que una poda (`retainOrders`) no la mueve y dejaría
  /// servir un salón con mesas ya cerradas; y `length` sola no distingue un
  /// append seguido de una poda de una sola op.
  Future<String> _revisionOf(String businessId) async {
    final seq = await _log.currentSeq(businessId);
    final length = await _log.length(businessId);
    // Una foto nueva del baseline también invalida: al reconectar se recaptura
    // y el salón tiene que reflejar lo que el server ya sabe. Va por CONTENIDO
    // y no por `capturedAt` — drift guarda las fechas con resolución de
    // segundos, así que dos capturas del mismo segundo serían indistinguibles.
    final baselineRev = await _baseline.revision(businessId);
    return '$seq:$length:$baselineRev';
  }
}

class _Entry {
  _Entry({required this.revision, required this.ops});

  final String revision;
  final List<Map<String, dynamic>> ops;

  /// Se calcula la primera vez que alguien pide el salón, no al construir:
  /// `getLocalHubOps` (el KDS) solo necesita las ops.
  List<Map<String, dynamic>>? salon;
}
