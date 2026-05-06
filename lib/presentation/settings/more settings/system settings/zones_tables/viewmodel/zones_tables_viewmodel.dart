// lib/presentation/settings/zones_tables/viewmodel/zones_tables_viewmodel.dart
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../../../data/models/dining_table.dart';
import '../../../../../../data/models/zone.dart';
import '../../../../../../data/repositories/pos_settings_repository.dart';
import '../../../../../../data/repositories/zones_repository.dart';
import '../../../../../../data/utils/business_id_resolver.dart';
import '../../../../../../core/utils/sorting_utils.dart';
import '../state/zones_tables_state.dart';

final zonesRepoProvider = Provider(
  (ref) => ZonesRepository(Supabase.instance.client),
);

final zonesTablesVmProvider =
    NotifierProvider<ZonesTablesViewModel, ZonesTablesState>(
      ZonesTablesViewModel.new,
    );

/// Excepción interna que el ViewModel emite ya con mensaje en español
/// listo para mostrar al usuario sin más procesamiento. La UI hace
/// `catch (e) { showSnackBar(e.toString()); }` y obtiene texto limpio.
class ZonesTablesException implements Exception {
  final String message;
  const ZonesTablesException(this.message);
  @override
  String toString() => message;
}

/// Resultado de una operación de eliminación. Se usa soft-delete cuando el
/// DELETE físico falla por FK (registro referenciado por historial de
/// ventas/órdenes). La UI muestra un mensaje distinto en cada caso.
enum DeleteOutcome { deleted, deactivated }

class ZonesTablesViewModel extends Notifier<ZonesTablesState> {
  late final SupabaseClient sb;
  RealtimeChannel? _rtZones;
  RealtimeChannel? _rtTables;
  Timer? _debounce;

  @override
  ZonesTablesState build() {
    sb = Supabase.instance.client;
    ref.onDispose(() {
      _debounce?.cancel();
      _rtZones?.unsubscribe();
      _rtTables?.unsubscribe();
      _rtZones = null;
      _rtTables = null;
    });
    return const ZonesTablesState();
  }

  // ---------------- CARGA ----------------
  Future<void> load({required String businessId}) async {
    state = state.copyWith(loading: true, error: null);

    try {
      final bizId = await resolveBusinessIdOrNull(sb, businessId);
      if (bizId == null) {
        state = state.copyWith(
          loading: false,
          error:
              'No se pudo resolver el negocio del usuario (businessId=auto).',
        );
        return;
      }

      final repo = ref.read(zonesRepoProvider);
      final settingsRepo = ref.read(posSettingsRepositoryProvider);

      final zones = await repo.fetchZones(
        bizId,
        includeInactive: state.showInactive,
      );
      final promptPeopleCountOnOpen = await settingsRepo
          .getPromptPeopleCountOnTableOpen(bizId);
      zones.sort((a, b) {
        final s = a.sortIndex.compareTo(b.sortIndex);
        return s != 0 ? s : a.name.compareTo(b.name);
      });

      state = state.copyWith(
        loading: false,
        businessId: bizId,
        zones: zones,
        promptPeopleCountOnOpen: promptPeopleCountOnOpen,
      );

      await Future.wait(zones.map((z) => refreshTables(z.id)));
      _subscribeRealtime(bizId);
    } catch (e) {
      state = state.copyWith(loading: false, error: _friendlyError(e));
    }
  }

  /// Limpia `state.error` después de que la UI lo mostró en un snackbar.
  void clearError() {
    if (state.error != null) {
      state = state.copyWith(error: null);
    }
  }

  // ---------------- CRUD ZONAS ----------------
  Future<void> addZone(String businessId, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw const ZonesTablesException('El nombre de la zona no puede estar vacío.');
    }

    state = state.copyWith(loading: true, error: null);
    try {
      final bizId = await resolveBusinessIdOrNull(sb, businessId);
      if (bizId == null) {
        throw const ZonesTablesException('BusinessId inválido.');
      }

      await sb.from('zones').insert({'business_id': bizId, 'name': trimmed});
      await load(businessId: bizId);
    } catch (e) {
      state = state.copyWith(loading: false, error: _friendlyError(e));
      throw ZonesTablesException(_friendlyError(e));
    }
  }

  Future<void> updateZone(String zoneId, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw const ZonesTablesException('El nombre de la zona no puede estar vacío.');
    }

    state = state.copyWith(error: null);
    try {
      await sb.from('zones').update({'name': trimmed}).eq('id', zoneId);
      final businessId = state.businessId;
      if (businessId != null && businessId.isNotEmpty) {
        await load(businessId: businessId);
      }
    } catch (e) {
      final msg = _friendlyError(e);
      state = state.copyWith(error: msg);
      throw ZonesTablesException(msg);
    }
  }

  /// Borra una zona. Pre-check: bloquea si tiene mesas con sesiones abiertas.
  ///
  /// Estrategia en cascada (igual que [deleteTable]):
  /// 1. Intenta DELETE físico (CASCADE sobre dining_tables).
  /// 2. Si FK violation (historial de ventas referenciado), hace
  ///    soft-delete de la zona Y de todas sus mesas (`is_active=false`).
  /// 3. UI usa [DeleteOutcome] para mostrar mensaje correcto.
  Future<DeleteOutcome> deleteZone(String zoneId) async {
    state = state.copyWith(loading: true, error: null);
    try {
      // Pre-check: ¿tiene mesas con sesiones abiertas?
      final openSessions = await sb
          .from('table_sessions')
          .select('id, dining_tables!inner(zone_id)')
          .filter('dining_tables.zone_id', 'eq', zoneId)
          .isFilter('closed_at', null);

      final openCount = (openSessions as List).length;
      if (openCount > 0) {
        throw ZonesTablesException(
          'No se puede borrar la zona: tiene $openCount mesa(s) ocupada(s). '
          'Cierra esas cuentas primero.',
        );
      }

      // Intento 1: DELETE físico (CASCADE elimina dining_tables y sessions).
      DeleteOutcome outcome;
      try {
        await sb.from('zones').delete().eq('id', zoneId);
        outcome = DeleteOutcome.deleted;
      } on PostgrestException catch (e) {
        if (e.code == '23503') {
          // Fallback: soft-delete de zona + de TODAS sus mesas.
          // Sin esto la zona quedaría inactiva pero las mesas seguirían
          // visibles en otros listados que filtren solo por business.
          await sb
              .from('dining_tables')
              .update({'is_active': false})
              .eq('zone_id', zoneId);
          await sb
              .from('zones')
              .update({'is_active': false})
              .eq('id', zoneId);
          outcome = DeleteOutcome.deactivated;
        } else {
          rethrow;
        }
      }

      // Limpia local y refresca
      final mapCopy = Map<String, List<DiningTable>>.from(state.tablesByZone)
        ..remove(zoneId);
      state = state.copyWith(tablesByZone: mapCopy);

      final businessId = state.businessId;
      if (businessId != null && businessId.isNotEmpty) {
        await load(businessId: businessId);
      } else {
        state = state.copyWith(loading: false);
      }
      return outcome;
    } catch (e) {
      final msg = _friendlyError(e);
      state = state.copyWith(loading: false, error: msg);
      throw ZonesTablesException(msg);
    }
  }

  /// Devuelve la cantidad de mesas que tiene la zona (para confirmaciones UI).
  int tableCountInZone(String zoneId) {
    return state.tablesByZone[zoneId]?.length ?? 0;
  }

  // ---------------- CRUD MESAS ----------------
  Future<void> addTable(
    String zoneId,
    String code, {
    String? label,
    int capacity = 4,
  }) async {
    final trimmedCode = code.trim();
    if (trimmedCode.isEmpty) {
      throw const ZonesTablesException('El código de mesa no puede estar vacío.');
    }
    if (capacity < 1 || capacity > 50) {
      throw const ZonesTablesException('La capacidad debe estar entre 1 y 50.');
    }

    // Validación client-side de duplicado: evita ir a la DB para casos obvios.
    final existing = state.tablesByZone[zoneId] ?? const [];
    final dup = existing.any(
      (t) => t.code.toLowerCase() == trimmedCode.toLowerCase(),
    );
    if (dup) {
      throw ZonesTablesException(
        'Ya existe una mesa con el código "$trimmedCode" en esta zona.',
      );
    }

    state = state.copyWith(loading: true, error: null);
    try {
      await sb.from('dining_tables').insert({
        'zone_id': zoneId,
        'code': trimmedCode,
        'label': (label?.trim().isEmpty ?? true) ? trimmedCode : label!.trim(),
        'capacity': capacity,
      });
      await refreshTables(zoneId);
    } catch (e) {
      final msg = _friendlyError(e);
      state = state.copyWith(error: msg);
      throw ZonesTablesException(msg);
    } finally {
      state = state.copyWith(loading: false);
    }
  }

  Future<void> updateTable(
    String tableId, {
    required String code,
    String? label,
    int? capacity,
    String? zoneId,
  }) async {
    final trimmedCode = code.trim();
    if (trimmedCode.isEmpty) {
      throw const ZonesTablesException('El código de mesa no puede estar vacío.');
    }
    if (capacity != null && (capacity < 1 || capacity > 50)) {
      throw const ZonesTablesException('La capacidad debe estar entre 1 y 50.');
    }

    // Validación client-side de duplicado dentro de la misma zona
    if (zoneId != null) {
      final existing = state.tablesByZone[zoneId] ?? const [];
      final dup = existing.any(
        (t) =>
            t.id != tableId &&
            t.code.toLowerCase() == trimmedCode.toLowerCase(),
      );
      if (dup) {
        throw ZonesTablesException(
          'Ya existe otra mesa con el código "$trimmedCode" en esta zona.',
        );
      }
    }

    state = state.copyWith(error: null);
    try {
      final updates = <String, dynamic>{
        'code': trimmedCode,
        'label': (label?.trim().isEmpty ?? true) ? trimmedCode : label!.trim(),
      };
      if (capacity != null) updates['capacity'] = capacity;

      await sb.from('dining_tables').update(updates).eq('id', tableId);
      if (zoneId != null) {
        await refreshTables(zoneId);
      }
    } catch (e) {
      final msg = _friendlyError(e);
      state = state.copyWith(error: msg);
      throw ZonesTablesException(msg);
    }
  }

  /// Borra una mesa. Pre-check: bloquea si tiene sesión abierta.
  ///
  /// Estrategia en cascada:
  /// 1. Intenta DELETE físico.
  /// 2. Si falla con código 23503 (FK violation) — típicamente porque
  ///    `fiscal_documents.order_id` referencia órdenes históricas vía
  ///    `table_sessions` — hace fallback a UPDATE `is_active=false`.
  /// 3. La UI usa el [DeleteOutcome] retornado para mostrar el mensaje
  ///    correcto al usuario ("Mesa eliminada" vs "Mesa desactivada").
  ///
  /// Para el cajero el resultado visible es idéntico: la mesa desaparece
  /// del listado de configuración y del runtime de ventas (ambos filtran
  /// `is_active=true`). El historial queda intacto.
  Future<DeleteOutcome> deleteTable(String tableId, {String? zoneId}) async {
    state = state.copyWith(loading: true, error: null);
    try {
      // Pre-check: ¿está la mesa libre?
      final tableRow = await sb
          .from('dining_tables')
          .select('state, code')
          .eq('id', tableId)
          .maybeSingle();

      if (tableRow == null) {
        throw const ZonesTablesException('Mesa no encontrada (¿ya fue borrada?).');
      }

      final currentState = tableRow['state'] as String?;
      final code = tableRow['code'] as String? ?? '';

      if (currentState != null && currentState != 'available') {
        throw ZonesTablesException(
          'No se puede borrar la mesa $code: está $currentState. '
          'Libera la mesa primero.',
        );
      }

      // Pre-check: sesión abierta (paranoia, debería estar 'available' si no hay sesión)
      final openSessions = await sb
          .from('table_sessions')
          .select('id')
          .eq('table_id', tableId)
          .isFilter('closed_at', null);

      if ((openSessions as List).isNotEmpty) {
        throw ZonesTablesException(
          'No se puede borrar la mesa $code: tiene una cuenta abierta.',
        );
      }

      // Intento 1: DELETE físico.
      DeleteOutcome outcome;
      try {
        await sb.from('dining_tables').delete().eq('id', tableId);
        outcome = DeleteOutcome.deleted;
      } on PostgrestException catch (e) {
        if (e.code == '23503') {
          // Fallback: soft-delete (hay historial referenciado).
          await sb
              .from('dining_tables')
              .update({'is_active': false})
              .eq('id', tableId);
          outcome = DeleteOutcome.deactivated;
        } else {
          rethrow;
        }
      }

      if (zoneId != null) {
        await refreshTables(zoneId);
      }
      return outcome;
    } catch (e) {
      final msg = _friendlyError(e);
      state = state.copyWith(loading: false, error: msg);
      throw ZonesTablesException(msg);
    } finally {
      if (state.loading) {
        state = state.copyWith(loading: false);
      }
    }
  }

  // ---------------- REACTIVAR (deshacer soft-delete) ----------------

  Future<void> reactivateTable(String tableId, {String? zoneId}) async {
    state = state.copyWith(loading: true, error: null);
    try {
      await sb
          .from('dining_tables')
          .update({'is_active': true})
          .eq('id', tableId);
      if (zoneId != null) {
        await refreshTables(zoneId);
      }
    } catch (e) {
      final msg = _friendlyError(e);
      state = state.copyWith(loading: false, error: msg);
      throw ZonesTablesException(msg);
    } finally {
      if (state.loading) {
        state = state.copyWith(loading: false);
      }
    }
  }

  Future<void> reactivateZone(String zoneId) async {
    state = state.copyWith(loading: true, error: null);
    try {
      await sb.from('zones').update({'is_active': true}).eq('id', zoneId);
      final businessId = state.businessId;
      if (businessId != null && businessId.isNotEmpty) {
        await load(businessId: businessId);
      }
    } catch (e) {
      final msg = _friendlyError(e);
      state = state.copyWith(loading: false, error: msg);
      throw ZonesTablesException(msg);
    }
  }

  // ---------------- TOGGLE MOSTRAR INACTIVAS ----------------

  Future<void> setShowInactive(bool value) async {
    if (state.showInactive == value) return;
    state = state.copyWith(showInactive: value);
    final businessId = state.businessId;
    if (businessId != null && businessId.isNotEmpty) {
      await load(businessId: businessId);
    }
  }

  // ---------------- REORDENAR ZONAS ----------------

  /// Persiste el nuevo orden en `zones.sort_index` según la posición en
  /// la lista provista. Hace updates en serie (Supabase JS no soporta
  /// batch upsert por id distinto en una sola llamada).
  Future<void> reorderZones(List<Zone> orderedZones) async {
    state = state.copyWith(loading: true, error: null);
    try {
      // Mantenemos sort_index empezando en 1 para no chocar con virtuales
      // (que usan 900/901). Step de 10 para permitir inserciones manuales
      // futuras sin reescribir todo.
      for (var i = 0; i < orderedZones.length; i++) {
        final z = orderedZones[i];
        final newIdx = (i + 1) * 10;
        if (z.sortIndex == newIdx) continue;
        await sb
            .from('zones')
            .update({'sort_index': newIdx})
            .eq('id', z.id);
      }
      final businessId = state.businessId;
      if (businessId != null && businessId.isNotEmpty) {
        await load(businessId: businessId);
      }
    } catch (e) {
      final msg = _friendlyError(e);
      state = state.copyWith(loading: false, error: msg);
      throw ZonesTablesException(msg);
    }
  }

  // ---------------- BULK CREATE DE MESAS ----------------

  /// Crea N mesas en un rango. Ej: prefix='T', from=1, to=20, padding=2
  /// genera T01, T02, ... T20.
  ///
  /// Si alguna ya existe (UNIQUE en zone_id+code), la salta sin error
  /// y reporta cuántas se crearon vs cuántas se saltaron.
  Future<({int created, int skipped})> addTablesBulk({
    required String zoneId,
    required String prefix,
    required int from,
    required int to,
    int padding = 2,
    int capacity = 4,
  }) async {
    final cleanPrefix = prefix.trim();
    if (cleanPrefix.isEmpty) {
      throw const ZonesTablesException('El prefijo no puede estar vacío.');
    }
    if (from < 1 || to < from) {
      throw const ZonesTablesException(
        'Rango inválido: "desde" debe ser ≥ 1 y "hasta" debe ser ≥ "desde".',
      );
    }
    if (to - from + 1 > 200) {
      throw const ZonesTablesException(
        'No se pueden crear más de 200 mesas a la vez.',
      );
    }
    if (capacity < 1 || capacity > 50) {
      throw const ZonesTablesException('La capacidad debe estar entre 1 y 50.');
    }

    final existing = state.tablesByZone[zoneId] ?? const [];
    final existingCodes = existing
        .map((t) => t.code.toLowerCase())
        .toSet();

    final toInsert = <Map<String, dynamic>>[];
    var skipped = 0;
    for (var n = from; n <= to; n++) {
      final code = '$cleanPrefix${n.toString().padLeft(padding, '0')}';
      if (existingCodes.contains(code.toLowerCase())) {
        skipped++;
        continue;
      }
      toInsert.add({
        'zone_id': zoneId,
        'code': code,
        'label': code,
        'capacity': capacity,
      });
    }

    if (toInsert.isEmpty) {
      return (created: 0, skipped: skipped);
    }

    state = state.copyWith(loading: true, error: null);
    try {
      await sb.from('dining_tables').insert(toInsert);
      await refreshTables(zoneId);
      return (created: toInsert.length, skipped: skipped);
    } catch (e) {
      final msg = _friendlyError(e);
      state = state.copyWith(loading: false, error: msg);
      throw ZonesTablesException(msg);
    } finally {
      if (state.loading) {
        state = state.copyWith(loading: false);
      }
    }
  }

  Future<void> setPromptPeopleCountOnOpen(bool enabled) async {
    final businessId = state.businessId;
    if (businessId == null || businessId.isEmpty) return;

    state = state.copyWith(savingOpenTableConfig: true, error: null);
    try {
      await ref
          .read(posSettingsRepositoryProvider)
          .setPromptPeopleCountOnTableOpen(
            businessId: businessId,
            enabled: enabled,
          );
      state = state.copyWith(
        promptPeopleCountOnOpen: enabled,
        savingOpenTableConfig: false,
      );
    } catch (e) {
      state = state.copyWith(
        savingOpenTableConfig: false,
        error: _friendlyError(e),
      );
    }
  }

  // ---------------- Helpers ----------------
  Future<void> refreshTables(String zoneId) async {
    final repo = ref.read(zonesRepoProvider);
    final rows = await repo.fetchTablesByZone(
      zoneId,
      includeInactive: state.showInactive,
    );
    rows.sort((a, b) => SortingUtils.naturalCompare(a.code, b.code));

    final map = Map<String, List<DiningTable>>.from(state.tablesByZone);
    map[zoneId] = rows;
    state = state.copyWith(tablesByZone: map);
  }

  /// Mapea errores de Postgrest/Supabase a mensajes en español útiles para
  /// el usuario final. Errores no reconocidos caen a un mensaje genérico
  /// con el detalle para debugging, pero acortado.
  String _friendlyError(Object e) {
    if (e is ZonesTablesException) return e.message;

    if (e is PostgrestException) {
      switch (e.code) {
        case '23505':
          // unique_violation
          return 'Ya existe un registro con ese valor único '
              '(probablemente otra mesa con el mismo código en la zona).';
        case '23503':
          // foreign_key_violation
          return 'No se puede borrar: este registro tiene historial asociado '
              '(ventas, sesiones u órdenes). Considera desactivarlo en lugar de eliminarlo.';
        case '23502':
          // not_null_violation
          return 'Falta un dato obligatorio.';
        case '23514':
          // check_violation
          return 'Un valor está fuera de rango (capacidad, estado, etc.).';
        case '42501':
          // insufficient_privilege (RLS)
          return 'No tienes permiso para esta operación.';
        case 'PGRST116':
          // not found
          return 'Registro no encontrado.';
        default:
          final detail = e.message.length > 120
              ? '${e.message.substring(0, 120)}...'
              : e.message;
          return 'Error de base de datos: $detail';
      }
    }

    final raw = e.toString();
    return raw.length > 200 ? '${raw.substring(0, 200)}...' : raw;
  }

  void _subscribeRealtime(String businessId) {
    _rtZones ??=
        sb
            .channel('rt:settings_zones:$businessId')
            .onPostgresChanges(
              event: PostgresChangeEvent.all,
              schema: 'public',
              table: 'zones',
              filter: PostgresChangeFilter(
                type: PostgresChangeFilterType.eq,
                column: 'business_id',
                value: businessId,
              ),
              callback: (_) => _debounced(() => load(businessId: businessId)),
            )
          ..subscribe();

    _rtTables ??=
        sb
            .channel('rt:settings_tables:$businessId')
            .onPostgresChanges(
              event: PostgresChangeEvent.all,
              schema: 'public',
              table: 'dining_tables',
              callback: (payload) {
                final zId =
                    (payload.newRecord['zone_id'] ??
                            payload.oldRecord['zone_id'])
                        as String?;
                // Solo refrescar si la zona afectada es del business actual.
                if (zId != null && state.tablesByZone.containsKey(zId)) {
                  _debounced(() => refreshTables(zId));
                }
              },
            )
          ..subscribe();
  }

  void _debounced(void Function() fn) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 220), fn);
  }
}
