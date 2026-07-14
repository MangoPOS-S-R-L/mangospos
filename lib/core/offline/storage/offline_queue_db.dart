// Drift schema para la cola offline.
//
// Fase 6 — esto reemplaza tres lecturas/escrituras que antes vivían en
// SharedPreferences:
//   - `offline_queue_{businessId}`      → tabla queue_actions
//   - `offline_completed_ops_{businessId}`         → tabla completed_ops
//   - `offline_completed_fingerprints_{businessId}` → tabla completed_fps
//
// Motivación: la implementación basada en SP reescribía la lista JSON
// ENTERA en cada enqueue/sync. Con 500+ items eso es O(n) en disco por
// cada operación. Con sqlite cada INSERT/UPDATE es O(log n) indexado.
//
// El resto del cache (snapshots, mappings, catalog, inventory) se queda
// en SharedPreferences — son writes infrecuentes y chicos donde no vale
// la pena migrar.
//
// Web: drift en web requiere WASM y setup adicional. En MangoPOS web
// la cola cae a SharedPreferences vía guards `kIsWeb` en
// `OfflinePosService`. La conexión drift se resuelve vía conditional
// import (`_db_connection_io.dart` en nativo, `_db_connection_web.dart`
// stub en web) para que el código compile en ambas plataformas.
//
// Para regenerar el código: `flutter pub run build_runner build`.

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '_db_connection_io.dart'
    if (dart.library.html) '_db_connection_web.dart';

part 'offline_queue_db.g.dart';

/// Acciones encoladas para sincronización offline. Cada fila es una
/// operación atómica (add_item, process_payment, inventory_adjust,
/// open_cash_session, etc.) con su payload completo serializado.
@DataClassName('QueueActionRow')
class QueueActions extends Table {
  TextColumn get id => text()(); // uuid de la op
  TextColumn get businessId => text()();
  TextColumn get type => text()();
  TextColumn get payloadJson => text()(); // toda la action como JSON
  TextColumn get status => text().withDefault(const Constant('pending'))();
  IntColumn get attempts => integer().withDefault(const Constant(0))();
  DateTimeColumn get queuedAt => dateTime()();
  DateTimeColumn get completedAt => dateTime().nullable()();
  TextColumn get fingerprint => text().nullable()();
  TextColumn get lastError => text().nullable()();
  DateTimeColumn get nextRetryAt => dateTime().nullable()();
  DateTimeColumn get processingStartedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Set de operation ids completados (idempotencia: si una op llega dos
/// veces a la cola con el mismo `id`, la segunda se descarta).
@DataClassName('CompletedOpRow')
class CompletedOps extends Table {
  TextColumn get opId => text()();
  TextColumn get businessId => text()();
  DateTimeColumn get completedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {opId, businessId};
}

/// Mismo concepto que CompletedOps pero indexado por fingerprint
/// (hash determinístico del payload). Captura el caso donde el cliente
/// re-encola la misma acción semánticamente con un id diferente.
@DataClassName('CompletedFingerprintRow')
class CompletedFingerprints extends Table {
  TextColumn get fingerprint => text()();
  TextColumn get businessId => text()();
  DateTimeColumn get completedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {fingerprint, businessId};
}

@DriftDatabase(tables: [QueueActions, CompletedOps, CompletedFingerprints])
class OfflineQueueDb extends _$OfflineQueueDb {
  // openConnection() viene de `_db_connection_io.dart` (nativo) o
  // `_db_connection_web.dart` (stub) via conditional import.
  OfflineQueueDb() : super(openConnection());

  /// Para tests: construye una DB en memoria sin tocar disco.
  OfflineQueueDb.inMemory(super.executor);

  @override
  int get schemaVersion => 1;

  /// Estrategia de migración. Hoy estamos en v1 (sin upgrades), pero el
  /// framework debe existir ANTES de que el esquema crezca (F3/F4 del
  /// roadmap offline agregan tablas/columnas). Sin esto, subir
  /// `schemaVersion` haría que Drift no supiera migrar y, en el peor caso,
  /// se perdería la cola pendiente del cajero.
  ///
  /// Cómo evolucionar el esquema en el futuro (forward-only):
  ///   1. Cambiar la tabla/columna en este archivo.
  ///   2. Subir `schemaVersion` a N.
  ///   3. Agregar el paso en `onUpgrade`:
  ///        if (from < N) { await m.addColumn(tabla, tabla.nuevaCol); }
  ///   4. Regenerar: `flutter pub run build_runner build`.
  /// Cada paso debe preservar las filas existentes (nunca dropear datos
  /// de la cola sin un respaldo explícito).
  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
        },
        onUpgrade: (m, from, to) async {
          // v1: no hay upgrades todavía. Los pasos por versión van aquí
          // cuando se suba `schemaVersion` (ver doc arriba).
        },
      );

  /// Singleton por proceso. Drift maneja un único pool por archivo, así
  /// que abrir esto N veces sería un bug; lo restringimos.
  static OfflineQueueDb? _instance;
  static OfflineQueueDb getInstance() {
    return _instance ??= OfflineQueueDb();
  }

  /// Para tests: inyecta la instancia (típicamente [OfflineQueueDb.inMemory])
  /// ANTES de que cualquier código llame a [getInstance]. En producción no
  /// se usa — la conexión real necesita path_provider, que no existe en el
  /// entorno de flutter_test.
  @visibleForTesting
  static set debugInstance(OfflineQueueDb db) => _instance = db;
}
