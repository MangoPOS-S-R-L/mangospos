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

LazyDatabase openConnection() {
  return LazyDatabase(() async {
    final dir = await getApplicationSupportDirectory();
    final file = File(p.join(dir.path, 'mangopos_offline_queue.db'));
    return NativeDatabase.createInBackground(file);
  });
}
