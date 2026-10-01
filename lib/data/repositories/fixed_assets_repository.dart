// Activos fijos (20260930_0052) y su verificación física (20261001_0050).
// Repositorio APARTE del de inventario a
// propósito: un activo fijo no es un insumo (no tiene existencia ni costo
// promedio, no entra en la valuación) y `InventoryRepository` ya pasa las
// 2,000 líneas.
//
// Lectura: SELECT directo (RLS de solo lectura por negocio).
// Escritura: SOLO por los RPC `fn_fixed_asset_*`, que validan el permiso
// `inventario.activos.gestionar` y dejan la historia. No hay INSERT/UPDATE
// directo: el servidor no tiene policies de escritura para estas tablas.
//
// Dos versiones del esquema conviven: un negocio puede tener solo 0052 (sin
// cantidad, sin verificaciones). La lista de activos se degrada sola (42703
// → columnas viejas, cantidad 1) y lo de verificaciones avisa qué migración
// falta en vez de romper la pantalla.

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../presentation/inventory/state/fixed_asset_verification_state.dart';
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

/// El servidor tiene los activos (0052) pero no la verificación: falta
/// `20261001_0050_fixed_asset_verification.sql`.
class FixedAssetVerificationMigrationMissing implements Exception {
  const FixedAssetVerificationMigrationMissing();

  @override
  String toString() =>
      'Falta aplicar la migración 20261001_0050_fixed_asset_verification.sql '
      'en Supabase.';
}

/// La verificación pedida no existe (o no es de este negocio).
class FixedAssetVerificationNotFound implements Exception {
  const FixedAssetVerificationNotFound();

  @override
  String toString() => 'Esa verificación no existe o no es de este negocio.';
}

/// Resultado de deshacer una revisión: la línea vuelve a «sin revisar», o
/// se borra si el activo no estaba en la lista.
typedef VerificationUncheckResult = ({
  bool removed,
  FixedAssetVerificationLine? line,
});

/// Resultado de registrar un activo durante la verificación.
typedef VerificationAddResult = ({
  FixedAsset asset,
  FixedAssetVerificationLine line,
});

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

  /// Las de 20261001_0050. Se piden aparte para poder caer a [_assetColumns]
  /// en una base que todavía no las tiene.
  static const _assetVerificationColumns =
      '$_assetColumns, quantity, last_verified_at, last_verification_id';

  static const _movementColumns =
      'id, asset_id, event_type, from_warehouse_name, to_warehouse_name, '
      'from_location_note, to_location_note, from_employee_name, '
      'to_employee_name, from_status, to_status, changes, notes, '
      'created_by_name, created_at';

  static const _movementVerificationColumns =
      '$_movementColumns, from_quantity, to_quantity, verification_id';

  /// Tri-estado de 20261001_0050: `null` = no se probó; `false` = este
  /// servidor no tiene la cantidad ni las verificaciones. ESTÁTICO: es una
  /// propiedad del servidor, no de esta instancia.
  static bool? _verificationSchema;

  /// ¿Se pueden mandar código propio y cantidad? Mientras no se sepa, sí: el
  /// primer listado lo aclara antes de que se abra un formulario.
  bool get quantitySupported => _verificationSchema != false;

  @visibleForTesting
  static void resetSchemaProbeForTest() => _verificationSchema = null;

  /// Columna desconocida: la base no tiene 20261001_0050.
  static bool _isMissingColumn(Object e) =>
      e is PostgrestException && (e.code == '42703' || e.code == 'PGRST204');

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

  /// Lo de verificaciones: si falta la tabla o el RPC, el aviso es de la
  /// migración NUEVA (los activos sí existen).
  Future<T> _guardVerification<T>(Future<T> Function() run) async {
    try {
      return await run();
    } catch (e) {
      if (isMissingSchema(e) || _isMissingColumn(e)) {
        debugPrint(
          '[activos] falta la migración 20261001_0050_fixed_asset_verification',
        );
        throw const FixedAssetVerificationMigrationMissing();
      }
      rethrow;
    }
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
    Future<List<FixedAsset>> run(String columns) async {
      final result = <FixedAsset>[];
      for (var from = 0;; from += _pageSize) {
        final rows = await _client
            .from('fixed_assets')
            .select(columns)
            .eq('business_id', businessId)
            .order('code')
            .range(from, from + _pageSize - 1);
        final page = List<Map<String, dynamic>>.from(rows as List);
        result.addAll(page.map(FixedAsset.fromMap));
        if (page.length < _pageSize) break;
      }
      return sortFixedAssetsByCode(result);
    }

    return _guard(() async {
      if (_verificationSchema != false) {
        try {
          final rows = await run(_assetVerificationColumns);
          _verificationSchema = true;
          return rows;
        } catch (e) {
          if (!_isMissingColumn(e)) rethrow;
          _verificationSchema = false;
          debugPrint(
            '[activos] sin cantidad: falta 20261001_0050_fixed_asset_verification',
          );
        }
      }
      // Base con solo 0052: cada ficha es UNA unidad.
      return run(_assetColumns);
    });
  }

  /// La historia de un activo, lo más reciente primero.
  Future<List<FixedAssetMovement>> listMovements(String assetId) {
    Future<List<FixedAssetMovement>> run(String columns) async {
      final rows = await _client
          .from('fixed_asset_movements')
          .select(columns)
          .eq('asset_id', assetId)
          .order('created_at', ascending: false)
          .limit(500);
      return List<Map<String, dynamic>>.from(rows as List)
          .map(FixedAssetMovement.fromMap)
          .toList(growable: false);
    }

    return _guard(() async {
      if (_verificationSchema != false) {
        try {
          final rows = await run(_movementVerificationColumns);
          _verificationSchema = true;
          return rows;
        } catch (e) {
          if (!_isMissingColumn(e)) rethrow;
          _verificationSchema = false;
        }
      }
      return run(_movementColumns);
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

  // ── Verificación física (20261001_0050) ─────────────────────────────────

  /// Las verificaciones del negocio: las abiertas primero, después las
  /// demás de la más nueva a la más vieja. Las abiertas traen su avance.
  Future<List<FixedAssetVerification>> listVerifications(String businessId) {
    return _guardVerification(() async {
      final rows = await _client
          .from('fixed_asset_verifications')
          .select()
          .eq('business_id', businessId)
          .order('started_at', ascending: false)
          .limit(200);
      final list = List<Map<String, dynamic>>.from(rows as List)
          .map(FixedAssetVerification.fromMap)
          .toList();

      final openIds = [
        for (final v in list)
          if (v.isOpen) v.id,
      ];
      final progress = <String, List<FixedAssetVerificationLine>>{};
      if (openIds.isNotEmpty) {
        for (var from = 0;; from += _pageSize) {
          final page = List<Map<String, dynamic>>.from(
            await _client
                .from('fixed_asset_verification_lines')
                .select('id, verification_id, asset_id, expected, found_qty, '
                    'is_new')
                .inFilter('verification_id', openIds)
                .order('id')
                .range(from, from + _pageSize - 1) as List,
          );
          for (final r in page) {
            final line = FixedAssetVerificationLine.fromMap(r);
            progress.putIfAbsent(line.verificationId, () => []).add(line);
          }
          if (page.length < _pageSize) break;
        }
      }

      final withProgress = [
        for (final v in list)
          v.isOpen
              ? v.copyWith(
                  listProgress: VerificationProgress.from(
                    progress[v.id] ?? const [],
                  ),
                )
              : v,
      ];
      withProgress.sort((a, b) {
        if (a.isOpen != b.isOpen) return a.isOpen ? -1 : 1;
        final at = a.startedAt ?? DateTime(1970);
        final bt = b.startedAt ?? DateTime(1970);
        return bt.compareTo(at);
      });
      return withProgress;
    });
  }

  /// Una verificación con TODAS sus líneas (de 1,000 en 1,000).
  Future<FixedAssetVerification> getVerification(String verificationId) {
    return _guardVerification(() async {
      final header = await _client
          .from('fixed_asset_verifications')
          .select()
          .eq('id', verificationId)
          .maybeSingle();
      if (header == null) {
        throw const FixedAssetVerificationNotFound();
      }
      final lines = <FixedAssetVerificationLine>[];
      for (var from = 0;; from += _pageSize) {
        final page = List<Map<String, dynamic>>.from(
          await _client
              .from('fixed_asset_verification_lines')
              .select()
              .eq('verification_id', verificationId)
              .order('asset_code')
              .range(from, from + _pageSize - 1) as List,
        );
        lines.addAll(page.map(FixedAssetVerificationLine.fromMap));
        if (page.length < _pageSize) break;
      }
      return FixedAssetVerification.fromMap(
        Map<String, dynamic>.from(header),
      ).copyWith(lines: sortVerificationLines(lines));
    });
  }

  /// id → número («#3») de varias verificaciones, para la historia de un
  /// activo. Sin la migración devuelve vacío: la historia sale sin número.
  Future<Map<String, int>> getVerificationNumbers(List<String> ids) async {
    final unique = ids.toSet().toList();
    if (unique.isEmpty || _verificationSchema == false) return const {};
    try {
      final rows = await _client
          .from('fixed_asset_verifications')
          .select('id, number')
          .inFilter('id', unique);
      return {
        for (final r in List<Map<String, dynamic>>.from(rows as List))
          r['id'].toString(): (r['number'] as num?)?.toInt() ?? 0,
      };
    } catch (e) {
      debugPrint('[activos] getVerificationNumbers: $e');
      return const {};
    }
  }

  FixedAssetVerification _verification(dynamic response) =>
      FixedAssetVerification.fromMap(
        Map<String, dynamic>.from(response as Map),
      );

  FixedAssetVerificationLine _line(dynamic response) =>
      FixedAssetVerificationLine.fromMap(
        Map<String, dynamic>.from(response as Map),
      );

  /// Abre una verificación de [warehouseId] (null = todas las ubicaciones).
  /// Si ya había una abierta del mismo alcance, devuelve esa con
  /// `resumed: true`.
  Future<FixedAssetVerification> startVerification({
    required String businessId,
    required String? warehouseId,
    String? notes,
  }) {
    return _guardVerification(() async {
      final response = await _client.rpc(
        'fn_fixed_asset_verification_start',
        params: {
          'p_business_id': businessId,
          'p_warehouse_id': warehouseId,
          'p_notes': notes,
        },
      );
      return _verification(response);
    });
  }

  /// Anota lo encontrado de un activo. FIJA (no suma): reintentar es seguro.
  /// [foundQty] 0 = «no está».
  Future<FixedAssetVerificationLine> checkVerificationLine({
    required String verificationId,
    required String assetId,
    required int foundQty,
    FixedAssetStatus? observedStatus,
    String? notes,
  }) {
    return _guardVerification(() async {
      final response = await _client.rpc(
        'fn_fixed_asset_verification_check',
        params: {
          'p_verification_id': verificationId,
          'p_asset_id': assetId,
          'p_found_qty': foundQty,
          'p_observed_status': observedStatus?.wire,
          'p_notes': notes,
        },
      );
      return _line(response);
    });
  }

  /// Deshace una revisión hecha por error.
  Future<VerificationUncheckResult> uncheckVerificationLine({
    required String verificationId,
    required String assetId,
  }) {
    return _guardVerification(() async {
      final response = Map<String, dynamic>.from(
        await _client.rpc(
          'fn_fixed_asset_verification_uncheck',
          params: {
            'p_verification_id': verificationId,
            'p_asset_id': assetId,
          },
        ) as Map,
      );
      final raw = response['line'];
      return (
        removed: response['removed'] == true,
        line: raw is Map ? _line(raw) : null,
      );
    });
  }

  /// Registra un activo que apareció sin estar en el sistema. La ubicación
  /// la fija el servidor (la de la verificación).
  Future<VerificationAddResult> addVerificationAsset({
    required String verificationId,
    required FixedAssetDraft draft,
    String? clientRequestId,
  }) {
    return _guardVerification(() async {
      final response = Map<String, dynamic>.from(
        await _client.rpc(
          'fn_fixed_asset_verification_add_asset',
          params: {
            'p_verification_id': verificationId,
            'p_data': draft.createJson(clientRequestId: clientRequestId),
          },
        ) as Map,
      );
      return (asset: _asset(response['asset']), line: _line(response['line']));
    });
  }

  /// Cierra con las decisiones de lo que no cuadró
  /// (`VerificationCloseChoices.toDecisions`).
  Future<FixedAssetVerification> closeVerification({
    required String verificationId,
    required List<Map<String, String>> decisions,
    String? notes,
  }) {
    return _guardVerification(() async {
      final response = await _client.rpc(
        'fn_fixed_asset_verification_close',
        params: {
          'p_verification_id': verificationId,
          'p_decisions': decisions,
          'p_notes': notes,
        },
      );
      return _verification(response);
    });
  }

  /// Cancela una abierta. Lo registrado durante ella se queda.
  Future<FixedAssetVerification> cancelVerification({
    required String verificationId,
    required String reason,
  }) {
    return _guardVerification(() async {
      final response = await _client.rpc(
        'fn_fixed_asset_verification_cancel',
        params: {'p_verification_id': verificationId, 'p_reason': reason},
      );
      return _verification(response);
    });
  }
}
