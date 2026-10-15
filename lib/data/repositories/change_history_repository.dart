import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/change_history_entry.dart';

/// Historial de cambios del negocio (migraciones 20261013_0001/0002).
///
/// Solo lectura: lo llenan triggers en la base de datos. La RLS solo deja
/// leer a dueño y administradores (is_admin_of_business); a nadie más le
/// devuelve filas, y nadie puede escribir desde la app.
class ChangeHistoryRepository {
  final SupabaseClient _client;

  ChangeHistoryRepository(this._client);

  static const int pageSize = 50;

  Future<List<ChangeHistoryEntry>> loadPage({
    required String businessId,
    int offset = 0,
    List<String> tables = const [],
    String? action,
    String search = '',
  }) async {
    var query = _client
        .from('change_history')
        .select(
          'id, table_name, row_id, action, label, context, actor_name, '
          'changed_at, changes, source',
        )
        .eq('business_id', businessId);
    if (tables.isNotEmpty) query = query.inFilter('table_name', tables);
    if (action != null) query = query.eq('action', action);
    final term = _searchTerm(search);
    if (term.isNotEmpty) {
      query = query.or(
        'label.ilike.*$term*,context.ilike.*$term*,actor_name.ilike.*$term*',
      );
    }
    final rows = await query
        .order('changed_at', ascending: false)
        .order('id', ascending: false)
        .range(offset, offset + pageSize - 1);
    return (rows as List)
        .map((r) => ChangeHistoryEntry.fromJson(Map<String, dynamic>.from(r)))
        .toList(growable: false);
  }

  /// Quita lo que rompe el filtro `or` de PostgREST (comas, paréntesis,
  /// comodines).
  static String _searchTerm(String raw) =>
      raw.replaceAll(RegExp(r'[,()*%\\]'), ' ').trim();

  /// La tabla no existe todavía en el servidor (falta la migración).
  static bool isNotActivated(Object error) {
    if (error is! PostgrestException) return false;
    return error.code == 'PGRST205' ||
        error.code == '42P01' ||
        (error.message.contains('change_history') &&
            RegExp(
              r'exist|schema cache',
              caseSensitive: false,
            ).hasMatch(error.message));
  }

  static String humanizeError(Object error) {
    final msg = error.toString().toLowerCase();
    if (msg.contains('socketexception') ||
        msg.contains('failed host lookup') ||
        msg.contains('network is unreachable') ||
        msg.contains('connection')) {
      return 'Sin conexión a internet. El historial se lee del servidor.';
    }
    if (msg.contains('row-level security') ||
        msg.contains('permission') ||
        msg.contains('42501')) {
      return 'Solo el dueño o un administrador puede ver el historial.';
    }
    return 'No se pudo cargar el historial. Inténtalo de nuevo.';
  }
}

final changeHistoryRepositoryProvider = Provider<ChangeHistoryRepository>((
  ref,
) {
  return ChangeHistoryRepository(Supabase.instance.client);
});
