// Base de datos LOCAL del Hub (paso 5 del plan offline).
//
// Vive en su PROPIO archivo (`mangopos_hub_state.db`), separado de
// `mangopos_offline_queue.db`. La razón es de riesgo, no de estilo: la BD de la
// cola ya custodia las operaciones pendientes del cajero EN PRODUCCIÓN, y meter
// las tablas del Hub ahí obligaría a migrarla en caliente. Con un archivo
// aparte, el Hub arranca en su v1 y un problema suyo no puede tocar la cola.
//
// Qué reemplaza: el op-log del Hub vivía como un array JSON en
// SharedPreferences (`hub_oplog_<businessId>`). Cada `append` leía el archivo
// entero, escaneaba linealmente para deduplicar por `op_id` y volvía a
// serializar todo el array — y ese es el ÚNICO camino de escritura de todas las
// cajas del local. Con 2.000 ops de una noche, cada nueva operación reescribía
// megabytes. Aquí cada INSERT es O(log n) indexado y la deduplicación es un
// constraint, no un barrido.
//
// Web: drift necesita WASM y setup adicional, así que en web `HubOpLog` sigue
// cayendo a SharedPreferences (ver el guard `kIsWeb` en el facade). La conexión
// se resuelve por conditional import igual que la cola.
//
// Para regenerar el código: `flutter pub run build_runner build`.

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../storage/_db_connection_io.dart'
    if (dart.library.html) '../storage/_db_connection_web.dart';

part 'hub_state_db.g.dart';

/// Op-log del Hub: registro append-only, ordenado y deduplicado de las
/// operaciones que los terminales mandan mientras el local está sin internet.
///
/// `seq` es monotónico POR NEGOCIO y contiguo (1, 2, 3…), igual que en la
/// implementación de SharedPreferences que reemplaza — los clientes guardan el
/// último `seq` visto y piden el delta, así que el contrato no puede cambiar.
/// Por eso la PK es compuesta y no un autoincremento global.
@DataClassName('HubOpRow')
class HubOps extends Table {
  TextColumn get businessId => text()();
  IntColumn get seq => integer()();

  /// Id de la operación. Nullable a propósito: hay ops sin `op_id` y esas NO se
  /// deduplican (mismo comportamiento que antes). SQLite permite varios NULL en
  /// un índice único, así que el índice de abajo las deja pasar.
  TextColumn get opId => text().nullable()();

  /// Se extrae del payload al insertar para poder podar por orden
  /// (`retainOrders`) sin deserializar el log entero.
  TextColumn get orderId => text().nullable()();

  /// La op completa como JSON, ya enriquecida con `seq` y `hub_received_at`.
  TextColumn get payloadJson => text()();

  DateTimeColumn get receivedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {businessId, seq};
}

/// Marca de agua del `seq` por negocio.
///
/// Existe por un bug REAL que arrastraba la versión de SharedPreferences: el
/// siguiente `seq` se calculaba como `MAX(seq) + 1` sobre las ops VIVAS, así que
/// después de una poda (`retainOrders`) o de un `clear` el máximo bajaba y el
/// Hub volvía a entregar un `seq` que ya le había dado a los clientes. Un
/// terminal que iba por el 2 y pedía `since(2)` se perdía para siempre la op
/// nueva que también recibió el 2.
///
/// Con esta tabla el contador NUNCA retrocede: se guarda aparte de las filas y
/// sobrevive a la poda.
@DataClassName('HubMetaRow')
class HubMeta extends Table {
  TextColumn get businessId => text()();

  /// Último `seq` ENTREGADO, aunque su fila ya se haya podado.
  IntColumn get lastSeq => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {businessId};
}

/// Foto de las órdenes que YA estaban abiertas antes de que se cayera internet.
///
/// El hueco que cierra: los proyectores solo reconstruyen órdenes CREADAS
/// durante la ventana offline, porque son las únicas cuyas ops están en el
/// op-log. Una mesa abierta por otra caja mientras había internet vive solo en
/// Supabase, así que al caer la red el Hub no sabía qué tenía dentro y abrirla
/// mostraba una orden vacía.
///
/// Es una FOTO, no un log: se reemplaza entera en cada captura. Por eso vive en
/// su propia tabla y NO como ops dentro de `hub_ops` — meter filas
/// reemplazables en un registro append-only es mezclar dos cosas distintas, y
/// además el uplink las vería y las volvería a subir a Supabase, duplicando
/// órdenes e inventario. Aquí el uplink ni las ve.
///
/// Se guarda como ops SINTÉTICAS (`open_table` + `add_item`) en vez de un
/// modelo propio: así la proyección es `projectSalon([...baseline, ...log])` y
/// lo que se hizo offline se apila encima de la foto usando el MISMO proyector
/// ya probado, sin lógica de mezcla aparte.
@DataClassName('HubBaselineRow')
class HubBaseline extends Table {
  TextColumn get businessId => text()();

  /// Cuándo se tomó la foto. Es además la parte de la revisión que le dice al
  /// cache de proyección que el baseline cambió.
  DateTimeColumn get capturedAt => dateTime()();

  /// Array JSON de ops sintéticas, en el orden en que deben plegarse.
  TextColumn get opsJson => text()();

  @override
  Set<Column> get primaryKey => {businessId};
}

@DriftDatabase(tables: [HubOps, HubMeta, HubBaseline])
class HubStateDb extends _$HubStateDb {
  HubStateDb() : super(openConnection(fileName: 'mangopos_hub_state.db'));

  /// Para tests: una BD en memoria, sin tocar disco ni path_provider.
  HubStateDb.inMemory(super.executor);

  @override
  int get schemaVersion => 1;

  /// Cómo evolucionar el esquema (forward-only):
  ///   1. Cambiar la tabla/columna aquí.
  ///   2. Subir `schemaVersion` a N.
  ///   3. Agregar el paso en `onUpgrade`:
  ///        if (from < N) { await m.addColumn(tabla, tabla.nuevaCol); }
  ///   4. Regenerar: `flutter pub run build_runner build`.
  /// Cada paso debe preservar las filas existentes: mientras el local está sin
  /// internet, esta tabla es la ÚNICA copia de lo que se vendió.
  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          await _createIndexes(m);
        },
        onUpgrade: (m, from, to) async {
          // v1: sin upgrades todavía.
        },
      );

  Future<void> _createIndexes(Migrator m) async {
    // Deduplicación por op_id dentro del negocio. Antes era un escaneo lineal
    // del log completo en cada append; ahora lo garantiza el motor.
    await m.database.customStatement(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_hub_ops_business_op '
      'ON hub_ops (business_id, op_id)',
    );
    // `since(seq)` y el orden FIFO del uplink.
    await m.database.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_hub_ops_business_seq '
      'ON hub_ops (business_id, seq)',
    );
    // Poda por orden tras el uplink.
    await m.database.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_hub_ops_business_order '
      'ON hub_ops (business_id, order_id)',
    );
  }

  /// Singleton por proceso: drift maneja un pool por archivo, abrir esto N
  /// veces sería un bug.
  static HubStateDb? _instance;
  static HubStateDb getInstance() => _instance ??= HubStateDb();

  /// Para tests: inyecta la instancia (típicamente [HubStateDb.inMemory])
  /// ANTES de que nadie llame a [getInstance].
  @visibleForTesting
  static set debugInstance(HubStateDb? db) => _instance = db;
}
