import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Última lista de clientes leída online, por negocio, para asignar cliente
/// y buscar sin internet.
///
/// Va a un archivo JSON propio en la carpeta de soporte de la app y NO a
/// SharedPreferences: la lista puede tener miles de filas, y en Windows cada
/// escritura de prefs reescribe el archivo entero (llegó a 34 MB).
class CustomersOfflineCache {
  CustomersOfflineCache._();
  static final CustomersOfflineCache instance = CustomersOfflineCache._();

  /// Último JSON escrito por negocio: solo se toca el disco si cambia.
  final Map<String, String> _lastWritten = {};

  /// Copia en memoria de lo leído del disco en esta sesión.
  final Map<String, List<Map<String, dynamic>>> _memory = {};

  Future<File?> _file(String businessId) async {
    if (kIsWeb) return null;
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/offline_cache/customers_$businessId.json');
  }

  Future<void> save(String businessId, List<Map<String, dynamic>> rows) async {
    try {
      final encoded = jsonEncode(rows);
      if (_lastWritten[businessId] == encoded) return;
      _memory[businessId] = rows;
      final file = await _file(businessId);
      if (file == null) return;
      await file.parent.create(recursive: true);
      // Escritura atómica: un corte a mitad no deja el JSON truncado.
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(encoded, flush: true);
      await tmp.rename(file.path);
      _lastWritten[businessId] = encoded;
    } catch (e) {
      debugPrint('[customers] no se pudo guardar caché offline: $e');
    }
  }

  /// Lista guardada, o vacía si nunca se leyó online en este equipo.
  Future<List<Map<String, dynamic>>> load(String businessId) async {
    final mem = _memory[businessId];
    if (mem != null) return mem;
    try {
      final file = await _file(businessId);
      if (file == null || !await file.exists()) return const [];
      final raw = await file.readAsString();
      final rows = (jsonDecode(raw) as List)
          .map((it) => Map<String, dynamic>.from(it as Map))
          .toList();
      _memory[businessId] = rows;
      _lastWritten[businessId] = raw;
      return rows;
    } catch (e) {
      debugPrint('[customers] caché offline ilegible: $e');
      return const [];
    }
  }

  /// Búsqueda local con los mismos campos que la del servidor
  /// (`CustomersQueries.searchFields`).
  static List<Map<String, dynamic>> filter(
    List<Map<String, dynamic>> rows,
    String query,
  ) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return rows;
    const fields = ['name', 'legal_name', 'email', 'phone', 'tax_id'];
    return rows
        .where(
          (row) => fields.any(
            (f) => (row[f]?.toString().toLowerCase() ?? '').contains(q),
          ),
        )
        .toList();
  }
}
