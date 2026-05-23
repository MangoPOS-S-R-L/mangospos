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
// Para regenerar el código: `flutter pub run build_runner build`.

import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

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
  OfflineQueueDb() : super(_openConnection());

  /// Para tests: construye una DB en memoria sin tocar disco.
  OfflineQueueDb.inMemory(QueryExecutor executor) : super(executor);

  @override
  int get schemaVersion => 1;

  /// Singleton por proceso. Drift maneja un único pool por archivo, así
  /// que abrir esto N veces sería un bug; lo restringimos.
  static OfflineQueueDb? _instance;
  static OfflineQueueDb getInstance() {
    return _instance ??= OfflineQueueDb();
  }
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final dir = await getApplicationSupportDirectory();
    final file = File(p.join(dir.path, 'mangopos_offline_queue.db'));
    return NativeDatabase.createInBackground(file);
  });
}
