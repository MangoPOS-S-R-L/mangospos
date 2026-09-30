// Activos fijos (20260930_0052). Repositorio APARTE del de inventario a
// propósito: un activo fijo no es un insumo (no tiene existencia ni costo
// promedio, no entra en la valuación) y `InventoryRepository` ya pasa las
// 2,000 líneas.
//
// Lectura: SELECT directo (RLS de solo lectura por negocio).
// Escritura: SOLO por los RPC `fn_fixed_asset_*`, que validan el permiso
// `inventario.activos.gestionar` y dejan la historia. No hay INSERT/UPDATE
// directo: el servidor no tiene policies de escritura para estas tablas.

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../presentation/inventory/state/fixed_assets_state.dart';
import '../utils/business_id_resolver.dart';

/// El servidor no tiene las tablas o los RPC: falta aplicar
/// `20260930_0052_fixed_assets.sql`. La pantalla lo dice en vez de mostrar
/// una lista vacía que parece «no hay activos».
class FixedAssetsMigrationMissing implements Exception {
  const FixedAssetsMigrationMissing();

  @override
  String toString() =>
      'Los activos fijos necesitan la migración 20260930_0052_fixed_assets '
      'aplicada en Supabase.';
}

final fixedAssetsRepositoryProvider = Provider<FixedAssetsRepository>((ref) {
  return FixedAssetsRepository(Supabase.instance.client);
});

class FixedAssetsRepository {
  FixedAssetsRepository(this._client);

  final SupabaseClient _client;

  /// La bodega y el responsable se resuelven por el nombre de su FK:
  /// `fixed_asset_movements` también apunta a `warehouses` y a `employees`,
  /// y sin la pista PostgREST podría ver más de un camino (PGRST201). El
  /// alias deja las claves como las devuelven los RPC.
  static const _assetColumns =
      'id, business_id, code, name, category, brand, model, serial_number, '
      'purchase_date, purchase_cost, supplier_name, warranty_until, '
      'warehouse_id, location_note, assigned_employee_id, status, '
      'retired_at, retired_reason, notes, created_at, updated_at, '
      'warehouses:warehouses!fixed_assets_warehouse_id_fkey(name), '
      'employees:employees!fixed_assets_assigned_employee_id_fkey'
      '(first_name, last_name)';

  static const _movementColumns =
      'id, asset_id, event_type, from_warehouse_name, to_warehouse_name, '
      'from_location_note, to_location_note, from_employee_name, '
      'to_employee_name, from_status, to_status, changes, notes, '
      'created_by_name, created_at';

  /// PostgREST corta en 1,000 filas por respuesta.
  static const _pageSize = 1000;

  /// True si el error es «acá no existe eso»: tabla (42P01 / PGRST205),
  /// relación para el embed (PGRST200) o RPC (PGRST202 / 42883).
  @visibleForTesting
  static bool isMissingSchema(Object e) {
    if (e is PostgrestException) {
      return e.code == '42P01' ||
          e.code == 'PGRST205' ||
          e.code == 'PGRST200' ||
          e.code == 'PGRST202' ||
          e.code == '42883';
    }
    return false;
  }

  Future<T> _guard<T>(Future<T> Function() run) async {
    try {
      return await run();
    } catch (e) {
      if (isMissingSchema(e)) {
        debugPrint('[activos] falta la migración 20260930_0052_fixed_assets');
        throw const FixedAssetsMigrationMissing();
      }
      rethrow;
    }
  }

  /// El negocio activo. Separado para que la pantalla no dependa de
  /// Supabase directamente (y las pruebas puedan darle uno fijo).
  Future<String?> resolveBusinessId() =>
      resolveBusinessIdOrNull(_client, 'auto');

  /// Todo el registro del negocio, incluidos los dados de baja (la pantalla
  /// los esconde por defecto, pero cuentan en los indicadores).
  Future<List<FixedAsset>> listAssets(String businessId) {
    return _guard(() async {
      final result = <FixedAsset>[];
      for (var from = 0;; from += _pageSize) {
        final rows = await _client
            .from('fixed_assets')
            .select(_assetColumns)
            .eq('business_id', businessId)
            .order('code')
            .range(from, from + _pageSize - 1);
        final page = List<Map<String, dynamic>>.from(rows as List);
        result.addAll(page.map(FixedAsset.fromMap));
        if (page.length < _pageSize) break;
      }
      return sortFixedAssetsByCode(result);
    });
  }

  /// La historia de un activo, lo más reciente primero.
  Future<List<FixedAssetMovement>> listMovements(String assetId) {
    return _guard(() async {
      final rows = await _client
          .from('fixed_asset_movements')
          .select(_movementColumns)
          .eq('asset_id', assetId)
          .order('created_at', ascending: false)
          .limit(500);
      return List<Map<String, dynamic>>.from(rows as List)
          .map(FixedAssetMovement.fromMap)
          .toList(growable: false);
    });
  }

  /// Bodegas activas del negocio, sin la virtual de tránsito (un horno no
  /// puede estar «en tránsito»).
  Future<List<FixedAssetOption>> listWarehouses(String businessId) async {
    final rows = await _client
        .from('warehouses')
        .select('id, name, is_main, is_active')
        .eq('business_id', businessId)
        .order('is_main', ascending: false)
        .order('name');
    return List<Map<String, dynamic>>.from(rows as List)
        .where((r) => r['is_active'] != false)
        .map((r) => FixedAssetOption(
              r['id']?.toString() ?? '',
              r['name']?.toString().trim() ?? '',
            ))
        .where((o) =>
            o.id.isNotEmpty && o.name.isNotEmpty && o.name != '__IN_TRANSIT__')
        .toList(growable: false);
  }

  /// Empleados activos, para elegir el responsable. Mismo criterio que el
  /// responsable de una bodega (`getKeeperCandidates`).
  Future<List<FixedAssetOption>> listEmployees(String businessId) async {
    final rows = await _client
        .from('employees')
        .select('id, first_name, last_name')
        .eq('business_id', businessId)
        .eq('status', 'active')
        .order('first_name');
    return List<Map<String, dynamic>>.from(rows as List)
        .map((r) => FixedAssetOption(
              r['id']?.toString() ?? '',
              [
                r['first_name']?.toString().trim() ?? '',
                r['last_name']?.toString().trim() ?? '',
              ].where((p) => p.isNotEmpty).join(' '),
            ))
        .where((o) => o.id.isNotEmpty && o.name.isNotEmpty)
        .toList(growable: false);
  }

  /// Nombre del negocio para encabezar los documentos. `businesses` no tiene
  /// columna `name`: la columna es `business_name`.
  Future<String> getBusinessName(String businessId) async {
    try {
      final row = await _client
          .from('businesses')
          .select('business_name')
          .eq('id', businessId)
          .maybeSingle();
      final nombre = row?['business_name']?.toString().trim();
      return (nombre == null || nombre.isEmpty) ? 'Negocio' : nombre;
    } catch (e) {
      debugPrint('[activos] getBusinessName error: $e');
      return 'Negocio';
    }
  }

  FixedAsset _asset(dynamic response) =>
      FixedAsset.fromMap(Map<String, dynamic>.from(response as Map));

  /// Alta. El código AF-00001 lo pone el servidor. [clientRequestId] (un
  /// uuid por formulario abierto) hace que un reintento tras un timeout
  /// devuelva la misma ficha en vez de crear otra.
  Future<FixedAsset> createAsset({
    required String businessId,
    required FixedAssetDraft draft,
    String? clientRequestId,
  }) {
    return _guard(() async {
      final response = await _client.rpc(
        'fn_fixed_asset_create',
        params: {
          'p_business_id': businessId,
          'p_data': draft.createJson(clientRequestId: clientRequestId),
        },
      );
      return _asset(response);
    });
  }

  /// Edita los datos de la ficha. NO mueve ni cambia el estado.
  Future<FixedAsset> updateAsset({
    required String assetId,
    required FixedAssetDraft draft,
  }) {
    return _guard(() async {
      final response = await _client.rpc(
        'fn_fixed_asset_update',
        params: {'p_asset_id': assetId, 'p_data': draft.dataJson()},
      );
      return _asset(response);
    });
  }

  /// Traslado y/o reasignación. Recibe el estado FINAL: null = sin bodega /
  /// sin responsable.
  Future<FixedAsset> moveAsset({
    required String assetId,
    required String? warehouseId,
    required String? locationNote,
    required String? employeeId,
    String? notes,
  }) {
    return _guard(() async {
      final response = await _client.rpc(
        'fn_fixed_asset_move',
        params: {
          'p_asset_id': assetId,
          'p_warehouse_id': warehouseId,
          'p_location_note': locationNote,
          'p_employee_id': employeeId,
          'p_notes': notes,
        },
      );
      return _asset(response);
    });
  }

  /// Cambio de estado. `retired` exige [notes] (el motivo de la baja);
  /// salir de `retired` es una reactivación.
  Future<FixedAsset> setStatus({
    required String assetId,
    required FixedAssetStatus status,
    String? notes,
  }) {
    return _guard(() async {
      final response = await _client.rpc(
        'fn_fixed_asset_set_status',
        params: {
          'p_asset_id': assetId,
          'p_status': status.wire,
          'p_notes': notes,
        },
      );
      return _asset(response);
    });
  }
}
