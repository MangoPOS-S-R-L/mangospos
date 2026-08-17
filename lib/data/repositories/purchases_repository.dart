import 'package:supabase_flutter/supabase_flutter.dart';

import '../../presentation/purchases/state/purchases_state.dart';
import '../datasources/queries/purchases_queries.dart';

class PurchasesRepository {
  final SupabaseClient _client;

  PurchasesRepository(this._client);

  double _toDouble(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? 0;
  }

  Future<List<PurchaseSupplier>> getSuppliers(String businessId) async {
    // `payment_terms_days` llega con la migración 20260814_0003. Si el
    // ambiente todavía no la aplicó, PostgREST responde 42703 y el módulo de
    // compras entero se quedaría en blanco: caemos a la selección legacy en
    // vez de tumbar la pantalla por un campo opcional.
    List<Map<String, dynamic>> rows;
    try {
      rows = List<Map<String, dynamic>>.from(
        await _client
            .from(PurchasesQueries.tableSuppliers)
            .select(
              'id, name, contact_name, phone, email, is_active, '
              'payment_terms, payment_terms_days',
            )
            .eq('business_id', businessId)
            .order('name'),
      );
    } on PostgrestException catch (e) {
      if (e.code != '42703') rethrow;
      rows = List<Map<String, dynamic>>.from(
        await _client
            .from(PurchasesQueries.tableSuppliers)
            .select('id, name, contact_name, phone, email, is_active, payment_terms')
            .eq('business_id', businessId)
            .order('name'),
      );
    }

    return rows.map(PurchaseSupplier.fromMap).toList(growable: false);
  }

  Future<List<PurchaseWarehouse>> getWarehouses(String businessId) async {
    final response = await _client
        .from(PurchasesQueries.tableWarehouses)
        .select('id, name, is_main')
        .eq('business_id', businessId)
        .eq('is_active', true)
        .order('is_main', ascending: false)
        .order('name');

    return List<Map<String, dynamic>>.from(
      response,
    ).map(PurchaseWarehouse.fromMap).toList(growable: false);
  }

  static const _inventoryItemColumns =
      'id, name, sku, barcode, unit, cost, is_active, purchase_unit, pack_size';

  Future<List<PurchaseInventoryItem>> getInventoryItems(String businessId) async {
    final response = await _client
        .from(PurchasesQueries.tableInventoryItems)
        .select(_inventoryItemColumns)
        .eq('business_id', businessId)
        .eq('is_active', true)
        .order('name');

    return List<Map<String, dynamic>>.from(
      response,
    ).map(PurchaseInventoryItem.fromMap).toList(growable: false);
  }

  /// Resuelve un código leído por la pistola contra el catálogo de INSUMOS:
  /// primero `barcode` exacto, luego `sku` — el mismo criterio del buscador
  /// manual, para que escanear y teclear resuelvan igual.
  ///
  /// La consulta es EN LÍNEA: el snapshot offline solo trae `menu_items`, no
  /// insumos de inventario. Sin conexión esto lanza y la vista lo informa, en
  /// lugar de fallar sin explicación.
  ///
  /// Devuelve la lista de coincidencias (ordenada por prioridad) para que la
  /// vista pueda avisar cuando un mismo código vive en dos insumos: se toma
  /// el primero, pero la ambigüedad se resuelve en el catálogo, no aquí.
  Future<List<PurchaseInventoryItem>> findInventoryItemsByCode({
    required String businessId,
    required String code,
  }) async {
    final clean = code.trim();
    if (clean.isEmpty) return const [];

    Future<List<PurchaseInventoryItem>> queryBy(String column) async {
      final rows = await _client
          .from(PurchasesQueries.tableInventoryItems)
          .select(_inventoryItemColumns)
          .eq('business_id', businessId)
          .eq('is_active', true)
          .eq(column, clean)
          .order('name');
      return List<Map<String, dynamic>>.from(rows)
          .map(PurchaseInventoryItem.fromMap)
          .toList(growable: false);
    }

    final byBarcode = await queryBy('barcode');
    if (byBarcode.isNotEmpty) return byBarcode;
    return queryBy('sku');
  }

  static const _orderColumns =
      'id, supplier_id, warehouse_id, order_number, invoice_number, ncf, '
      'status, total, expected_date, received_date, created_at, notes';

  static const _orderColumnsLegacy =
      'id, supplier_id, warehouse_id, order_number, invoice_number, '
      'status, total, expected_date, received_date, created_at, notes';

  Future<List<PurchaseOrderSummary>> getOrders({
    required String businessId,
    String? status,
    int limit = 50,
    int offset = 0,
  }) async {
    // Igual que en `getSuppliers`: `ncf` llega con 20260814_0003 y su ausencia
    // no puede dejar el listado en blanco.
    Future<List<Map<String, dynamic>>> fetch(String columns) async {
      final response = status != null && status.isNotEmpty
          ? await _client
                .from(PurchasesQueries.tablePurchaseOrders)
                .select(columns)
                .eq('business_id', businessId)
                .eq('status', status)
                .order('created_at', ascending: false)
                .range(offset, offset + limit - 1)
          : await _client
                .from(PurchasesQueries.tablePurchaseOrders)
                .select(columns)
                .eq('business_id', businessId)
                .order('created_at', ascending: false)
                .range(offset, offset + limit - 1);
      return List<Map<String, dynamic>>.from(response);
    }

    List<Map<String, dynamic>> orders;
    try {
      orders = await fetch(_orderColumns);
    } on PostgrestException catch (e) {
      if (e.code != '42703') rethrow;
      orders = await fetch(_orderColumnsLegacy);
    }
    if (orders.isEmpty) return const [];

    final supplierIds = orders
        .map((row) => row['supplier_id']?.toString())
        .whereType<String>()
        .toSet()
        .toList(growable: false);
    final warehouseIds = orders
        .map((row) => row['warehouse_id']?.toString())
        .whereType<String>()
        .toSet()
        .toList(growable: false);

    final suppliersById = <String, String>{};
    if (supplierIds.isNotEmpty) {
      final suppliers = await _client
          .from(PurchasesQueries.tableSuppliers)
          .select('id, name')
          .inFilter('id', supplierIds);
      for (final row in List<Map<String, dynamic>>.from(suppliers)) {
        suppliersById[row['id']?.toString() ?? ''] = row['name']?.toString() ?? '';
      }
    }

    final warehousesById = <String, String>{};
    if (warehouseIds.isNotEmpty) {
      final warehouses = await _client
          .from(PurchasesQueries.tableWarehouses)
          .select('id, name')
          .inFilter('id', warehouseIds);
      for (final row in List<Map<String, dynamic>>.from(warehouses)) {
        warehousesById[row['id']?.toString() ?? ''] =
            row['name']?.toString() ?? '';
      }
    }

    return orders
        .map(
          (row) => PurchaseOrderSummary.fromMap(
            row,
            supplierName:
                suppliersById[row['supplier_id']?.toString() ?? ''] ??
                'Proveedor no asignado',
            warehouseName:
                warehousesById[row['warehouse_id']?.toString() ?? ''] ??
                'Almacen',
          ),
        )
        .toList(growable: false);
  }

  Future<PurchaseSupplier> createSupplier({
    required String businessId,
    required String name,
    String? contactName,
    String? phone,
    String? email,
    String? rnc,
    String? address,
    String? paymentTerms,
    int? paymentTermsDays,
    String? notes,
  }) async {
    final payload = <String, dynamic>{
      'business_id': businessId,
      'name': name,
      'contact_name': contactName,
      'phone': phone,
      'email': email,
      'rnc': rnc,
      'address': address,
      'payment_terms': paymentTerms,
      'notes': notes,
      'is_active': true,
    }..removeWhere((key, value) => value == null || value == '');

    // En la BD viva `payment_terms_days` es integer NOT NULL con default 0
    // (la columna precedía a la migración 20260814_0003, que por eso no la
    // tocó). Se manda SIEMPRE —0 cuando no hay plazo— para no depender de que
    // ese default exista: 0 es "sin configurar", no "pago a 0 días", y así lo
    // lee `PaymentTerms.resolve`. Si el ambiente no tiene la columna, el 42703
    // de abajo reintenta sin ella.
    final days = (paymentTermsDays ?? 0) > 0 ? paymentTermsDays! : 0;

    Future<Map<String, dynamic>> insert(Map<String, dynamic> body) async {
      final row = await _client
          .from(PurchasesQueries.tableSuppliers)
          .insert(body)
          .select(
            'id, name, contact_name, phone, email, is_active, payment_terms',
          )
          .single();
      return Map<String, dynamic>.from(row);
    }

    Map<String, dynamic> row;
    try {
      row = await insert({...payload, 'payment_terms_days': days});
    } on PostgrestException catch (e) {
      if (e.code != '42703') rethrow;
      row = await insert(payload);
    }
    final map = Map<String, dynamic>.from(row);
    // El select legacy no trae la columna nueva; devolvemos lo que ya sabemos
    // para que la vista pueda usar el plazo del proveedor recién creado.
    map['payment_terms_days'] ??= paymentTermsDays;
    return PurchaseSupplier.fromMap(map);
  }

  /// Crea un almacén para el registro de compra sin salir del flujo. Si se
  /// marca principal, baja la marca del almacén principal previo (sólo uno
  /// por negocio), igual que la gestión de inventario.
  Future<PurchaseWarehouse> createWarehouse({
    required String businessId,
    required String name,
    bool isMain = false,
  }) async {
    if (isMain) {
      await _client
          .from(PurchasesQueries.tableWarehouses)
          .update({'is_main': false})
          .eq('business_id', businessId)
          .eq('is_main', true);
    }
    final row = await _client
        .from(PurchasesQueries.tableWarehouses)
        .insert({
          'business_id': businessId,
          'name': name,
          'is_main': isMain,
          'is_active': true,
        })
        .select('id, name, is_main')
        .single();
    return PurchaseWarehouse.fromMap(Map<String, dynamic>.from(row));
  }

  /// Crea la orden (y postea stock si va "Recibida"). Devuelve el id de la
  /// orden creada — lo usa la compra a crédito para vincular la CxP.
  Future<String> createPurchaseOrder({
    required String businessId,
    required String supplierId,
    required String warehouseId,
    required String orderNumber,
    required String status,
    required DateTime expectedDate,
    String? notes,
    String? invoiceNumber,
    /// Comprobante fiscal de la factura. Va en su PROPIA columna: el número
    /// de factura y el NCF son identificadores distintos con dueños distintos.
    String? ncf,
    required List<PurchaseDraftItem> items,
    // Cuando es true, el costo de cada línea vinculada actualiza el costo
    // maestro del insumo (inventory_items.cost). El costo ya viene en unidad
    // base (la vista convirtió desde la unidad de compra).
    bool updateItemCost = false,
    // Descuento GLOBAL de la orden en RD$ (pronto pago, acuerdo comercial).
    // Es financiero: no se prorratea a las líneas ni toca costos/kardex.
    // Los descuentos POR LÍNEA no viajan aquí: ya vienen dentro del unitCost
    // (descontado) + discountAmount informativo de cada PurchaseDraftItem.
    double discount = 0,
  }) async {
    if (items.isEmpty) {
      throw Exception('Debes agregar al menos una linea a la orden.');
    }

    final subtotal = items.fold<double>(0, (sum, item) => sum + item.total);
    // ITBIS absoluto por línea (o derivado del % en el modo heredado).
    final tax = items.fold<double>(0, (sum, item) => sum + item.taxValue);
    final orderDiscount = discount.clamp(0, subtotal + tax).toDouble();
    final total = subtotal + tax - orderDiscount;

    // Cuando el usuario registra la compra ya "Recibida", NO insertamos la
    // orden directamente en ese estado: la creamos como 'sent' (pendiente) y
    // dejamos que `fn_receive_purchase_order` sea quien postee el stock y la
    // marque como 'received'. Así, si la recepción falla (permisos, red), la
    // orden queda pendiente y consistente (sin stock, no marcada recibida) en
    // lugar de aparecer "Recibida" pero sin haber sumado nada al inventario.
    final bool receiveNow = status == 'received';
    final String insertStatus = receiveNow ? 'sent' : status;

    final Map<String, dynamic> createdOrder;
    try {
      createdOrder = await _client
          .from(PurchasesQueries.tablePurchaseOrders)
          .insert({
            'business_id': businessId,
            'supplier_id': supplierId,
            'warehouse_id': warehouseId,
            'order_number': orderNumber,
            'invoice_number': invoiceNumber,
            // Igual que `discount`: solo viaja cuando hay valor, para no
            // depender de la migración en negocios que no la aplicaron. Con
            // NCF digitado y columna ausente el guardado FALLA con motivo —
            // perder el comprobante en silencio sería peor.
            if (ncf != null && ncf.trim().isNotEmpty) 'ncf': ncf.trim(),
            'status': insertStatus,
            'subtotal': subtotal,
            'tax': tax,
            // Solo se manda la columna cuando hay descuento: así las compras
            // sin descuento siguen funcionando aunque la migración
            // 20260725_0001 (columna discount) no esté aplicada todavía.
            if (orderDiscount > 0) 'discount': orderDiscount,
            'total': total,
            'expected_date': expectedDate.toIso8601String().split('T').first,
            'notes': notes,
          }..removeWhere((key, value) => value == null || value == ''))
          .select('id')
          .single();
    } on PostgrestException catch (e) {
      if (e.code == '42703' && (e.message).contains('ncf')) {
        throw Exception(
          'La columna `ncf` no existe todavía en purchase_orders. Aplica la '
          'migración 20260814_0003_purchase_ncf_and_payment_terms.sql o deja '
          'el NCF vacío para guardar esta compra.',
        );
      }
      rethrow;
    }

    final orderId = createdOrder['id']?.toString();
    if (orderId == null || orderId.isEmpty) {
      throw Exception('No se pudo crear la orden de compra.');
    }

    await _client.from(PurchasesQueries.tablePurchaseOrderItems).insert(
      items
          .map(
            (item) => {
              'purchase_order_id': orderId,
              'inventory_item_id': item.inventoryItemId,
              'description': item.description,
              // quantity_ordered y unit_cost van en unidad BASE (la vista
              // ya convirtió desde la unidad de compra). El snapshot de
              // empaque permite mostrar/recibir en la unidad de compra.
              'quantity_ordered': item.quantity,
              // unit_cost va YA descontado (costo real): kardex y costo
              // maestro correctos sin tocar la RPC de recepción. El
              // descuento de la línea queda aparte como dato de auditoría.
              'unit_cost': item.unitCost,
              'tax_rate': item.taxRate,
              'total': item.total,
              if (item.discountAmount > 0) 'discount': item.discountAmount,
              'purchase_unit':
                  item.purchaseUnit.trim().isEmpty ? null : item.purchaseUnit.trim(),
              'pack_size': item.packSize,
            },
          )
          .toList(growable: false),
    );

    if (updateItemCost) {
      // Actualiza el costo maestro del insumo con el costo de compra recién
      // digitado (ya en unidad base). Si una línea con costo 0 comparte insumo
      // con otra de costo válido, gana la de costo > 0; si hay varias válidas,
      // gana la última de la lista.
      //
      // Política formal: costeo por ÚLTIMO PRECIO (mig 20260714_0001). El
      // trigger trg_inventory_movement_recost aplica la misma regla al
      // recibir cualquier movimiento de compra (incluye recepciones
      // directas); este update solo adelanta el valor al registrar la orden.
      final latestCostByItem = <String, double>{};
      for (final item in items) {
        final id = item.inventoryItemId;
        if (id == null || id.isEmpty) continue;
        if (item.unitCost <= 0) continue;
        latestCostByItem[id] = item.unitCost;
      }
      for (final entry in latestCostByItem.entries) {
        try {
          await _client
              .from(PurchasesQueries.tableInventoryItems)
              .update({'cost': entry.value})
              .eq('id', entry.key)
              .eq('business_id', businessId);
        } catch (_) {
          // Best-effort: un fallo al actualizar el costo maestro no debe
          // tumbar el registro de la compra (la orden ya quedó guardada).
        }
      }
    }

    // Postea el stock al inventario cuando la compra se registra "Recibida".
    // `fn_receive_purchase_order` crea los movimientos (tipo 'purchase') por
    // cada línea con insumo vinculado; el trigger de inventario sincroniza
    // `inventory_stock` y la RPC marca la orden como 'received'. Este era el
    // eslabón faltante: registrar la compra no sumaba nada al inventario.
    if (receiveNow) {
      await receivePurchaseOrder(orderId, notes: notes);
    }

    return orderId;
  }

  /// §6.4 — La compra se guardó a crédito pero la CxP no llegó a nacer.
  ///
  /// Mientras orden y CxP no sean una sola operación atómica, ese estado
  /// partido (mercancía dentro, deuda sin registrar) tiene que quedar VISIBLE
  /// en el listado y no solo en un aviso que se va a los dos segundos. La
  /// marca vive en `notes` para no añadir columnas fuera del modelo del PRD.
  ///
  /// Best-effort a propósito: si esto falla, el aviso al usuario sigue siendo
  /// el respaldo — no tiene sentido tumbar una compra ya guardada.
  Future<void> markPayablePending({
    required String orderId,
    required String currentNotes,
  }) async {
    if (currentNotes.contains(kPendingPayableTag)) return;
    final merged = currentNotes.trim().isEmpty
        ? kPendingPayableTag
        : '${currentNotes.trim()} $kPendingPayableTag';
    try {
      await _client
          .from(PurchasesQueries.tablePurchaseOrders)
          .update({'notes': merged})
          .eq('id', orderId);
    } catch (_) {
      // Sin red o sin permiso de update: el snackbar del registro ya avisó.
    }
  }

  Future<void> receivePurchaseOrder(String orderId, {String? notes}) async {
    await _client.rpc(
      PurchasesQueries.rpcReceivePurchaseOrder,
      params: {
        'p_order_id': orderId,
        'p_notes': notes,
      }..removeWhere((key, value) => value == null || value == ''),
    );
  }

  /// Lee las líneas de una OC, incluyendo `quantity_ordered`, `quantity_received`
  /// y datos del insumo para mostrar en el dialog de recepción parcial.
  Future<List<PurchaseOrderLine>> getOrderLines(String orderId) async {
    final response = await _client
        .from(PurchasesQueries.tablePurchaseOrderItems)
        .select(
          'id, inventory_item_id, description, quantity_ordered, quantity_received, '
          'unit_cost, tax_rate, total, purchase_unit, pack_size, '
          'inventory_items(name, unit, sku, tracks_lots, purchase_unit, pack_size)',
        )
        .eq('purchase_order_id', orderId)
        .order('id');
    return List<Map<String, dynamic>>.from(response)
        .map(PurchaseOrderLine.fromMap)
        .toList(growable: false);
  }

  /// Recepción parcial: el caller envía un array de líneas con cantidad a
  /// recibir. La RPC valida que la cantidad no exceda lo pendiente, crea
  /// los movimientos de inventario correspondientes y recalcula el status
  /// de la OC ('partial' o 'received').
  Future<Map<String, dynamic>> receivePurchaseOrderPartial({
    required String orderId,
    required List<Map<String, dynamic>> lineItems,
    String? notes,
  }) async {
    final response = await _client.rpc(
      PurchasesQueries.rpcReceivePurchaseOrderPartial,
      params: {
        'p_order_id': orderId,
        'p_line_items': lineItems,
        'p_notes': notes,
      }..removeWhere((key, value) => value == null || value == ''),
    );
    return response is Map
        ? Map<String, dynamic>.from(response)
        : <String, dynamic>{};
  }

  Future<String> generateNextOrderNumber(String businessId) async {
    final latest = await _client
        .from(PurchasesQueries.tablePurchaseOrders)
        .select('order_number')
        .eq('business_id', businessId)
        .order('created_at', ascending: false)
        .limit(1)
        .maybeSingle();

    final raw = latest?['order_number']?.toString() ?? '';
    final match = RegExp(r'(\d+)$').firstMatch(raw);
    final next = match == null ? 1 : (int.tryParse(match.group(1)!) ?? 0) + 1;
    return 'PO-${next.toString().padLeft(5, '0')}';
  }

  Future<Map<String, double>> getOrderTotalsByStatus(String businessId) async {
    final rows = List<Map<String, dynamic>>.from(
      await _client
          .from(PurchasesQueries.tablePurchaseOrders)
          .select('status, total')
          .eq('business_id', businessId),
    );

    final totals = <String, double>{};
    for (final row in rows) {
      final status = row['status']?.toString() ?? 'draft';
      totals[status] = (totals[status] ?? 0) + _toDouble(row['total']);
    }
    return totals;
  }
}
