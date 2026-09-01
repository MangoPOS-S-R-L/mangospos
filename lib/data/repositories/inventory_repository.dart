import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/network/connectivity_service.dart';
import '../../core/offline/inventory_offline_cache.dart';
import '../../core/offline/offline_pos_service.dart';
import '../../presentation/inventory/state/inventory_state.dart';
import '../../presentation/inventory/state/requisitions_state.dart';
import '../../presentation/inventory/state/warehouse_overview_state.dart';
import '../../presentation/inventory/state/transfers_state.dart';
import '../datasources/queries/inventory_queries.dart';

/// La escritura no falló: RLS filtró la fila y afectó 0 registros.
///
/// Postgres no lanza error cuando una policy excluye la fila de un
/// UPDATE/DELETE — la sentencia "tiene éxito" sin tocar nada. Sin esto la
/// pantalla reportaría un borrado que nunca ocurrió.
class InventoryWriteDeniedException implements Exception {
  const InventoryWriteDeniedException();

  @override
  String toString() =>
      'No tienes permiso para modificar insumos en este negocio.';
}

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
        .order('name', ascending: true);

    final rows = List<Map<String, dynamic>>.from(response);
    // Write-through, best-effort: no cambia lo que devuelve este método,
    // solo deja la copia que necesita [getCachedWarehouses] para poder
    // pintar antes de que responda la red.
    unawaited(
      _cache.saveWarehousesSnapshot(businessId: businessId, rows: rows),
    );
    return rows.map(InventoryWarehouse.fromMap).toList(growable: false);
  }

  /// Bodegas desde el caché local, SIN tocar la red. `null` si nunca se
  /// guardó una copia. Es el primer paso del arranque cache-first: los
  /// snapshots de items están indexados por bodega, así que hay que saber
  /// cuáles son antes de poder leerlos.
  Future<List<InventoryWarehouse>?> getCachedWarehouses(
    String businessId,
  ) async {
    final rows = await _cache.loadWarehousesSnapshot(businessId);
    if (rows == null || rows.isEmpty) return null;
    return rows.map(InventoryWarehouse.fromMap).toList(growable: false);
  }

  // ── F0 Almacenes por sección ────────────────────────────────────────────

  /// Columnas de siempre. Es el SELECT que corre contra un servidor que
  /// todavía no aplicó `20260901_0001_warehouse_sections`.
  static const _warehouseBaseColumns =
      'id, name, address, is_main, is_active, created_at';

  /// Columnas de siempre + las de la Fase 0, con el nombre del área y del
  /// responsable resueltos por el join de PostgREST en la misma ida.
  static const _warehouseSectionColumns =
      '$_warehouseBaseColumns, warehouse_type, production_area_id, '
      'keeper_employee_id, requires_requisition, shows_in_pos, '
      'print_areas(name), employees(first_name, last_name)';

  /// Tri-estado del soporte de almacenes por sección: `null` = no se probó,
  /// `true/false` = respuesta del esquema. Mismo criterio que los mínimos
  /// por bodega: se prueba una vez por sesión y no se vuelve a insistir.
  bool? _warehouseSectionsSupported;

  bool get warehouseSectionsSupported => _warehouseSectionsSupported == true;

  /// True si el error es "acá no existe eso": columna desconocida (42703),
  /// relación desconocida para el embed (PGRST200) o columna que no está en
  /// el caché de esquema al escribir (PGRST204). Los tres significan lo
  /// mismo para nosotros: este servidor no tiene la migración.
  static bool _isMissingSectionsSchema(Object e) {
    if (e is PostgrestException) {
      return e.code == '42703' ||
          e.code == 'PGRST200' ||
          e.code == 'PGRST204';
    }
    return false;
  }

  /// PRD 9 Fase 1B: lista todas las bodegas del business (incluye inactivas
  /// y la virtual `__IN_TRANSIT__`), con dirección y flag is_active para CRUD.
  /// F0: agrega tipo, área de producción y responsable cuando el esquema los
  /// tiene; si no, devuelve lo mismo que antes y la pantalla no se entera.
  Future<List<InventoryWarehouseDetail>> getAllWarehouses(
    String businessId,
  ) async {
    Future<List<InventoryWarehouseDetail>> run(String columns) async {
      final response = await _client
          .from(InventoryQueries.tableWarehouses)
          .select(columns)
          .eq('business_id', businessId)
          .order('is_main', ascending: false)
          .order('name');
      return List<Map<String, dynamic>>.from(response)
          .map(InventoryWarehouseDetail.fromMap)
          .toList(growable: false);
    }

    if (_warehouseSectionsSupported != false) {
      try {
        final rows = await run(_warehouseSectionColumns);
        _warehouseSectionsSupported = true;
        return rows;
      } catch (e) {
        if (!_isMissingSectionsSchema(e)) rethrow;
        _warehouseSectionsSupported = false;
        debugPrint(
          '[bodegas] sin secciones: falta la migración '
          '20260901_0001_warehouse_sections',
        );
      }
    }
    return run(_warehouseBaseColumns);
  }

  /// Campos de la Fase 0 que van en el INSERT/UPDATE. Se arman aparte para
  /// poder sacarlos de un saque cuando el servidor no los conoce.
  Map<String, dynamic> _sectionPayload({
    required WarehouseType? warehouseType,
    required String? productionAreaId,
    required String? keeperEmployeeId,
    required bool? requiresRequisition,
    required bool? showsInPos,
  }) {
    // Área y responsable van SIEMPRE, incluso en null: "sin área" es un
    // valor que hay que escribir para desasignar, no un campo ausente.
    final payload = <String, dynamic>{
      'production_area_id': productionAreaId,
      'keeper_employee_id': keeperEmployeeId,
    };
    if (warehouseType != null) {
      payload['warehouse_type'] = warehouseType.wire;
    }
    if (requiresRequisition != null) {
      payload['requires_requisition'] = requiresRequisition;
    }
    if (showsInPos != null) {
      payload['shows_in_pos'] = showsInPos;
    }
    return payload;
  }

  Future<InventoryWarehouseDetail> createWarehouse({
    required String businessId,
    required String name,
    String? address,
    bool isMain = false,
    bool isActive = true,
    WarehouseType warehouseType = WarehouseType.general,
    String? productionAreaId,
    String? keeperEmployeeId,
    bool requiresRequisition = false,
    bool showsInPos = false,
  }) async {
    if (isMain) {
      // Sólo una bodega principal por business: bajar la marca de la actual.
      await _client
          .from(InventoryQueries.tableWarehouses)
          .update({'is_main': false})
          .eq('business_id', businessId)
          .eq('is_main', true);
    }

    final base = <String, dynamic>{
      'business_id': businessId,
      'name': name,
      'address': address,
      'is_main': isMain,
      'is_active': isActive,
    }..removeWhere((key, value) => value == null);

    Future<InventoryWarehouseDetail> insert(
      Map<String, dynamic> payload,
      String columns,
    ) async {
      final response = await _client
          .from(InventoryQueries.tableWarehouses)
          .insert(payload)
          .select(columns)
          .single();
      return InventoryWarehouseDetail.fromMap(
        Map<String, dynamic>.from(response),
      );
    }

    if (_warehouseSectionsSupported != false) {
      try {
        final payload = {
          ...base,
          ..._sectionPayload(
            warehouseType: warehouseType,
            productionAreaId: productionAreaId,
            keeperEmployeeId: keeperEmployeeId,
            requiresRequisition: requiresRequisition,
            showsInPos: showsInPos,
          ),
        };
        InventoryWarehouseDetail created;
        try {
          created = await insert(payload, _warehouseSectionColumns);
        } catch (e) {
          // Servidor sin 20260901_0006: solo admite una bodega marcada.
          // Se desmarca la anterior y se reintenta, para no dejar al usuario
          // con un error que no puede resolver desde la pantalla.
          if (!_isPosSourceConflict(e)) rethrow;
          _posSourceSingleOnly = true;
          await _clearPosSource(businessId, null);
          created = await insert(payload, _warehouseSectionColumns);
        }
        _warehouseSectionsSupported = true;
        return created;
      } catch (e) {
        if (!_isMissingSectionsSchema(e)) rethrow;
        _warehouseSectionsSupported = false;
      }
    }
    return insert(base, _warehouseBaseColumns);
  }

  Future<void> updateWarehouse({
    required String businessId,
    required String warehouseId,
    required String name,
    String? address,
    required bool isMain,
    required bool isActive,
    WarehouseType? warehouseType,
    String? productionAreaId,
    String? keeperEmployeeId,
    bool? requiresRequisition,
    bool? showsInPos,
  }) async {
    if (isMain) {
      await _client
          .from(InventoryQueries.tableWarehouses)
          .update({'is_main': false})
          .eq('business_id', businessId)
          .eq('is_main', true)
          .neq('id', warehouseId);
    }

    final base = <String, dynamic>{
      'name': name,
      'address': address,
      'is_main': isMain,
      'is_active': isActive,
    };

    Future<void> write(Map<String, dynamic> payload) async {
      await _client
          .from(InventoryQueries.tableWarehouses)
          .update(payload)
          .eq('id', warehouseId);
    }

    // `warehouseType == null` = la pantalla no está editando la Fase 0
    // (llamada vieja): no se manda nada de sección y no se pisa lo guardado.
    if (warehouseType != null && _warehouseSectionsSupported != false) {
      try {
        final payload = {
          ...base,
          ..._sectionPayload(
            warehouseType: warehouseType,
            productionAreaId: productionAreaId,
            keeperEmployeeId: keeperEmployeeId,
            requiresRequisition: requiresRequisition,
            showsInPos: showsInPos,
          ),
        };
        try {
          await write(payload);
        } catch (e) {
          if (!_isPosSourceConflict(e)) rethrow;
          _posSourceSingleOnly = true;
          await _clearPosSource(businessId, warehouseId);
          await write(payload);
        }
        _warehouseSectionsSupported = true;
        return;
      } catch (e) {
        if (!_isMissingSectionsSchema(e)) rethrow;
        _warehouseSectionsSupported = false;
      }
    }
    await write(base);
  }

  /// True cuando el servidor todavía tiene el índice único de una sola
  /// bodega de punto de venta (falta `20260901_0006_pos_multi_warehouse`).
  /// La pantalla lo consulta después de guardar para poder explicarlo.
  bool _posSourceSingleOnly = false;

  bool get posSourceSingleOnly => _posSourceSingleOnly;

  /// El índice único `uq_warehouses_pos_source` protestando: este servidor
  /// no admite varias bodegas marcadas.
  static bool _isPosSourceConflict(Object e) =>
      e is PostgrestException &&
      (e.code == '23505' &&
          (e.message.contains('uq_warehouses_pos_source') ||
              (e.details?.toString().contains('uq_warehouses_pos_source') ??
                  false)));

  /// Baja la marca de punto de venta de las demás bodegas del negocio.
  /// Solo se usa como salida cuando el servidor todavía tiene el índice
  /// único: con `20260901_0006` aplicada pueden convivir varias y esto no
  /// se llama nunca.
  Future<void> _clearPosSource(String businessId, String? exceptId) async {
    var q = _client
        .from(InventoryQueries.tableWarehouses)
        .update({'shows_in_pos': false})
        .eq('business_id', businessId)
        .eq('shows_in_pos', true);
    if (exceptId != null) q = q.neq('id', exceptId);
    await q;
  }

  /// Áreas de producción del negocio, para el selector del formulario de
  /// almacén. Son las mismas `print_areas` que rutean las comandas.
  Future<List<WarehouseAssignmentOption>> getProductionAreas(
    String businessId,
  ) async {
    try {
      final rows = await _client
          .from('print_areas')
          .select('id, name')
          .eq('business_id', businessId)
          .eq('is_active', true)
          .order('name');
      return List<Map<String, dynamic>>.from(rows)
          .map((r) => WarehouseAssignmentOption(
                id: r['id']?.toString() ?? '',
                name: r['name']?.toString() ?? '',
              ))
          .where((o) => o.id.isNotEmpty && o.name.isNotEmpty)
          .toList(growable: false);
    } catch (e) {
      debugPrint('getProductionAreas error: $e');
      return const [];
    }
  }

  /// Empleados activos, para elegir el responsable del almacén.
  Future<List<WarehouseAssignmentOption>> getKeeperCandidates(
    String businessId,
  ) async {
    try {
      final rows = await _client
          .from('employees')
          .select('id, first_name, last_name')
          .eq('business_id', businessId)
          .eq('status', 'active')
          .order('first_name');
      return List<Map<String, dynamic>>.from(rows)
          .map((r) => WarehouseAssignmentOption(
                id: r['id']?.toString() ?? '',
                name: [
                  r['first_name']?.toString().trim() ?? '',
                  r['last_name']?.toString().trim() ?? '',
                ].where((p) => p.isNotEmpty).join(' '),
              ))
          .where((o) => o.id.isNotEmpty && o.name.isNotEmpty)
          .toList(growable: false);
    } catch (e) {
      debugPrint('getKeeperCandidates error: $e');
      return const [];
    }
  }

  // ── Fase 2 Bodegas — el mapa y el interior de cada almacén ─────────────

  /// Columnas del maestro de insumos. Mismas que usa la matriz de Insumos:
  /// el detalle de una bodega pinta las mismas fichas.
  static const _itemColumns =
      'id, sku, name, description, unit, cost, min_stock, max_stock, '
      'is_active, costing_method, barcode, tracks_lots, item_classification, '
      'purchase_unit, pack_size';

  /// Tri-estado del soporte de mínimos por bodega:
  /// `null` = todavía no se probó, `true/false` = respuesta del esquema.
  ///
  /// `inventory_stock.min_stock` llega con la migración
  /// `20260819_0001_warehouse_min_stock`. Mientras no esté aplicada, el
  /// servidor responde 42703 y la pantalla degrada al mínimo global en vez
  /// de romperse: la app tiene que andar contra las dos versiones del
  /// esquema porque los negocios se actualizan en tiempos distintos.
  bool? _warehouseMinSupported;

  bool get warehouseMinStockSupported => _warehouseMinSupported == true;

  /// True si el error es "la columna no existe" (esquema viejo).
  static bool _isUndefinedColumn(Object e) {
    if (e is PostgrestException) {
      if (e.code == '42703') return true;
      return e.message.contains('min_stock') &&
          e.message.toLowerCase().contains('does not exist');
    }
    return false;
  }

  /// Filas de `inventory_stock` de las bodegas pedidas, con el mínimo propio
  /// cuando el esquema lo tiene. Deja registrado el soporte en
  /// [_warehouseMinSupported] para no volver a probar en la sesión.
  Future<List<Map<String, dynamic>>> _fetchStockRows(
    List<String> warehouseIds,
  ) async {
    if (warehouseIds.isEmpty) return const [];
    if (_warehouseMinSupported != false) {
      try {
        final response = await _client
            .from(InventoryQueries.tableInventoryStock)
            .select('item_id, warehouse_id, quantity, last_updated, min_stock')
            .inFilter('warehouse_id', warehouseIds);
        _warehouseMinSupported = true;
        return List<Map<String, dynamic>>.from(response);
      } catch (e) {
        if (!_isUndefinedColumn(e)) rethrow;
        _warehouseMinSupported = false;
        debugPrint(
          '[bodegas] sin mínimos por bodega: falta la migración '
          '20260819_0001_warehouse_min_stock',
        );
      }
    }
    final response = await _client
        .from(InventoryQueries.tableInventoryStock)
        .select('item_id, warehouse_id, quantity, last_updated')
        .inFilter('warehouse_id', warehouseIds);
    return List<Map<String, dynamic>>.from(response);
  }

  /// Mapa de bodegas: cada almacén con el valor de lo que guarda, cuántos
  /// insumos viven ahí, qué está bajo mínimo local, qué viene en camino y
  /// hace cuánto que no se cuenta.
  ///
  /// Cinco lecturas, cuatro en paralelo: el maestro de insumos, el stock de
  /// todas las bodegas, las transferencias en camino y el último conteo
  /// físico de cada una. Las dos últimas son señales de apoyo: si fallan
  /// (vista ausente en un despliegue viejo, permisos) la pantalla sigue
  /// mostrando lo importante en vez de caerse entera.
  Future<InventoryWarehousesOverview> getWarehousesOverview(
    String businessId,
  ) async {
    final warehouses = await getAllWarehouses(businessId);
    final ids = warehouses.map((w) => w.id).toList(growable: false);

    final results = await Future.wait<dynamic>([
      _client
          .from(InventoryQueries.tableInventoryItems)
          .select(_itemColumns)
          .eq('business_id', businessId)
          .order('name', ascending: true),
      _fetchStockRows(ids),
      _pendingTransfersOrEmpty(businessId),
      _lastCompletedCounts(businessId),
    ]);

    final itemsRaw = List<Map<String, dynamic>>.from(results[0]);
    final stockRows = List<Map<String, dynamic>>.from(results[1]);
    final transfers = results[2] as List<StockTransfer>;
    final lastCounts = results[3] as Map<String, DateTime>;

    final stockByWarehouse = <String, Map<String, double>>{};
    final minByWarehouse = <String, Map<String, double>>{};
    final lastActivity = <String, DateTime>{};
    for (final row in stockRows) {
      final warehouseId = row['warehouse_id']?.toString();
      final itemId = row['item_id']?.toString();
      if (warehouseId == null || warehouseId.isEmpty) continue;
      if (itemId == null || itemId.isEmpty) continue;
      (stockByWarehouse[warehouseId] ??= <String, double>{})[itemId] = _toQty(
        row['quantity'],
      );
      final min = row['min_stock'];
      if (min != null) {
        (minByWarehouse[warehouseId] ??= <String, double>{})[itemId] = _toQty(
          min,
        );
      }
      final updated = DateTime.tryParse(row['last_updated']?.toString() ?? '');
      if (updated != null) {
        final current = lastActivity[warehouseId];
        if (current == null || updated.isAfter(current)) {
          lastActivity[warehouseId] = updated;
        }
      }
    }

    final incoming = <String, int>{};
    for (final transfer in transfers) {
      incoming[transfer.toWarehouseId] =
          (incoming[transfer.toWarehouseId] ?? 0) + 1;
    }

    final items = itemsRaw
        .map((raw) => InventoryItemSummary.fromMap(raw, stock: 0))
        .toList(growable: false);

    return InventoryWarehousesOverview.build(
      warehouses: warehouses,
      items: items,
      stockByWarehouse: stockByWarehouse,
      minByWarehouse: minByWarehouse,
      lastActivityByWarehouse: lastActivity,
      lastCountByWarehouse: lastCounts,
      incomingTransfers: incoming,
      transfersInTransit: transfers.length,
      perWarehouseMinSupported: _warehouseMinSupported == true,
    );
  }

  /// El mapa reconstruido desde los snapshots locales, SIN tocar la red.
  /// `null` si nunca se guardó una copia.
  ///
  /// Trae menos que la lectura fresca —el caché no guarda transferencias ni
  /// conteos— pero alcanza para pintar las tarjetas con su valor y sus
  /// insumos mientras responde el servidor.
  Future<InventoryWarehousesOverview?> getCachedWarehousesOverview(
    String businessId,
  ) async {
    final cached = await getCachedWarehouses(businessId);
    if (cached == null || cached.isEmpty) return null;
    final visible = cached
        .where((w) => w.name != '__IN_TRANSIT__')
        .toList(growable: false);
    if (visible.isEmpty) return null;

    final matrix = await getCachedItemsMatrix(
      businessId: businessId,
      warehouseIds: visible.map((w) => w.id).toList(growable: false),
    );
    if (matrix == null || matrix.items.isEmpty) return null;

    final stockByWarehouse = <String, Map<String, double>>{};
    matrix.byWarehouse.forEach((itemId, row) {
      row.forEach((warehouseId, qty) {
        (stockByWarehouse[warehouseId] ??= <String, double>{})[itemId] = qty;
      });
    });

    // El snapshot de bodegas sólo guarda id/nombre/principal: lo que falta
    // (dirección, estado) se completa en la lectura fresca. Se asume activa
    // porque el snapshot se hidrata desde `getWarehouses`, que ya filtra.
    return InventoryWarehousesOverview.build(
      warehouses: visible
          .map(
            (w) => InventoryWarehouseDetail(
              id: w.id,
              name: w.name,
              address: '',
              isMain: w.isMain,
              isActive: true,
              createdAt: null,
            ),
          )
          .toList(growable: false),
      items: matrix.items,
      stockByWarehouse: stockByWarehouse,
      perWarehouseMinSupported: _warehouseMinSupported == true,
      fromCache: true,
    );
  }

  /// Transferencias enviadas y sin recibir. Señal de apoyo: si la vista
  /// falla, el mapa se dibuja igual sin la franja de tránsito.
  Future<List<StockTransfer>> _pendingTransfersOrEmpty(
    String businessId,
  ) async {
    try {
      return await listTransfers(
        businessId: businessId,
        status: StockTransferStatus.sent.wire,
        limit: 200,
      );
    } catch (e) {
      debugPrint('[bodegas] no se pudieron leer las transferencias: $e');
      return const [];
    }
  }

  /// warehouseId → fecha del último conteo físico COMPLETADO.
  Future<Map<String, DateTime>> _lastCompletedCounts(String businessId) async {
    try {
      final response = await _client
          .from('v_physical_count_sessions_summary')
          .select('warehouse_id, completed_at')
          .eq('business_id', businessId)
          .eq('status', 'completed')
          .order('completed_at', ascending: false)
          .limit(200);
      final result = <String, DateTime>{};
      for (final row in List<Map<String, dynamic>>.from(response)) {
        final warehouseId = row['warehouse_id']?.toString();
        final completed = DateTime.tryParse(
          row['completed_at']?.toString() ?? '',
        );
        if (warehouseId == null || warehouseId.isEmpty || completed == null) {
          continue;
        }
        // Vienen ordenados desc: la primera aparición es la más reciente.
        result.putIfAbsent(warehouseId, () => completed);
      }
      return result;
    } catch (e) {
      debugPrint('[bodegas] no se pudieron leer los conteos físicos: $e');
      return const {};
    }
  }

  /// Mínimos PROPIOS de una bodega (itemId → mínimo). Vacío si el esquema
  /// todavía no los soporta.
  Future<Map<String, double>> getWarehouseMinStock(String warehouseId) async {
    if (_warehouseMinSupported == false) return const {};
    try {
      final response = await _client
          .from(InventoryQueries.tableInventoryStock)
          .select('item_id, min_stock')
          .eq('warehouse_id', warehouseId)
          .not('min_stock', 'is', null);
      _warehouseMinSupported = true;
      final result = <String, double>{};
      for (final row in List<Map<String, dynamic>>.from(response)) {
        final itemId = row['item_id']?.toString();
        if (itemId == null || itemId.isEmpty) continue;
        result[itemId] = _toQty(row['min_stock']);
      }
      return result;
    } catch (e) {
      if (!_isUndefinedColumn(e)) rethrow;
      _warehouseMinSupported = false;
      return const {};
    }
  }

  /// Fija (o borra, con [minStock] en null) el mínimo de un insumo en una
  /// bodega. Va por RPC porque `inventory_stock` no tiene policy de
  /// escritura para `authenticated`: un update directo se iría en silencio.
  Future<void> setWarehouseMinStock({
    required String warehouseId,
    required String itemId,
    required double? minStock,
  }) async {
    await _client.rpc(
      'fn_inventory_set_warehouse_min_stock',
      params: {
        'p_warehouse_id': warehouseId,
        'p_item_id': itemId,
        'p_min_stock': minStock,
      },
    );
    _warehouseMinSupported = true;
  }

  /// Copia la LISTA de insumos de [sourceWarehouseId] (o de todo el catálogo,
  /// si va nulo) a [targetWarehouseId], creando cada fila con existencia 0.
  ///
  /// Nunca copia cantidades: duplicar el stock inventaría mercancía que no
  /// existe y descuadraría la valuación del negocio. La bodega nueva arranca
  /// en cero y se llena contando, recibiendo o transfiriendo.
  ///
  /// Devuelve cuántos insumos se agregaron, o `null` si el esquema todavía no
  /// tiene la función (migración `20260819_0002_copy_warehouse_items` sin
  /// aplicar) — la pantalla lo distingue de "no había nada que copiar".
  Future<int?> copyWarehouseItems({
    required String targetWarehouseId,
    String? sourceWarehouseId,
    bool onlyActive = true,
  }) async {
    try {
      final response = await _client.rpc(
        'fn_inventory_copy_warehouse_items',
        params: {
          'p_target_warehouse_id': targetWarehouseId,
          'p_source_warehouse_id': sourceWarehouseId,
          'p_only_active': onlyActive,
        },
      );
      if (response is num) return response.toInt();
      return int.tryParse(response?.toString() ?? '') ?? 0;
    } catch (e) {
      if (_isMissingFunction(e)) {
        debugPrint(
          '[bodegas] no se pudo copiar la lista: falta la migración '
          '20260819_0002_copy_warehouse_items',
        );
        return null;
      }
      rethrow;
    }
  }

  /// True si el error es "esa función no existe" (esquema viejo). PostgREST
  /// contesta `PGRST202` cuando no la encuentra en su caché de esquema, y
  /// Postgres `42883` cuando la firma no coincide.
  static bool _isMissingFunction(Object e) {
    if (e is PostgrestException) {
      if (e.code == 'PGRST202' || e.code == '42883') return true;
      final message = e.message.toLowerCase();
      return message.contains('fn_inventory_copy_warehouse_items') &&
          (message.contains('does not exist') ||
              message.contains('could not find'));
    }
    return false;
  }

  /// Cuántos movimientos de entrada y de salida hubo en la bodega desde
  /// [since]. Dos conteos exactos en el servidor: la alternativa era traer
  /// las filas y contarlas acá, que miente en cuanto pasan del límite.
  Future<({int inbound, int outbound})> getMovementCounts({
    required String businessId,
    required String warehouseId,
    required DateTime since,
  }) async {
    final iso = since.toUtc().toIso8601String();
    final responses = await Future.wait([
      _client
          .from(InventoryQueries.tableInventoryMovements)
          .select('id')
          .eq('business_id', businessId)
          .eq('warehouse_id', warehouseId)
          .gte('created_at', iso)
          .gt('quantity', 0)
          .count(CountOption.exact),
      _client
          .from(InventoryQueries.tableInventoryMovements)
          .select('id')
          .eq('business_id', businessId)
          .eq('warehouse_id', warehouseId)
          .gte('created_at', iso)
          .lt('quantity', 0)
          .count(CountOption.exact),
    ]);
    return (inbound: responses[0].count, outbound: responses[1].count);
  }

  static double _toQty(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? 0;
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

      // Filtro POR ALMACÉN: la lista muestra solo los insumos PRESENTES en el
      // almacén seleccionado (con fila en inventory_stock, aunque la cantidad
      // sea 0). En el almacén PRINCIPAL además incluimos los "huérfanos" (sin
      // stock en NINGÚN almacén del negocio) para que insumos recién creados o
      // sin asignar no desaparezcan de la vista.
      final warehousesRaw = await _client
          .from(InventoryQueries.tableWarehouses)
          .select('id, is_main')
          .eq('business_id', businessId);
      final allWarehouseIds = <String>[];
      var selectedIsMain = false;
      for (final w in List<Map<String, dynamic>>.from(warehousesRaw)) {
        final wid = w['id']?.toString();
        if (wid == null || wid.isEmpty) continue;
        allWarehouseIds.add(wid);
        if (wid == warehouseId && w['is_main'] == true) selectedIsMain = true;
      }

      var orphanItemIds = const <String>{};
      if (selectedIsMain && allWarehouseIds.isNotEmpty) {
        final anyRowResponse = await _client
            .from(InventoryQueries.tableInventoryStock)
            .select('item_id')
            .inFilter('warehouse_id', allWarehouseIds);
        final withRow = <String>{};
        for (final r in List<Map<String, dynamic>>.from(anyRowResponse)) {
          final iid = r['item_id']?.toString();
          if (iid != null && iid.isNotEmpty) withRow.add(iid);
        }
        orphanItemIds = itemsRaw
            .map((i) => i['id']?.toString() ?? '')
            .where((id) => id.isNotEmpty && !withRow.contains(id))
            .toSet();
      }

      bool presentInWarehouse(String id) =>
          stockByItem.containsKey(id) || orphanItemIds.contains(id);

      final present = itemsRaw
          .where((i) => presentInWarehouse(i['id']?.toString() ?? ''))
          .toList(growable: false);
      final filtered = (normalized == null || normalized.isEmpty)
          ? present
          : _filterRawItems(present, normalized);
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
      // Offline: el snapshot guarda el stock del almacén consultado, así que
      // mostramos los insumos PRESENTES en él (los huérfanos del principal
      // requieren red para resolverse y reaparecen al reconectar).
      final present = snapshot.items
          .where(
            (i) => snapshot.stock.containsKey(i['id']?.toString() ?? ''),
          )
          .toList(growable: false);
      final filtered = (normalized == null || normalized.isEmpty)
          ? present
          : _filterRawItems(present, normalized);
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

  /// Un insumo por id, para EDITAR su ficha desde una pantalla que no carga
  /// el catálogo completo.
  ///
  /// POR QUÉ NO ALCANZA [getItems]: ese listado devuelve lo PRESENTE en una
  /// bodega (más los huérfanos, si la bodega es la principal). Las líneas de
  /// un conteo físico, en cambio, incluyen TODOS los insumos activos del
  /// negocio, así que hay renglones que el listado no trae. Sin esto, editar
  /// justo el insumo que falta corregir sería imposible.
  ///
  /// OJO: `stock` vuelve en 0 — no se consulta existencia. Sirve para el
  /// formulario del maestro, no para mostrar cantidades.
  Future<InventoryItemSummary?> getItemById(String itemId) async {
    const columns =
        'id, sku, name, description, unit, cost, min_stock, max_stock, '
        'is_active, costing_method, barcode, tracks_lots, item_classification, '
        'purchase_unit, pack_size';
    final row = await _client
        .from(InventoryQueries.tableInventoryItems)
        .select(columns)
        .eq('id', itemId)
        .maybeSingle();
    if (row == null) return null;
    return InventoryItemSummary.fromMap(
      Map<String, dynamic>.from(row),
      stock: 0,
    );
  }

  /// Insumos del negocio con el stock DESGLOSADO por bodega (Insumos v2).
  ///
  /// A diferencia de [getItems] —que devuelve lo PRESENTE en una bodega—
  /// acá se trae el maestro completo del negocio más la matriz
  /// (insumo × bodega) en dos lecturas. La pantalla necesita las dos cosas:
  /// una fila por insumo y una columna por bodega, incluyendo los ceros
  /// ("acá no hay") y los insumos que todavía no tienen fila en ninguna.
  ///
  /// [warehouseIds] son las bodegas VISIBLES (activas, sin `__IN_TRANSIT__`).
  /// El total de cada insumo es la suma de esas bodegas, así que la mercancía
  /// en tránsito no infla el stock del negocio.
  Future<InventoryStockMatrix> getItemsMatrix({
    required String businessId,
    required List<String> warehouseIds,
    String? query,
  }) async {
    const columns =
        'id, sku, name, description, unit, cost, min_stock, max_stock, '
        'is_active, costing_method, barcode, tracks_lots, item_classification, '
        'purchase_unit, pack_size';
    final normalized = query?.trim();

    double toQty(dynamic value) {
      if (value is num) return value.toDouble();
      return double.tryParse(value?.toString() ?? '') ?? 0;
    }

    InventoryStockMatrix build(
      List<Map<String, dynamic>> itemsRaw,
      Map<String, Map<String, double>> matrix, {
      required bool fromCache,
    }) {
      final filtered = (normalized == null || normalized.isEmpty)
          ? itemsRaw
          : _filterRawItems(itemsRaw, normalized);
      return InventoryStockMatrix(
        items: filtered.map((item) {
          final id = item['id']?.toString() ?? '';
          final row = matrix[id];
          final total = row == null
              ? 0.0
              : row.values.fold<double>(0, (acc, qty) => acc + qty);
          return InventoryItemSummary.fromMap(item, stock: total);
        }).toList(growable: false),
        byWarehouse: matrix,
        fromCache: fromCache,
      );
    }

    try {
      // Las dos lecturas son INDEPENDIENTES: el stock filtra por bodega, no
      // por los items. En serie sumaban dos viajes completos al servidor
      // antes de poder pintar nada, así que van con `Future.wait`.
      //
      // Tiene que ser `Future.wait` y no dos `await` seguidos: los builders
      // de postgrest son perezosos —la petición sale recién con el primer
      // `then`—, así que crearlos por separado no adelanta trabajo.
      //
      // `ascending: true` EXPLÍCITO: postgrest-dart declara
      // `order(column, {bool ascending = false})`, al revés que PostgREST.
      // Sin esto la lista salía de la Z a la A.
      final responses = await Future.wait<dynamic>([
        _client
            .from(InventoryQueries.tableInventoryItems)
            .select(columns)
            .eq('business_id', businessId)
            .order('name', ascending: true),
        if (warehouseIds.isNotEmpty)
          _client
              .from(InventoryQueries.tableInventoryStock)
              .select('item_id, warehouse_id, quantity')
              .inFilter('warehouse_id', warehouseIds),
      ]);
      final itemsRaw = List<Map<String, dynamic>>.from(responses.first);

      final matrix = <String, Map<String, double>>{};
      final byWarehouse = <String, Map<String, double>>{
        for (final id in warehouseIds) id: <String, double>{},
      };

      if (responses.length > 1) {
        for (final row in List<Map<String, dynamic>>.from(responses[1])) {
          final itemId = row['item_id']?.toString();
          final warehouseId = row['warehouse_id']?.toString();
          if (itemId == null || itemId.isEmpty) continue;
          if (warehouseId == null || warehouseId.isEmpty) continue;
          final qty = toQty(row['quantity']);
          (matrix[itemId] ??= <String, double>{})[warehouseId] = qty;
          byWarehouse[warehouseId]?[itemId] = qty;
        }
      }

      // Hidratamos el cache offline con el MISMO formato por bodega que usa
      // `getItems`: así Insumos y el cuadre de stock comparten snapshot en
      // vez de mantener dos representaciones que se desincronizan.
      for (final entry in byWarehouse.entries) {
        unawaited(
          _cache.saveItemsSnapshot(
            businessId: businessId,
            warehouseId: entry.key,
            itemsRaw: itemsRaw,
            stockByItem: entry.value,
          ),
        );
      }
      _lastReadFromCache = false;
      return build(itemsRaw, matrix, fromCache: false);
    } catch (e) {
      if (!_isConnectivityError(e)) rethrow;

      // Offline: servimos la última copia local. Si tampoco hay, propagamos
      // el error original.
      final cached = await getCachedItemsMatrix(
        businessId: businessId,
        warehouseIds: warehouseIds,
        query: normalized,
      );
      if (cached == null) rethrow;
      debugPrint('[inventory] getItemsMatrix cayó al cache local: $e');
      _lastReadFromCache = true;
      return cached;
    }
  }

  /// Matriz reconstruida desde los snapshots locales, SIN tocar la red.
  /// `null` si no hay ninguna copia guardada.
  ///
  /// La usan dos caminos distintos: el arranque cache-first (pintar algo
  /// real de inmediato mientras la red responde) y el fallback de
  /// [getItemsMatrix] cuando no hay conexión. La matriz sale marcada con
  /// `fromCache: true` en ambos — quien la consume decide si eso significa
  /// "estás offline" o "todavía estoy refrescando".
  Future<InventoryStockMatrix?> getCachedItemsMatrix({
    required String businessId,
    required List<String> warehouseIds,
    String? query,
  }) async {
    // El maestro de insumos es el mismo en todos los snapshots, así que
    // basta el primero que exista; el stock sí se toma bodega por bodega.
    List<Map<String, dynamic>>? itemsRaw;
    final matrix = <String, Map<String, double>>{};
    for (final warehouseId in warehouseIds) {
      final snapshot = await _cache.loadItemsSnapshot(
        businessId: businessId,
        warehouseId: warehouseId,
      );
      if (snapshot == null) continue;
      itemsRaw ??= snapshot.items;
      snapshot.stock.forEach((itemId, qty) {
        (matrix[itemId] ??= <String, double>{})[warehouseId] = qty;
      });
    }
    if (itemsRaw == null) return null;

    final normalized = query?.trim();
    final filtered = (normalized == null || normalized.isEmpty)
        ? itemsRaw
        : _filterRawItems(itemsRaw, normalized);
    return InventoryStockMatrix(
      items: filtered.map((item) {
        final id = item['id']?.toString() ?? '';
        final row = matrix[id];
        final total = row == null
            ? 0.0
            : row.values.fold<double>(0, (acc, qty) => acc + qty);
        return InventoryItemSummary.fromMap(item, stock: total);
      }).toList(growable: false),
      byWarehouse: matrix,
      fromCache: true,
    );
  }

  /// Filtro case-insensitive contra name/sku/description/barcode.
  /// Compartido por el branch online (post-fetch, antes de mapear) y por el
  /// branch offline (sobre el snapshot del cache). Mantenerlo en un solo
  /// punto evita drift entre los dos paths.
  ///
  /// El barcode entra al filtro porque la barra de búsqueda de Insumos
  /// acepta el disparo de la pistola: lo escaneado llega como texto y tiene
  /// que resolver al insumo, no quedar en "sin coincidencias".
  List<Map<String, dynamic>> _filterRawItems(
    List<Map<String, dynamic>> items,
    String query,
  ) {
    final lower = query.toLowerCase();
    return items.where((item) {
      final name = item['name']?.toString().toLowerCase() ?? '';
      final sku = item['sku']?.toString().toLowerCase() ?? '';
      final desc = item['description']?.toString().toLowerCase() ?? '';
      final barcode = item['barcode']?.toString().toLowerCase() ?? '';
      return name.contains(lower) ||
          sku.contains(lower) ||
          desc.contains(lower) ||
          (barcode.isNotEmpty && barcode.contains(lower));
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
  /// opcionales por status ('received' | 'cancelled'), supplier y búsqueda
  /// libre (número de recepción, proveedor o bodega).
  Future<List<Map<String, dynamic>>> listDirectReceipts({
    required String businessId,
    String? status,
    String? supplierId,
    String? search,
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
    final term = search?.trim() ?? '';
    if (term.isNotEmpty) {
      // Coma/paréntesis rompen la sintaxis de or() de PostgREST y % es
      // comodín de ilike: se eliminan del término en vez de escaparlos.
      final safe = term.replaceAll(RegExp(r'[,()%]'), '');
      if (safe.isNotEmpty) {
        query = query.or(
          'receipt_number.ilike.%$safe%,'
          'supplier_name.ilike.%$safe%,'
          'warehouse_name.ilike.%$safe%',
        );
      }
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

  /// Inventario multisucursal (panel de totales): stock de cada producto
  /// —emparejado por SKU— en todas las sucursales del mismo dueño, con desglose
  /// por sucursal + total + valuación. Devuelve el JSON crudo del RPC
  /// (`{branches: [...], products: [...]}`).
  Future<Map<String, dynamic>> getConsolidatedInventory({
    required String businessId,
  }) async {
    final response = await _client.rpc(
      'get_consolidated_inventory',
      params: {'_anchor_business_id': businessId},
    );
    if (response is Map) return Map<String, dynamic>.from(response);
    return <String, dynamic>{'branches': <dynamic>[], 'products': <dynamic>[]};
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

    final newItemId = response['id']?.toString();
    // Presencia (qty 0) en el almacén PRINCIPAL para que el insumo nuevo
    // aparezca de inmediato en la lista del principal aunque no tenga stock
    // inicial. Idempotente: si ya existe la fila, no la pisa. Best-effort.
    if (newItemId != null && newItemId.isNotEmpty) {
      try {
        final mainW = await _client
            .from(InventoryQueries.tableWarehouses)
            .select('id')
            .eq('business_id', businessId)
            .eq('is_main', true)
            .order('created_at')
            .limit(1)
            .maybeSingle();
        final mainId = mainW?['id']?.toString();
        if (mainId != null && mainId.isNotEmpty) {
          await _client
              .from(InventoryQueries.tableInventoryStock)
              .upsert(
                {'warehouse_id': mainId, 'item_id': newItemId, 'quantity': 0},
                onConflict: 'warehouse_id,item_id',
                ignoreDuplicates: true,
              );
        }
      } catch (e) {
        debugPrint(
          'createItem: no se pudo asegurar presencia en almacén principal: $e',
        );
      }
    }

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

  /// Activa/desactiva un insumo (soft-delete). Update mínimo de `is_active`
  /// para no exigir el resto de campos requeridos por [updateItem].
  Future<void> setItemActive({
    required String itemId,
    required bool isActive,
  }) async {
    // `.select()` devuelve las filas afectadas: si RLS filtra la fila, el
    // update no falla, simplemente no toca nada. Sin esto el error es mudo.
    final rows = await _client
        .from(InventoryQueries.tableInventoryItems)
        .update({'is_active': isActive})
        .eq('id', itemId)
        .select('id');
    if ((rows as List).isEmpty) {
      throw const InventoryWriteDeniedException();
    }
  }

  /// Elimina un insumo. Si nunca tuvo movimientos en el kardex intenta el
  /// borrado real (limpiando antes sus filas de stock, que sin movimientos
  /// están en 0); si tiene historial o lo referencian recetas/compras/
  /// producción (FK restrict), cae a soft-delete via [setItemActive].
  /// Devuelve `true` si el borrado fue real, `false` si quedó desactivado.
  Future<bool> deleteItem({required String itemId}) async {
    final movements = await _client
        .from(InventoryQueries.tableInventoryMovements)
        .select('id')
        .eq('item_id', itemId)
        .limit(1);
    final hasHistory = (movements as List).isNotEmpty;

    if (!hasHistory) {
      try {
        await _client
            .from(InventoryQueries.tableInventoryStock)
            .delete()
            .eq('item_id', itemId);
        // Igual que en setItemActive: un DELETE bloqueado por RLS no lanza
        // excepción, borra 0 filas. Pedimos las filas borradas para saber si
        // de verdad pasó algo y no reportar un éxito falso.
        final deleted = await _client
            .from(InventoryQueries.tableInventoryItems)
            .delete()
            .eq('id', itemId)
            .select('id');
        if ((deleted as List).isNotEmpty) return true;
        throw const InventoryWriteDeniedException();
      } on PostgrestException catch (e) {
        // 23503 = foreign_key_violation: lo referencia una receta, compra,
        // producción, etc. → conservamos el registro y lo desactivamos.
        if (e.code != '23503') rethrow;
      }
    }

    await setItemActive(itemId: itemId, isActive: false);
    return false;
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

  // El ALTA y la EDICIÓN de la ficha viven en `SuppliersRepository`
  // (Fase 3 Proveedores). Estaban acá como `createSupplierDetailed` /
  // `updateSupplierDetailed` y se quitaron al quedar sin llamadores: dos
  // caminos de escritura sobre `suppliers` divergían en silencio, porque
  // sólo el nuevo guarda las condiciones estructuradas. La lectura
  // `getAllSuppliers` se queda: la usa el diálogo de recepción directa.

  // ── Sprint Inventario V1.1 Fase B — Transferencias entre bodegas ──

  /// Lista transferencias desde `v_inventory_transfers_log`. Si [status]
  /// se provee, filtra por status ('sent','received','cancelled').
  /// Soporta paginación offset-based para listas grandes.
  ///
  /// Devuelve transferencias donde el [businessId] participa como source
  /// (`from_business_id`) o como target (`to_business_id`). De esta forma
  /// el negocio activo ve tanto las transferencias que envió como las
  /// inter-sucursal entrantes que debe recibir.
  /// Nombre del negocio para encabezar documentos. `businesses` NO tiene
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
      debugPrint('getBusinessName error: $e');
      return 'Negocio';
    }
  }

  // ── F2 Requisiciones ────────────────────────────────────────────────────

  /// Columnas de la bandeja. Las dos bodegas se resuelven por el nombre de su
  /// FK porque `requisitions` apunta DOS veces a `warehouses`: sin
  /// desambiguar, PostgREST no sabe cuál es cuál.
  static const _requisitionColumns =
      'id, business_id, code, status, from_warehouse_id, to_warehouse_id, '
      'transfer_id, requested_at, dispatched_at, received_at, cancel_reason, '
      'notes, '
      'from_warehouse:warehouses!requisitions_from_warehouse_id_fkey(name), '
      'to_warehouse:warehouses!requisitions_to_warehouse_id_fkey(name)';

  /// True si el error es "acá no existe la tabla/relación": el servidor no
  /// aplicó `20260902_0001_requisitions`. La pantalla lo explica en vez de
  /// mostrar un error crudo.
  static bool _isMissingRequisitions(Object e) {
    if (e is PostgrestException) {
      return e.code == '42P01' ||
          e.code == 'PGRST205' ||
          e.code == 'PGRST202' ||
          e.code == 'PGRST200';
    }
    return false;
  }

  bool _requisitionsSupported = true;
  bool get requisitionsSupported => _requisitionsSupported;

  Future<List<Requisition>> listRequisitions({
    required String businessId,
    List<RequisitionStatus>? statuses,
    String? fromWarehouseId,
    String? toWarehouseId,
    int limit = 50,
  }) async {
    try {
      var q = _client
          .from(InventoryQueries.tableRequisitions)
          .select(_requisitionColumns)
          .eq('business_id', businessId);
      if (statuses != null && statuses.isNotEmpty) {
        q = q.inFilter(
          'status',
          statuses.map((s) => s.wire).toList(growable: false),
        );
      }
      if (fromWarehouseId != null) {
        q = q.eq('from_warehouse_id', fromWarehouseId);
      }
      if (toWarehouseId != null) q = q.eq('to_warehouse_id', toWarehouseId);
      final rows =
          await q.order('requested_at', ascending: false).limit(limit);
      _requisitionsSupported = true;
      return List<Map<String, dynamic>>.from(rows)
          .map(Requisition.fromMap)
          .toList(growable: false);
    } catch (e) {
      if (!_isMissingRequisitions(e)) rethrow;
      _requisitionsSupported = false;
      debugPrint(
        '[requisiciones] falta la migración 20260902_0001_requisitions',
      );
      return const [];
    }
  }

  Future<List<RequisitionLine>> getRequisitionLines(
    String requisitionId,
  ) async {
    final rows = await _client
        .from(InventoryQueries.tableRequisitionLines)
        .select(
          'id, item_id, requested_qty, dispatched_qty, received_qty, unit, '
          'line_notes, inventory_items(name, unit)',
        )
        .eq('requisition_id', requisitionId)
        .order('id');
    return List<Map<String, dynamic>>.from(rows)
        .map(RequisitionLine.fromMap)
        .toList(growable: false);
  }

  /// Crea la solicitud. [lines] son mapas `{item_id, requested_qty, unit,
  /// line_notes?}`. NO mueve stock: eso pasa en el despacho.
  Future<Requisition> createRequisition({
    required String businessId,
    required String fromWarehouseId,
    required String toWarehouseId,
    required List<Map<String, dynamic>> lines,
    String? notes,
  }) async {
    final response = await _client.rpc(
      InventoryQueries.rpcRequisitionCreate,
      params: {
        'p_business_id': businessId,
        'p_from_warehouse_id': fromWarehouseId,
        'p_to_warehouse_id': toWarehouseId,
        'p_lines': lines,
        'p_notes': notes,
      },
    );
    return Requisition.fromMap(Map<String, dynamic>.from(response as Map));
  }

  /// Despacha. [lines] son `{item_id, dispatched_qty}`; una línea ausente se
  /// despacha en CERO, que es "la miré y no había". Acá sí se mueve el stock,
  /// vía la transferencia que dispara el RPC.
  Future<Requisition> dispatchRequisition({
    required String requisitionId,
    required List<Map<String, dynamic>> lines,
    String? notes,
  }) async {
    final response = await _client.rpc(
      InventoryQueries.rpcRequisitionDispatch,
      params: {
        'p_requisition_id': requisitionId,
        'p_lines': lines,
        'p_notes': notes,
      },
    );
    return Requisition.fromMap(Map<String, dynamic>.from(response as Map));
  }

  /// Confirma la recepción. [lines] (`{item_id, received_qty}`) solo hace
  /// falta para declarar una diferencia: por defecto se recibe lo despachado.
  Future<Requisition> receiveRequisition({
    required String requisitionId,
    List<Map<String, dynamic>>? lines,
    String? notes,
  }) async {
    final response = await _client.rpc(
      InventoryQueries.rpcRequisitionReceive,
      params: {
        'p_requisition_id': requisitionId,
        'p_lines': lines,
        'p_notes': notes,
      },
    );
    return Requisition.fromMap(Map<String, dynamic>.from(response as Map));
  }

  Future<Requisition> cancelRequisition({
    required String requisitionId,
    String? reason,
  }) async {
    final response = await _client.rpc(
      InventoryQueries.rpcRequisitionCancel,
      params: {'p_requisition_id': requisitionId, 'p_reason': reason},
    );
    return Requisition.fromMap(Map<String, dynamic>.from(response as Map));
  }

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
          // Desambiguar: stock_transfer_items tiene 2 FK a inventory_items
          // (item_id origen y target_item_id destino). Aquí queremos el insumo
          // de origen, así que fijamos la relación por item_id_fkey.
          'inventory_items!stock_transfer_items_item_id_fkey(name, unit)',
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
