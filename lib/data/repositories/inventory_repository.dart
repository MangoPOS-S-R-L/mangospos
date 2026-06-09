import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/network/connectivity_service.dart';
import '../../core/offline/inventory_offline_cache.dart';
import '../../core/offline/offline_pos_service.dart';
import '../../presentation/inventory/state/inventory_state.dart';
import '../../presentation/inventory/state/transfers_state.dart';
import '../datasources/queries/inventory_queries.dart';

class InventoryRepository {
  final SupabaseClient _client;
  final InventoryOfflineCache _cache = InventoryOfflineCache();
  final OfflinePosService _offlinePos = OfflinePosService();
  final ConnectivityService _connectivity = ConnectivityService();

  InventoryRepository(this._client);

  /// True si el último error del repo fue un fallo de conectividad y se
  /// resolvió contra el cache local. Las pantallas pueden leerlo para
  /// mostrar un disclaimer "Datos pueden estar desactualizados".
  bool _lastReadFromCache = false;
  bool get lastReadFromCache => _lastReadFromCache;

  Future<List<InventoryWarehouse>> getWarehouses(String businessId) async {
    final response = await _client
        .from(InventoryQueries.tableWarehouses)
        .select('id, name, is_main')
        .eq('business_id', businessId)
        .eq('is_active', true)
        .order('is_main', ascending: false)
        .order('name');

    return List<Map<String, dynamic>>.from(
      response,
    ).map(InventoryWarehouse.fromMap).toList(growable: false);
  }

  /// PRD 9 Fase 1B: lista todas las bodegas del business (incluye inactivas
  /// y la virtual `__IN_TRANSIT__`), con dirección y flag is_active para CRUD.
  Future<List<InventoryWarehouseDetail>> getAllWarehouses(
    String businessId,
  ) async {
    final response = await _client
        .from(InventoryQueries.tableWarehouses)
        .select('id, name, address, is_main, is_active, created_at')
        .eq('business_id', businessId)
        .order('is_main', ascending: false)
        .order('name');

    return List<Map<String, dynamic>>.from(response)
        .map(InventoryWarehouseDetail.fromMap)
        .toList(growable: false);
  }

  Future<InventoryWarehouseDetail> createWarehouse({
    required String businessId,
    required String name,
    String? address,
    bool isMain = false,
    bool isActive = true,
  }) async {
    if (isMain) {
      // Sólo una bodega principal por business: bajar la marca de la actual.
      await _client
          .from(InventoryQueries.tableWarehouses)
          .update({'is_main': false})
          .eq('business_id', businessId)
          .eq('is_main', true);
    }
    final response = await _client
        .from(InventoryQueries.tableWarehouses)
        .insert({
          'business_id': businessId,
          'name': name,
          'address': address,
          'is_main': isMain,
          'is_active': isActive,
        }..removeWhere((key, value) => value == null))
        .select('id, name, address, is_main, is_active, created_at')
        .single();
    return InventoryWarehouseDetail.fromMap(
      Map<String, dynamic>.from(response),
    );
  }

  Future<void> updateWarehouse({
    required String businessId,
    required String warehouseId,
    required String name,
    String? address,
    required bool isMain,
    required bool isActive,
  }) async {
    if (isMain) {
      await _client
          .from(InventoryQueries.tableWarehouses)
          .update({'is_main': false})
          .eq('business_id', businessId)
          .eq('is_main', true)
          .neq('id', warehouseId);
    }
    await _client
        .from(InventoryQueries.tableWarehouses)
        .update({
          'name': name,
          'address': address,
          'is_main': isMain,
          'is_active': isActive,
        })
        .eq('id', warehouseId);
  }

  Future<List<InventoryItemSummary>> getItems({
    required String businessId,
    required String warehouseId,
    String? query,
  }) async {
    // PRD 9 Fase 1D + Sprint 4 lotes: incluir costing_method, barcode y
    // tracks_lots. PRD inventario avanzado: item_classification.
    const columns =
        'id, sku, name, description, unit, cost, min_stock, max_stock, '
        'is_active, costing_method, barcode, tracks_lots, item_classification, '
        'purchase_unit, pack_size';
    final normalized = query?.trim();
    try {
      // SIEMPRE traemos el listado completo sin filtro y aplicamos el
      // query client-side. Era tentador filtrar server-side cuando había
      // `query`, pero entonces el cache offline NUNCA se hidrataba en
      // uso real (el cajero siempre busca). Con catálogos POS típicos
      // (~hasta unos miles de items) la diferencia es despreciable y
      // ganamos hidratación garantizada del snapshot offline.
      final itemsResponse = await _client
          .from(InventoryQueries.tableInventoryItems)
          .select(columns)
          .eq('business_id', businessId)
          .order('name');
      final itemsRaw = List<Map<String, dynamic>>.from(itemsResponse);

      final stockResponse = await _client
          .from(InventoryQueries.tableInventoryStock)
          .select('item_id, quantity')
          .eq('warehouse_id', warehouseId);

      final stockByItem = <String, double>{};
      for (final row in List<Map<String, dynamic>>.from(stockResponse)) {
        final itemId = row['item_id']?.toString();
        if (itemId == null || itemId.isEmpty) continue;
        final quantity = row['quantity'];
        stockByItem[itemId] = quantity is num
            ? quantity.toDouble()
            : double.tryParse(quantity?.toString() ?? '') ?? 0;
      }

      // Hidratamos el cache offline con el listado COMPLETO en cada
      // lectura exitosa (fire-and-forget). Garantiza que un cajero que
      // entra a Inventario una vez con red, queda cubierto para uso
      // offline aunque haya tipeado un query.
      unawaited(
        _cache.saveItemsSnapshot(
          businessId: businessId,
          warehouseId: warehouseId,
          itemsRaw: itemsRaw,
          stockByItem: stockByItem,
        ),
      );

      _lastReadFromCache = false;
      final filtered = (normalized == null || normalized.isEmpty)
          ? itemsRaw
          : _filterRawItems(itemsRaw, normalized);
      return filtered
          .map(
            (item) => InventoryItemSummary.fromMap(
              item,
              stock: stockByItem[item['id']?.toString() ?? ''] ?? 0,
            ),
          )
          .toList(growable: false);
    } catch (e) {
      if (!_isConnectivityError(e)) rethrow;
      final snapshot = await _cache.loadItemsSnapshot(
        businessId: businessId,
        warehouseId: warehouseId,
      );
      if (snapshot == null) rethrow;
      debugPrint('[inventory] getItems cayó al cache local: $e');
      _lastReadFromCache = true;
      final filtered = (normalized == null || normalized.isEmpty)
          ? snapshot.items
          : _filterRawItems(snapshot.items, normalized);
      return filtered
          .map(
            (item) => InventoryItemSummary.fromMap(
              item,
              stock: snapshot.stock[item['id']?.toString() ?? ''] ?? 0,
            ),
          )
          .toList(growable: false);
    }
  }

  /// Filtro case-insensitive contra name/sku/description. Compartido por
  /// el branch online (post-fetch, antes de mapear) y por el branch
  /// offline (sobre el snapshot del cache). Mantenerlo en un solo punto
  /// evita drift entre los dos paths.
  List<Map<String, dynamic>> _filterRawItems(
    List<Map<String, dynamic>> items,
    String query,
  ) {
    final lower = query.toLowerCase();
    return items.where((item) {
      final name = item['name']?.toString().toLowerCase() ?? '';
      final sku = item['sku']?.toString().toLowerCase() ?? '';
      final desc = item['description']?.toString().toLowerCase() ?? '';
      return name.contains(lower) ||
          sku.contains(lower) ||
          desc.contains(lower);
    }).toList(growable: false);
  }

  bool _isConnectivityError(Object e) {
    if (e is SocketException) return true;
    if (e is TimeoutException) return true;
    // Combinamos el flag del adapter ConnectivityService como ground
    // truth. Si el adapter dice que estamos online, NO interpretamos
    // strings vagos como "connection refused" como falla de red — eso
    // confundía RPCs que mencionan "connection" en mensajes legítimos
    // (e.g. "no connection to RPC X") y caía falsamente al cache stale.
    if (_connectivity.isConnected == true) return false;
    final msg = e.toString().toLowerCase();
    return msg.contains('socketexception') ||
        msg.contains('failed host lookup') ||
        msg.contains('network is unreachable') ||
        msg.contains('clientexception');
  }

  Future<List<InventoryMovementEntry>> getMovements({
    required String businessId,
    String? warehouseId,
    String? itemId,
    int limit = 60,
  }) async {
    final movementsResponse = warehouseId != null && warehouseId.isNotEmpty
        ? await _client
              .from(InventoryQueries.tableInventoryMovements)
              .select(
                'id, item_id, warehouse_id, movement_type, quantity, notes, reference_type, created_at',
              )
              .eq('business_id', businessId)
              .eq('warehouse_id', warehouseId)
              .order('created_at', ascending: false)
              .limit(limit)
        : itemId != null && itemId.isNotEmpty
        ? await _client
              .from(InventoryQueries.tableInventoryMovements)
              .select(
                'id, item_id, warehouse_id, movement_type, quantity, notes, reference_type, created_at',
              )
              .eq('business_id', businessId)
              .eq('item_id', itemId)
              .order('created_at', ascending: false)
              .limit(limit)
        : await _client
              .from(InventoryQueries.tableInventoryMovements)
              .select(
                'id, item_id, warehouse_id, movement_type, quantity, notes, reference_type, created_at',
              )
              .eq('business_id', businessId)
              .order('created_at', ascending: false)
              .limit(limit);
    final movementsRaw = List<Map<String, dynamic>>.from(movementsResponse);

    final itemIds = movementsRaw
        .map((row) => row['item_id']?.toString())
        .whereType<String>()
        .toSet()
        .toList(growable: false);
    final warehouseIds = movementsRaw
        .map((row) => row['warehouse_id']?.toString())
        .whereType<String>()
        .toSet()
        .toList(growable: false);

    final itemsById = <String, String>{};
    if (itemIds.isNotEmpty) {
      final items = await _client
          .from(InventoryQueries.tableInventoryItems)
          .select('id, name')
          .inFilter('id', itemIds);
      for (final row in List<Map<String, dynamic>>.from(items)) {
        itemsById[row['id']?.toString() ?? ''] = row['name']?.toString() ?? '';
      }
    }

    final warehousesById = <String, String>{};
    if (warehouseIds.isNotEmpty) {
      final warehouses = await _client
          .from(InventoryQueries.tableWarehouses)
          .select('id, name')
          .inFilter('id', warehouseIds);
      for (final row in List<Map<String, dynamic>>.from(warehouses)) {
        warehousesById[row['id']?.toString() ?? ''] =
            row['name']?.toString() ?? '';
      }
    }

    return movementsRaw
        .map(
          (row) => InventoryMovementEntry.fromMap(
            row,
            itemName: itemsById[row['item_id']?.toString() ?? ''] ?? 'Insumo',
            warehouseName:
                warehousesById[row['warehouse_id']?.toString() ?? ''] ??
                'Almacen',
          ),
        )
        .toList(growable: false);
  }

  /// Sprint 3 — Kardex.
  ///
  /// Lee la vista `v_inventory_movements_with_balance` con todos los filtros
  /// y paginación offset-based. La vista ya calcula `running_balance` por
  /// (warehouse_id, item_id) mediante window function en SQL.
  ///
  /// Notas sobre filtros:
  ///  - [itemId] limita al kardex de un insumo específico (típico uso).
  ///  - [warehouseId] limita a una bodega específica.
  ///  - [movementType] filtra por tipo ('purchase','sale','adjustment',
  ///    'transfer_in','transfer_out','waste','return').
  ///  - [createdBy] filtra por usuario que registró el movimiento.
  ///  - [from]/[to] limitan por rango de fecha de creación.
  Future<List<Map<String, dynamic>>> getKardexMovements({
    required String businessId,
    String? itemId,
    String? warehouseId,
    String? movementType,
    String? createdBy,
    DateTime? from,
    DateTime? to,
    int limit = 100,
    int offset = 0,
  }) async {
    var query = _client
        .from(InventoryQueries.viewMovementsKardex)
        .select()
        .eq('business_id', businessId);
    if (itemId != null && itemId.isNotEmpty) {
      query = query.eq('item_id', itemId);
    }
    if (warehouseId != null && warehouseId.isNotEmpty) {
      query = query.eq('warehouse_id', warehouseId);
    }
    if (movementType != null && movementType.isNotEmpty) {
      query = query.eq('movement_type', movementType);
    }
    if (createdBy != null && createdBy.isNotEmpty) {
      query = query.eq('created_by', createdBy);
    }
    if (from != null) {
      query = query.gte('created_at', from.toUtc().toIso8601String());
    }
    if (to != null) {
      query = query.lte('created_at', to.toUtc().toIso8601String());
    }
    final response = await query
        .order('created_at', ascending: false)
        .order('id', ascending: false)
        .range(offset, offset + limit - 1);
    return List<Map<String, dynamic>>.from(response);
  }

  /// Sprint 4 Inventario — Alertas de stock bajo.
  ///
  /// Lee la vista `v_inventory_low_stock`. Cada fila trae el insumo, su
  /// stock total (excluyendo __IN_TRANSIT__), el nivel de alerta y el
  /// `shortfall` (cuánto falta para alcanzar el mínimo configurado).
  ///
  /// [alertLevel] permite filtrar por 'out_of_stock', 'critical' o 'low'.
  Future<List<Map<String, dynamic>>> getLowStockAlerts({
    required String businessId,
    String? alertLevel,
    int limit = 200,
    int offset = 0,
  }) async {
    var query = _client
        .from(InventoryQueries.viewLowStock)
        .select()
        .eq('business_id', businessId);
    if (alertLevel != null && alertLevel.isNotEmpty) {
      query = query.eq('alert_level', alertLevel);
    }
    final response = await query
        // Orden: agotados primero, después críticos, después bajos.
        // Dentro del nivel, los de mayor shortfall primero.
        .order('alert_level', ascending: true)
        .order('shortfall', ascending: false)
        .order('name', ascending: true)
        .range(offset, offset + limit - 1);
    return List<Map<String, dynamic>>.from(response);
  }

  /// Devuelve el conteo total de alertas de stock bajo para un business.
  /// Usado por el badge global del header — query liviana sin traer payloads.
  Future<int> getLowStockAlertsCount({
    required String businessId,
    String? alertLevel,
  }) async {
    var query = _client
        .from(InventoryQueries.viewLowStock)
        .select('item_id')
        .eq('business_id', businessId);
    if (alertLevel != null && alertLevel.isNotEmpty) {
      query = query.eq('alert_level', alertLevel);
    }
    final response = await query.count(CountOption.exact);
    return response.count;
  }

  /// Devuelve el desglose de stock por bodega para un insumo. Útil para
  /// mostrar "en qué bodegas hace falta" cuando el usuario expande una alerta.
  Future<List<Map<String, dynamic>>> getStockByWarehouseForItem({
    required String businessId,
    required String itemId,
  }) async {
    final response = await _client
        .from(InventoryQueries.viewStockByWarehouse)
        .select()
        .eq('business_id', businessId)
        .eq('item_id', itemId)
        .order('warehouse_is_main', ascending: false)
        .order('warehouse_name', ascending: true);
    return List<Map<String, dynamic>>.from(response);
  }

  // ── Sprint 4 Inventario — Recepción directa (sin OC) ────────────────────

  /// Lista recepciones directas desde `v_direct_receipts_log`. Filtros
  /// opcionales por status ('received' | 'cancelled') y supplier.
  Future<List<Map<String, dynamic>>> listDirectReceipts({
    required String businessId,
    String? status,
    String? supplierId,
    int limit = 50,
    int offset = 0,
  }) async {
    var query = _client
        .from(InventoryQueries.viewDirectReceiptsLog)
        .select()
        .eq('business_id', businessId);
    if (status != null && status.isNotEmpty) {
      query = query.eq('status', status);
    }
    if (supplierId != null && supplierId.isNotEmpty) {
      query = query.eq('supplier_id', supplierId);
    }
    final response = await query
        .order('created_at', ascending: false)
        .range(offset, offset + limit - 1);
    return List<Map<String, dynamic>>.from(response);
  }

  /// Carga las líneas de una recepción directa con nombre/unidad del insumo.
  Future<List<Map<String, dynamic>>> getDirectReceiptItems(
    String receiptId,
  ) async {
    final response = await _client
        .from(InventoryQueries.tableDirectReceiptItems)
        .select(
          'id, item_id, quantity, unit_cost, line_total, notes, '
          'inventory_items(name, sku, unit)',
        )
        .eq('direct_receipt_id', receiptId)
        .order('id');
    return List<Map<String, dynamic>>.from(response);
  }

  /// Crea una recepción directa: header + items + movimientos de inventario
  /// (atómico). [items] = `[{item_id, quantity, unit_cost?, notes?}]`.
  Future<Map<String, dynamic>> createDirectReceipt({
    required String businessId,
    required String warehouseId,
    required List<Map<String, dynamic>> items,
    String? supplierId,
    String? notes,
  }) async {
    final response = await _client.rpc(
      InventoryQueries.rpcDirectReceipt,
      params: {
        'p_business_id': businessId,
        'p_warehouse_id': warehouseId,
        'p_items': items,
        'p_supplier_id': supplierId,
        'p_notes': notes,
      },
    );
    return response is Map
        ? Map<String, dynamic>.from(response)
        : <String, dynamic>{};
  }

  /// Cancela una recepción directa: registra ajustes negativos por cada
  /// línea (revirtiendo el stock) y marca el header como `cancelled`.
  Future<Map<String, dynamic>> cancelDirectReceipt({
    required String receiptId,
    String? reason,
  }) async {
    final response = await _client.rpc(
      InventoryQueries.rpcDirectReceiptCancel,
      params: {
        'p_receipt_id': receiptId,
        'p_reason': reason,
      },
    );
    return response is Map
        ? Map<String, dynamic>.from(response)
        : <String, dynamic>{};
  }

  // ── Sprint 5 Inventario — Valoración + ABC ──────────────────────────────

  /// Detalle de valoración por (item × bodega). Filtros opcionales por
  /// bodega o insumo. Se ordena por value descendente.
  Future<List<Map<String, dynamic>>> getInventoryValuation({
    required String businessId,
    String? warehouseId,
    String? itemId,
  }) async {
    var query = _client
        .from(InventoryQueries.viewValuation)
        .select()
        .eq('business_id', businessId);
    if (warehouseId != null && warehouseId.isNotEmpty) {
      query = query.eq('warehouse_id', warehouseId);
    }
    if (itemId != null && itemId.isNotEmpty) {
      query = query.eq('item_id', itemId);
    }
    final response = await query
        .order('value', ascending: false)
        .order('item_name', ascending: true);
    return List<Map<String, dynamic>>.from(response);
  }

  /// Análisis de rotación: outflow, velocidad y clase (star/active/slow/dormant)
  /// por insumo en una ventana de [daysBack] días (default 30).
  Future<List<Map<String, dynamic>>> getInventoryRotation({
    required String businessId,
    int daysBack = 30,
  }) async {
    final response = await _client.rpc(
      InventoryQueries.rpcRotationAnalysis,
      params: {
        'p_business_id': businessId,
        'p_days_back': daysBack,
      },
    );
    return List<Map<String, dynamic>>.from(response as Iterable);
  }

  /// Resumen agregado por insumo con clasificación ABC. Filtro opcional
  /// por `abcClass` ('A' | 'B' | 'C' | 'no_data').
  Future<List<Map<String, dynamic>>> getInventoryValuationSummary({
    required String businessId,
    String? abcClass,
  }) async {
    var query = _client
        .from(InventoryQueries.viewValuationSummary)
        .select()
        .eq('business_id', businessId);
    if (abcClass != null && abcClass.isNotEmpty) {
      query = query.eq('abc_class', abcClass);
    }
    final response = await query
        .order('total_value', ascending: false)
        .order('item_name', ascending: true);
    return List<Map<String, dynamic>>.from(response);
  }

  // ── Sprint 4 Inventario — Lotes y vencimientos (fase 1) ─────────────────

  /// Lista lotes desde `v_inventory_lots_with_status`. Filtros opcionales:
  /// - `expiryStatus`: 'fresh' | 'warning' | 'critical' | 'expired' |
  ///                   'depleted' | 'disposed'.
  /// - `status`: 'active' | 'depleted' | 'disposed' (status crudo).
  /// - `itemId` / `warehouseId`: scope a un insumo/bodega.
  Future<List<Map<String, dynamic>>> listLots({
    required String businessId,
    String? expiryStatus,
    String? status,
    String? itemId,
    String? warehouseId,
    int limit = 100,
    int offset = 0,
  }) async {
    var query = _client
        .from(InventoryQueries.viewLotsWithStatus)
        .select()
        .eq('business_id', businessId);
    if (expiryStatus != null && expiryStatus.isNotEmpty) {
      query = query.eq('expiry_status', expiryStatus);
    }
    if (status != null && status.isNotEmpty) {
      query = query.eq('status', status);
    }
    if (itemId != null && itemId.isNotEmpty) {
      query = query.eq('item_id', itemId);
    }
    if (warehouseId != null && warehouseId.isNotEmpty) {
      query = query.eq('warehouse_id', warehouseId);
    }
    // Orden: vencidos primero (más urgente), después por fecha de vencimiento
    // ascendente (los más próximos a vencer al inicio).
    final response = await query
        .order('expiry_date', ascending: true, nullsFirst: false)
        .order('created_at', ascending: false)
        .range(offset, offset + limit - 1);
    return List<Map<String, dynamic>>.from(response);
  }

  /// Cuenta lotes activos en un estado de vencimiento dado (para badge).
  Future<int> countLotsByExpiryStatus({
    required String businessId,
    required String expiryStatus,
  }) async {
    final response = await _client
        .from(InventoryQueries.viewLotsWithStatus)
        .select('id')
        .eq('business_id', businessId)
        .eq('expiry_status', expiryStatus)
        .count(CountOption.exact);
    return response.count;
  }

  /// Marca un lote como dispuesto: revierte el saldo restante (si lo hay)
  /// como ajuste negativo en la bodega y deja el header con status=disposed.
  Future<Map<String, dynamic>> disposeLot({
    required String lotId,
    String? reason,
  }) async {
    final response = await _client.rpc(
      InventoryQueries.rpcLotDispose,
      params: {
        'p_lot_id': lotId,
        'p_reason': reason,
      },
    );
    return response is Map
        ? Map<String, dynamic>.from(response)
        : <String, dynamic>{};
  }

  /// Registra un lote manualmente (útil para inventario inicial cuando
  /// no se quiere atar el lote a un direct receipt formal).
  Future<Map<String, dynamic>> registerLot({
    required String businessId,
    required String itemId,
    required String warehouseId,
    required double quantity,
    String? lotNumber,
    DateTime? expiryDate,
    double? costPerUnit,
    String? notes,
  }) async {
    final response = await _client.rpc(
      InventoryQueries.rpcRegisterLot,
      params: {
        'p_business_id': businessId,
        'p_item_id': itemId,
        'p_warehouse_id': warehouseId,
        'p_quantity': quantity,
        'p_lot_number': lotNumber,
        'p_expiry_date': expiryDate?.toIso8601String().split('T').first,
        'p_cost_per_unit': costPerUnit,
        'p_source_type': 'manual',
        'p_source_id': null,
        'p_notes': notes,
      },
    );
    return response is Map
        ? Map<String, dynamic>.from(response)
        : <String, dynamic>{};
  }

  Future<Map<String, dynamic>> createItem({
    required String businessId,
    required String name,
    String? sku,
    String? description,
    String unit = 'unidad',
    double cost = 0,
    double minStock = 0,
    double? maxStock,
    bool isActive = true,
    String? costingMethod,
    String? barcode,
    bool tracksLots = false,
    String? itemClassification,
    String? purchaseUnit,
    double? packSize,
  }) async {
    final response = await _client
        .from(InventoryQueries.tableInventoryItems)
        .insert(
          {
            'business_id': businessId,
            'name': name,
            'sku': sku,
            'description': description,
            'unit': unit,
            'cost': cost,
            'min_stock': minStock,
            'max_stock': maxStock,
            'is_active': isActive,
            'costing_method': costingMethod,
            'barcode': barcode,
            'tracks_lots': tracksLots,
            'item_classification': itemClassification,
            'purchase_unit': purchaseUnit,
            'pack_size': packSize,
          }..removeWhere((key, value) => value == null),
        )
        .select()
        .single();

    return Map<String, dynamic>.from(response);
  }

  Future<void> updateItem({
    required String itemId,
    required String name,
    String? sku,
    String? description,
    required String unit,
    required double cost,
    required double minStock,
    double? maxStock,
    required bool isActive,
    String? costingMethod,
    String? barcode,
    bool? tracksLots,
    String? itemClassification,
    String? purchaseUnit,
    double? packSize,
  }) async {
    final payload = <String, dynamic>{
      'name': name,
      'sku': sku,
      'description': description,
      'unit': unit,
      'cost': cost,
      'min_stock': minStock,
      'max_stock': maxStock,
      'is_active': isActive,
    };
    // Campos opcionales extendidos — solo se mandan si el caller los provee
    // para no pisar valores existentes.
    if (costingMethod != null) payload['costing_method'] = costingMethod;
    if (barcode != null) payload['barcode'] = barcode;
    if (tracksLots != null) payload['tracks_lots'] = tracksLots;
    if (itemClassification != null) {
      payload['item_classification'] = itemClassification;
    }
    // Empaque: purchase_unit puede ser '' (limpiar); pack_size siempre número.
    if (purchaseUnit != null) {
      payload['purchase_unit'] = purchaseUnit.trim().isEmpty
          ? null
          : purchaseUnit.trim();
    }
    if (packSize != null) payload['pack_size'] = packSize;
    payload.removeWhere((key, value) => value == null);
    await _client
        .from(InventoryQueries.tableInventoryItems)
        .update(payload)
        .eq('id', itemId);
  }

  Future<void> recordMovement({
    required String businessId,
    required String warehouseId,
    required String itemId,
    required String movementType,
    required double quantity,
    double? costPerUnit,
    String? notes,
    String? referenceType,
  }) async {
    try {
      await _client.rpc(
        InventoryQueries.rpcRecordMovement,
        params: {
          'p_business_id': businessId,
          'p_warehouse_id': warehouseId,
          'p_item_id': itemId,
          'p_movement_type': movementType,
          'p_quantity': quantity,
          'p_cost_per_unit': costPerUnit,
          'p_notes': notes,
          'p_reference_type': referenceType,
        },
      );
    } catch (e) {
      if (!_connectivity.isConnected || _isConnectivityError(e)) {
        await _enqueueMovementOffline(
          businessId: businessId,
          warehouseId: warehouseId,
          itemId: itemId,
          movementType: movementType,
          quantity: quantity,
          costPerUnit: costPerUnit,
          notes: notes,
          referenceType: referenceType,
        );
        return;
      }
      rethrow;
    }
  }

  /// Signos de los movement_type conocidos para mantener el cache local
  /// alineado con lo que hará el server al replay. Si aparece un tipo no
  /// listado dejamos delta=0 (el cache se reconciliará al primer sync).
  ///
  /// Basado en `fn_inventory_record_movement` (migración 20260308_0016):
  /// purchase, transfer_in, return_from_customer suman; sale, waste,
  /// breakage, theft, transfer_out, return_to_supplier restan.
  static const Map<String, int> _movementSign = {
    'purchase': 1,
    'transfer_in': 1,
    'return_from_customer': 1,
    'adjustment_in': 1,
    'sale': -1,
    'waste': -1,
    'breakage': -1,
    'theft': -1,
    'expiration': -1,
    'donation': -1,
    'transfer_out': -1,
    'return_to_supplier': -1,
    'adjustment_out': -1,
  };

  Future<void> _enqueueMovementOffline({
    required String businessId,
    required String warehouseId,
    required String itemId,
    required String movementType,
    required double quantity,
    double? costPerUnit,
    String? notes,
    String? referenceType,
  }) async {
    final occurredAt = DateTime.now().toUtc();
    await _offlinePos.enqueueAction(
      businessId: businessId,
      action: {
        'type': 'inventory_movement',
        'warehouse_id': warehouseId,
        'item_id': itemId,
        'movement_type': movementType,
        'quantity': quantity,
        'cost_per_unit': costPerUnit,
        'notes': notes,
        'reference_type': referenceType,
        'occurred_at': occurredAt.toIso8601String(),
      },
    );
    final sign = _movementSign[movementType] ?? 0;
    if (sign != 0) {
      await _cache.applyStockDelta(
        businessId: businessId,
        warehouseId: warehouseId,
        itemId: itemId,
        delta: sign * quantity,
      );
    }
  }

  /// Sprint Inventario V1.1: ajuste con razón estructurada (migración 0017).
  /// Envuelve `fn_inventory_adjust` que calcula el delta server-side a partir
  /// del stock actual con FOR UPDATE (evita race con ventas concurrentes) y
  /// valida que el caller sea owner/admin/manager.
  ///
  /// [reasonCode] debe ser uno de: physical_count, breakage, expiration,
  /// theft, donation, correction, other. Si es 'other', [notes] es obligatorio.
  Future<void> adjustInventory({
    required String businessId,
    required String warehouseId,
    required String itemId,
    required double countedQuantity,
    required String reasonCode,
    String? notes,
    double? costPerUnit,
  }) async {
    try {
      await _client.rpc(
        InventoryQueries.rpcAdjustInventory,
        params: {
          'p_business_id': businessId,
          'p_warehouse_id': warehouseId,
          'p_item_id': itemId,
          'p_counted_quantity': countedQuantity,
          'p_reason_code': reasonCode,
          'p_notes': notes,
          'p_cost_per_unit': costPerUnit,
        },
      );
    } catch (e) {
      if (!_connectivity.isConnected || _isConnectivityError(e)) {
        await _offlinePos.enqueueAction(
          businessId: businessId,
          action: {
            'type': 'inventory_adjust',
            'warehouse_id': warehouseId,
            'item_id': itemId,
            'counted_quantity': countedQuantity,
            'reason_code': reasonCode,
            'notes': notes,
            'cost_per_unit': costPerUnit,
            'occurred_at': DateTime.now().toUtc().toIso8601String(),
          },
        );
        // Optimista: el conteo físico ES el stock nuevo. Lo aplicamos al
        // cache local. Si otro terminal toca el stock mientras estamos
        // offline, el server resuelve al sync (LWW por created_at del
        // movement que genera el RPC).
        await _cache.setStock(
          businessId: businessId,
          warehouseId: warehouseId,
          itemId: itemId,
          quantity: countedQuantity,
        );
        return;
      }
      rethrow;
    }
  }

  // ── PRD 9 Fase 1C: Proveedores (CRUD completo) ─────────────────────

  Future<List<InventorySupplierDetail>> getAllSuppliers(
    String businessId,
  ) async {
    final response = await _client
        .from('suppliers')
        .select(
          'id, name, rnc, contact_name, phone, email, address, '
          'payment_terms, notes, is_active, created_at',
        )
        .eq('business_id', businessId)
        .order('name');
    return List<Map<String, dynamic>>.from(response)
        .map(InventorySupplierDetail.fromMap)
        .toList(growable: false);
  }

  Future<InventorySupplierDetail> createSupplierDetailed({
    required String businessId,
    required String name,
    String? rnc,
    String? contactName,
    String? phone,
    String? email,
    String? address,
    String? paymentTerms,
    String? notes,
    bool isActive = true,
  }) async {
    final response = await _client
        .from('suppliers')
        .insert({
          'business_id': businessId,
          'name': name,
          'rnc': rnc,
          'contact_name': contactName,
          'phone': phone,
          'email': email,
          'address': address,
          'payment_terms': paymentTerms,
          'notes': notes,
          'is_active': isActive,
        }..removeWhere((key, value) => value == null || value == ''))
        .select(
          'id, name, rnc, contact_name, phone, email, address, '
          'payment_terms, notes, is_active, created_at',
        )
        .single();
    return InventorySupplierDetail.fromMap(
      Map<String, dynamic>.from(response),
    );
  }

  Future<void> updateSupplierDetailed({
    required String supplierId,
    required String name,
    String? rnc,
    String? contactName,
    String? phone,
    String? email,
    String? address,
    String? paymentTerms,
    String? notes,
    required bool isActive,
  }) async {
    await _client
        .from('suppliers')
        .update({
          'name': name,
          'rnc': rnc,
          'contact_name': contactName,
          'phone': phone,
          'email': email,
          'address': address,
          'payment_terms': paymentTerms,
          'notes': notes,
          'is_active': isActive,
        })
        .eq('id', supplierId);
  }

  // ── Sprint Inventario V1.1 Fase B — Transferencias entre bodegas ──

  /// Lista transferencias desde `v_inventory_transfers_log`. Si [status]
  /// se provee, filtra por status ('sent','received','cancelled').
  /// Soporta paginación offset-based para listas grandes.
  ///
  /// Devuelve transferencias donde el [businessId] participa como source
  /// (`from_business_id`) o como target (`to_business_id`). De esta forma
  /// el negocio activo ve tanto las transferencias que envió como las
  /// inter-sucursal entrantes que debe recibir.
  Future<List<StockTransfer>> listTransfers({
    required String businessId,
    String? status,
    int limit = 50,
    int offset = 0,
  }) async {
    final query = _client
        .from(InventoryQueries.viewTransfersLog)
        .select()
        .or('from_business_id.eq.$businessId,to_business_id.eq.$businessId');
    final filtered = status != null && status.isNotEmpty
        ? query.eq('status', status)
        : query;
    final response = await filtered
        .order('sent_at', ascending: false)
        .range(offset, offset + limit - 1);
    return List<Map<String, dynamic>>.from(response)
        .map(StockTransfer.fromLogMap)
        .toList(growable: false);
  }

  /// Carga los items de una transferencia con el nombre del insumo.
  Future<List<StockTransferItem>> getTransferItems(String transferId) async {
    final response = await _client
        .from(InventoryQueries.tableStockTransferItems)
        .select(
          'id, item_id, quantity_sent, quantity_received, '
          'cost_per_unit, variance_reason, '
          'inventory_items(name, unit)',
        )
        .eq('stock_transfer_id', transferId)
        .order('id');
    return List<Map<String, dynamic>>.from(response)
        .map(StockTransferItem.fromMap)
        .toList(growable: false);
  }

  /// Envía mercancía desde [fromWarehouseId] hacia [toWarehouseId]. Llama a
  /// `fn_inventory_transfer_send` que crea el header + 2 movements por item
  /// (transfer_out origen, transfer_in IN_TRANSIT) en transacción atómica.
  ///
  /// [items] debe ser una lista de mapas con `item_id`, `quantity` y
  /// opcionalmente `cost_per_unit`.
  ///
  /// Para una transferencia inter-sucursal (cross-business), pasa
  /// [targetBusinessId] distinto de [businessId]. En ese caso
  /// [toWarehouseId] debe pertenecer al target y el usuario debe tener rol
  /// owner/admin/manager en ambos businesses.
  Future<Map<String, dynamic>> sendTransfer({
    required String businessId,
    required String fromWarehouseId,
    required String toWarehouseId,
    required List<Map<String, dynamic>> items,
    String? notes,
    String? targetBusinessId,
  }) async {
    final response = await _client.rpc(
      InventoryQueries.rpcTransferSend,
      params: {
        'p_business_id': businessId,
        'p_from_warehouse_id': fromWarehouseId,
        'p_to_warehouse_id': toWarehouseId,
        'p_items': items,
        'p_notes': notes,
        if (targetBusinessId != null && targetBusinessId != businessId)
          'p_target_business_id': targetBusinessId,
      },
    );
    return response is Map
        ? Map<String, dynamic>.from(response)
        : <String, dynamic>{};
  }

  /// Recibe una transferencia. [receivedItems] es lista de
  /// `{transfer_item_id, quantity_received}`. Si recibido < enviado se
  /// registra automáticamente la merma como ajuste sobre IN_TRANSIT.
  Future<Map<String, dynamic>> receiveTransfer({
    required String transferId,
    required List<Map<String, dynamic>> receivedItems,
    String? varianceNotes,
  }) async {
    final response = await _client.rpc(
      InventoryQueries.rpcTransferReceive,
      params: {
        'p_transfer_id': transferId,
        'p_received_items': receivedItems,
        'p_variance_notes': varianceNotes,
      },
    );
    return response is Map
        ? Map<String, dynamic>.from(response)
        : <String, dynamic>{};
  }

  /// Cancela una transferencia en status='sent' devolviendo la mercancía
  /// desde IN_TRANSIT a la bodega origen.
  Future<Map<String, dynamic>> cancelTransfer({
    required String transferId,
    String? reason,
  }) async {
    final response = await _client.rpc(
      InventoryQueries.rpcTransferCancel,
      params: {'p_transfer_id': transferId, 'p_reason': reason},
    );
    return response is Map
        ? Map<String, dynamic>.from(response)
        : <String, dynamic>{};
  }

  /// Aprueba una transferencia en status='pending_approval'. La RPC
  /// `fn_inventory_transfer_approve` valida rol del caller, ejecuta los
  /// movimientos de stock (out de origen + in a IN_TRANSIT) y marca la
  /// orden como 'sent' con `approved_at`/`approved_by` poblados.
  Future<Map<String, dynamic>> approveTransfer({
    required String transferId,
  }) async {
    final response = await _client.rpc(
      'fn_inventory_transfer_approve',
      params: {'p_transfer_id': transferId},
    );
    return response is Map
        ? Map<String, dynamic>.from(response)
        : <String, dynamic>{};
  }

  /// PRD 9 Fase 1: invoca la RPC `bootstrap_menu_to_inventory_links` que
  /// genera, para el business, los `inventory_items` faltantes a partir
  /// del menú activo y crea las `recipes` + `recipe_ingredients` 1:1
  /// (qty=1) requeridas para que la integración con ventas resuelva
  /// menu_item → inventory_item.
  ///
  /// Retorna el JSON de la RPC: `{business_id, items_created,
  /// recipes_created, ingredients_created}`. Lanza si el caller no es
  /// owner/admin/manager (la RPC enforce backend).
  Future<Map<String, dynamic>> bootstrapMenuToInventoryLinks(
    String businessId,
  ) async {
    final response = await _client.rpc(
      'bootstrap_menu_to_inventory_links',
      params: {'p_business_id': businessId},
    );
    if (response is Map) {
      return Map<String, dynamic>.from(response);
    }
    return <String, dynamic>{};
  }
}
