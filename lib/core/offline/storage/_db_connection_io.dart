// Implementación de la conexión drift para plataformas nativas
// (Windows, macOS, Linux, Android, iOS). Usa `NativeDatabase` que
// requiere `dart:ffi` — por eso este archivo NO debe importarse en web.
//
// El archivo `_db_connection.dart` hace el conditional export para
// que web cargue `_db_connection_web.dart` en su lugar.

import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Abre una BD drift por nombre de archivo.
///
/// El nombre es parámetro (y no una constante) porque el Hub Local necesita su
/// PROPIA base, separada de la cola. Meter las tablas del Hub en
/// `mangopos_offline_queue.db` obligaría a migrar en caliente la BD que ya
/// custodia las operaciones pendientes del cajero en producción; un archivo
/// aparte arranca en su v1, y un problema en el Hub no puede tocar la cola.
LazyDatabase openConnection({
  String fileName = 'mangopos_offline_queue.db',
}) {
  return LazyDatabase(() async {
    final dir = await getApplicationSupportDirectory();
    final file = File(p.join(dir.path, fileName));
    return NativeDatabase.createInBackground(file);
  });
}
