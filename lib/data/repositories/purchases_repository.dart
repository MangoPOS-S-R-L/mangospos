import 'package:supabase_flutter/supabase_flutter.dart';

import '../../presentation/purchases/state/goods_receipt.dart';
import '../../presentation/purchases/state/purchases_state.dart';
import '../datasources/queries/purchases_queries.dart';
import 'pos_settings_repository.dart';

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
      'status, total, expected_date, received_date, created_at, created_by, '
      'notes';

  static const _orderColumnsLegacy =
      'id, supplier_id, warehouse_id, order_number, invoice_number, '
      'status, total, expected_date, received_date, created_at, created_by, '
      'notes';

  Future<List<PurchaseOrderSummary>> getOrders({
    required String businessId,
    String? status,
    /// Varios estados a la vez. Lo usa la pantalla de recepción, que necesita
    /// "todo lo que todavía se puede recibir" y eso no es un solo estado.
    /// Tiene prioridad sobre [status] cuando viene con valores.
    List<String>? statuses,
    int limit = 50,
    int offset = 0,
  }) async {
    // Igual que en `getSuppliers`: `ncf` llega con 20260814_0003 y su ausencia
    // no puede dejar el listado en blanco.
    Future<List<Map<String, dynamic>>> fetch(String columns) async {
      final response = statuses != null && statuses.isNotEmpty
          ? await _client
                .from(PurchasesQueries.tablePurchaseOrders)
                .select(columns)
                .eq('business_id', businessId)
                .inFilter('status', statuses)
                .order('created_at', ascending: false)
                .range(offset, offset + limit - 1)
          : status != null && status.isNotEmpty
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
    // Segundo candado, del lado de los datos: si el negocio exige recepción
    // en almacén, registrar una compra NUNCA mueve stock —venga de donde
    // venga la llamada—. La UI ya no ofrece "Recibida", pero la garantía que
    // el contable necesita no puede depender de que un selector siga oculto.
    final bool requireReceipt = await requiresGoodsReceipt(businessId);
    final bool receiveNow = status == 'received' && !requireReceipt;
    final String insertStatus =
        (status == 'received') ? 'sent' : status;

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

    // Postea el stock al inventario cuando la compra se registra "Recibida".
    // `fn_receive_purchase_order` crea los movimientos (tipo 'purchase') por
    // cada línea con insumo vinculado; el trigger de inventario sincroniza
    // `inventory_stock` y la RPC marca la orden como 'received'. Este era el
    // eslabón faltante: registrar la compra no sumaba nada al inventario.
    //
    // El COSTO MAESTRO del insumo no se toca desde acá a propósito
    // (decisión 2026-08-28): el costo solo cambia con mercancía que entró de
    // verdad. Lo hace el trigger `trg_inventory_movement_recost` al postear
    // el movimiento —último precio, mig 20260714_0001, aplicada en prod—, y
    // así una orden que quede en Borrador o se cancele no deja el costo
    // movido. Antes esta función pisaba `inventory_items.cost` al guardar.
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
  static const _orderLineColumns =
      'id, inventory_item_id, description, quantity_ordered, quantity_received, '
      'unit_cost, tax_rate, total, discount, purchase_unit, pack_size, '
      'inventory_items(name, unit, sku, tracks_lots, purchase_unit, pack_size)';

  /// Sin la migración 20260725_0001 la columna `discount` de las líneas no
  /// existe; perder el descuento informativo es aceptable, quedarse sin
  /// líneas no lo es.
  static const _orderLineColumnsLegacy =
      'id, inventory_item_id, description, quantity_ordered, quantity_received, '
      'unit_cost, tax_rate, total, purchase_unit, pack_size, '
      'inventory_items(name, unit, sku, tracks_lots, purchase_unit, pack_size)';

  Future<List<PurchaseOrderLine>> getOrderLines(String orderId) async {
    Future<List<Map<String, dynamic>>> fetch(String columns) async {
      final response = await _client
          .from(PurchasesQueries.tablePurchaseOrderItems)
          .select(columns)
          .eq('purchase_order_id', orderId)
          .order('id');
      return List<Map<String, dynamic>>.from(response);
    }

    List<Map<String, dynamic>> rows;
    try {
      rows = await fetch(_orderLineColumns);
    } on PostgrestException catch (e) {
      if (e.code != '42703') rethrow;
      rows = await fetch(_orderLineColumnsLegacy);
    }
    return rows.map(PurchaseOrderLine.fromMap).toList(growable: false);
  }

  /// Factura de compra completa: cabecera con su desglose (subtotal, ITBIS,
  /// descuento global) + las líneas de lo comprado.
  ///
  /// Lee la orden por id en lugar de tomarla del listado para que el detalle
  /// abra igual desde un enlace directo o tras recargar la app.
  Future<PurchaseOrderDetail> getOrderDetail(String orderId) async {
    // Mismo criterio que `getOrders`: `ncf` (20260814_0003) y `discount`
    // (20260725_0001) pueden no estar aplicadas en el negocio. Se prueba de
    // más completo a más viejo y se cae al siguiente solo ante 42703.
    const columnSets = <String>[
      '$_orderColumns, subtotal, tax, discount',
      '$_orderColumns, subtotal, tax',
      '$_orderColumnsLegacy, subtotal, tax',
    ];

    Map<String, dynamic>? row;
    PostgrestException? lastMissingColumn;
    for (final columns in columnSets) {
      try {
        final response = await _client
            .from(PurchasesQueries.tablePurchaseOrders)
            .select(columns)
            .eq('id', orderId)
            .maybeSingle();
        row = response == null ? null : Map<String, dynamic>.from(response);
        lastMissingColumn = null;
        break;
      } on PostgrestException catch (e) {
        if (e.code != '42703') rethrow;
        lastMissingColumn = e;
      }
    }
    if (lastMissingColumn != null) throw lastMissingColumn;
    if (row == null) {
      throw Exception('La orden de compra ya no existe.');
    }

    double toDouble(dynamic value) {
      if (value is num) return value.toDouble();
      return double.tryParse(value?.toString() ?? '') ?? 0;
    }

    Future<String?> nameOf(String table, String? id) async {
      if (id == null || id.isEmpty) return null;
      final found = await _client
          .from(table)
          .select('name')
          .eq('id', id)
          .maybeSingle();
      return found?['name']?.toString();
    }

    final supplierName = await nameOf(
      PurchasesQueries.tableSuppliers,
      row['supplier_id']?.toString(),
    );
    final warehouseName = await nameOf(
      PurchasesQueries.tableWarehouses,
      row['warehouse_id']?.toString(),
    );
    final lines = await getOrderLines(orderId);

    return PurchaseOrderDetail(
      order: PurchaseOrderSummary.fromMap(
        row,
        supplierName: supplierName ?? 'Proveedor no asignado',
        warehouseName: warehouseName ?? 'Almacen',
      ),
      subtotal: toDouble(row['subtotal']),
      tax: toDouble(row['tax']),
      discount: toDouble(row['discount']),
      lines: lines,
      createdByName: await _employeeName(row['created_by']?.toString()),
    );
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

  /// El negocio exige recepción en almacén: registrar una compra NO mueve
  /// stock, la mercancía entra solo por la pantalla de recepción (que emite
  /// el conduce). Columna de la migración 20260828_0001.
  ///
  /// Se lee por [PosSettingsRepository] y no con un select propio porque ese
  /// camino ya tiene caché, timeout y fallback offline: una consulta cruda a
  /// `business_settings` en pleno registro de compra puede colgarse sin red.
  /// Sin la migración aplicada la columna no viene y responde `false`
  /// (comportamiento histórico) en vez de tumbar el registro.
  Future<bool> requiresGoodsReceipt(String businessId) async {
    try {
      final features =
          await PosSettingsRepository(_client).getBusinessFeatures(businessId);
      return features.requireGoodsReceipt;
    } catch (_) {
      return false;
    }
  }

  /// Recepción de mercancía que EMITE conduce (RPC v2).
  ///
  /// A diferencia de [receivePurchaseOrderPartial], esta deja el documento:
  /// cabecera numerada en `purchase_receptions` + una línea por producto con
  /// el snapshot de lo recibido. Eso es lo que el contable archiva.
  ///
  /// [idempotencyKey] la genera la pantalla ANTES de enviar y la reusa en
  /// cada reintento: si la respuesta se pierde por red, reenviar devuelve la
  /// misma recepción (`replayed: true`) en vez de duplicar el stock.
  ///
  /// Lanza [GoodsReceiptUnavailable] cuando la migración 20260828_0001 no
  /// está aplicada, para que la UI decida si cae a la recepción sin documento.
  Future<Map<String, dynamic>> receivePurchaseOrderWithReceipt({
    required String warehouseId,
    required List<Map<String, dynamic>> lines,
    required String idempotencyKey,
    String? orderId,
    String? supplierId,
    String? notes,
    String closeMode = 'complete',
  }) async {
    try {
      final response = await _client.rpc(
        PurchasesQueries.rpcReceivePurchaseOrderV2,
        params: {
          'p_warehouse_id': warehouseId,
          'p_lines': lines,
          'p_idempotency_key': idempotencyKey,
          'p_order_id': orderId,
          'p_supplier_id': supplierId,
          'p_close_mode': closeMode,
          'p_notes': notes,
        }..removeWhere((key, value) => value == null || value == ''),
      );
      return response is Map
          ? Map<String, dynamic>.from(response)
          : <String, dynamic>{};
    } on PostgrestException catch (e) {
      // 42883 = la función no existe; PGRST202 = PostgREST no la ve en el
      // schema cache. Las dos significan lo mismo: migración sin aplicar.
      if (e.code == '42883' || e.code == 'PGRST202') {
        throw const GoodsReceiptUnavailable();
      }
      // 42703 = a la tabla de recepciones le faltan las columnas nuevas
      // (0811_0002 aplicada, 0828_0001 no).
      if (e.code == '42703') throw const GoodsReceiptUnavailable();
      rethrow;
    }
  }

  static const _receptionColumns =
      'id, reception_number, reception_date, status, notes, created_at, '
      'purchase_order_id, received_by, '
      'suppliers(name, rnc), warehouses(name), '
      'purchase_orders(order_number, invoice_number, ncf, created_by)';

  /// Quién REALIZÓ la compra que dio origen a esta recepción. Sale de la
  /// orden (`created_by`), no de la recepción: el conduce lo lleva en la
  /// firma «Realizado por» y quien recibe firma al lado.
  Future<String> _orderIssuerName(Map<String, dynamic> header) {
    final order = header['purchase_orders'];
    if (order is! Map) return Future.value('');
    return _employeeName(order['created_by']?.toString());
  }

  /// Conduce completo (cabecera + líneas) listo para imprimir o reimprimir.
  Future<GoodsReceipt> getGoodsReceipt(String receptionId) async {
    final header = await _client
        .from(PurchasesQueries.tablePurchaseReceptions)
        .select(_receptionColumns)
        .eq('id', receptionId)
        .maybeSingle();
    if (header == null) {
      throw Exception('La recepción ya no existe.');
    }
    final lines = await _getReceptionLines(receptionId);
    return _receiptFromMaps(
      Map<String, dynamic>.from(header),
      lines,
      await _employeeName(header['received_by']?.toString()),
      await _orderIssuerName(header),
    );
  }

  /// Todas las recepciones de una orden, de la más reciente a la más vieja.
  /// Una OC recibida en tres viajes tiene tres conduces, y cada uno se
  /// reimprime por separado.
  Future<List<GoodsReceipt>> getGoodsReceiptsForOrder(String orderId) async {
    List<Map<String, dynamic>> rows;
    try {
      rows = List<Map<String, dynamic>>.from(
        await _client
            .from(PurchasesQueries.tablePurchaseReceptions)
            .select(_receptionColumns)
            .eq('purchase_order_id', orderId)
            .order('created_at', ascending: false),
      );
    } on PostgrestException catch (e) {
      // Sin la migración no hay recepciones que mostrar: la orden se recibió
      // por la ruta vieja, que no deja documento.
      if (e.code == '42P01' || e.code == '42703' || e.code == 'PGRST205') {
        return const [];
      }
      rethrow;
    }

    final receipts = <GoodsReceipt>[];
    for (final row in rows) {
      final lines = await _getReceptionLines(row['id']?.toString() ?? '');
      receipts.add(
        _receiptFromMaps(
          row,
          lines,
          await _employeeName(row['received_by']?.toString()),
          await _orderIssuerName(row),
        ),
      );
    }
    return receipts;
  }

  Future<List<Map<String, dynamic>>> _getReceptionLines(String receptionId) async {
    if (receptionId.isEmpty) return const [];
    const withSnapshot =
        'id, quantity_received, actual_unit_cost, discrepancy, '
        'item_name, item_sku, item_unit, description, '
        'inventory_items(name, sku, unit)';
    // Recepciones anteriores a 20260828_0001 no tienen snapshot: se leen sin
    // esas columnas y el modelo cae al maestro del insumo.
    const legacy =
        'id, quantity_received, actual_unit_cost, discrepancy, '
        'inventory_items(name, sku, unit)';

    Future<List<Map<String, dynamic>>> fetch(String columns) async {
      final response = await _client
          .from(PurchasesQueries.tablePurchaseReceptionLines)
          .select(columns)
          .eq('reception_id', receptionId)
          .order('id');
      return List<Map<String, dynamic>>.from(response);
    }

    try {
      return await fetch(withSnapshot);
    } on PostgrestException catch (e) {
      if (e.code != '42703') rethrow;
      return await fetch(legacy);
    }
  }

  /// Nombres ya resueltos en esta instancia. Una orden con tres recepciones
  /// del mismo almacenista no tiene por qué preguntar tres veces.
  final Map<String, String> _employeeNames = {};

  /// Nombre del empleado detrás de un `user_id` (quien recibió, quien
  /// registró la compra). Best-effort: el papel vale igual sin él, y no hay
  /// razón para tumbar una impresión porque el usuario no tenga ficha de
  /// empleado.
  Future<String> _employeeName(String? userId) async {
    if (userId == null || userId.isEmpty) return '';
    final cached = _employeeNames[userId];
    if (cached != null) return cached;
    try {
      final row = await _client
          .from(PurchasesQueries.tableEmployees)
          .select('first_name, last_name')
          .eq('user_id', userId)
          .limit(1)
          .maybeSingle();
      final full = row == null
          ? ''
          : '${row['first_name'] ?? ''} ${row['last_name'] ?? ''}'.trim();
      _employeeNames[userId] = full;
      return full;
    } catch (_) {
      return '';
    }
  }

  GoodsReceipt _receiptFromMaps(
    Map<String, dynamic> header,
    List<Map<String, dynamic>> lines,
    String receiverName,
    String issuerName,
  ) {
    final supplier = header['suppliers'];
    final warehouse = header['warehouses'];
    final order = header['purchase_orders'];

    String rel(dynamic value, String key) =>
        value is Map ? (value[key]?.toString() ?? '') : '';

    final rawDate =
        header['reception_date']?.toString() ?? header['created_at']?.toString();
    final createdAt =
        DateTime.tryParse(header['created_at']?.toString() ?? '')?.toLocal();

    return GoodsReceipt(
      id: header['id']?.toString() ?? '',
      number: header['reception_number']?.toString() ?? '',
      date: DateTime.tryParse(rawDate ?? '')?.toLocal() ?? DateTime.now(),
      createdAt: createdAt ??
          DateTime.tryParse(rawDate ?? '')?.toLocal() ??
          DateTime.now(),
      status: header['status']?.toString() ?? 'complete',
      orderId: header['purchase_order_id']?.toString(),
      orderNumber: rel(order, 'order_number'),
      invoiceNumber: rel(order, 'invoice_number'),
      ncf: rel(order, 'ncf'),
      supplierName: rel(supplier, 'name').isEmpty
          ? 'Proveedor no asignado'
          : rel(supplier, 'name'),
      supplierRnc: rel(supplier, 'rnc'),
      warehouseName: rel(warehouse, 'name').isEmpty
          ? 'Almacén'
          : rel(warehouse, 'name'),
      receivedByName: receiverName,
      issuedByName: issuerName,
      notes: header['notes']?.toString() ?? '',
      lines: lines.map(GoodsReceiptLine.fromMap).toList(growable: false),
    );
  }

  /// Estados en los que una orden todavía admite mercancía. `received` y
  /// `cancelled` quedan fuera: la primera ya cerró, la segunda no debería
  /// recibir nada.
  static const receivableStatuses = <String>['draft', 'sent', 'partial'];

  /// Órdenes pendientes de recibir, para el selector de la pantalla de
  /// recepción. Trae más que una página normal porque es una lista para
  /// escoger, no para navegar.
  Future<List<PurchaseOrderSummary>> getReceivableOrders(
    String businessId, {
    int limit = 200,
  }) {
    return getOrders(
      businessId: businessId,
      statuses: receivableStatuses,
      limit: limit,
    );
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

/// La recepción con conduce no está disponible en este servidor: falta la
/// migración 20260828_0001 (o la 20260812_0001 sobre la que se apoya).
///
/// Es un tipo propio y no un Exception genérico porque la UI TIENE que
/// distinguirlo: ante esto cae a la recepción sin documento —que sigue
/// moviendo el stock correctamente— en vez de dejar al almacén sin recibir.
class GoodsReceiptUnavailable implements Exception {
  const GoodsReceiptUnavailable();

  @override
  String toString() =>
      'GoodsReceiptUnavailable: falta la migración 20260828_0001 '
      '(fn_receive_purchase_order_v2).';
}
