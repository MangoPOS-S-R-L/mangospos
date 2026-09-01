class InventoryWarehouse {
  final String id;
  final String name;
  final bool isMain;

  const InventoryWarehouse({
    required this.id,
    required this.name,
    required this.isMain,
  });

  factory InventoryWarehouse.fromMap(Map<String, dynamic> map) {
    return InventoryWarehouse(
      id: map['id']?.toString() ?? '',
      name: map['name']?.toString() ?? 'Almacen',
      isMain: map['is_main'] == true,
    );
  }
}

/// PRD 9 Fase 1C — Proveedor con todos los campos del schema (`rnc`,
/// `payment_terms`, `notes`, etc.) para el CRUD del módulo Inventario.
class InventorySupplierDetail {
  final String id;
  final String name;
  final String rnc;
  final String contactName;
  final String phone;
  final String email;
  final String address;
  final String paymentTerms;
  final String notes;
  final bool isActive;
  final DateTime? createdAt;

  // ── Fase 3 Proveedores — condiciones comerciales estructuradas ──────────
  //
  // `paymentTerms` (texto libre) sigue siendo lo que escribió el negocio y no
  // se toca. Estos campos son los que permiten CALCULAR: un vencimiento, un
  // atraso, un orden por deuda. Llegan con la migración
  // 20260819_0003_supplier_terms_and_items y son nulos mientras no se aplique
  // — la pantalla lo detecta y se queda con el texto.

  /// 'contado' | 'credito' | 'anticipo'. Vacío = sin definir.
  final String paymentTermsType;

  /// Días de plazo. Null = no configurado (distinto de 0 = contado).
  final int? paymentTermsDays;

  /// 'invoice' | 'receipt': desde cuándo cuentan los días.
  final String paymentTermsFrom;

  /// Monto mínimo que el proveedor exige por orden.
  final double? minOrderAmount;

  /// Días de entrega PROMETIDOS, para contrastar con el promedio real.
  final int? leadTimeDays;

  const InventorySupplierDetail({
    required this.id,
    required this.name,
    required this.rnc,
    required this.contactName,
    required this.phone,
    required this.email,
    required this.address,
    required this.paymentTerms,
    required this.notes,
    required this.isActive,
    required this.createdAt,
    this.paymentTermsType = '',
    this.paymentTermsDays,
    this.paymentTermsFrom = '',
    this.minOrderAmount,
    this.leadTimeDays,
  });

  factory InventorySupplierDetail.fromMap(Map<String, dynamic> map) {
    return InventorySupplierDetail(
      id: map['id']?.toString() ?? '',
      name: map['name']?.toString() ?? 'Proveedor',
      rnc: map['rnc']?.toString() ?? '',
      contactName: map['contact_name']?.toString() ?? '',
      phone: map['phone']?.toString() ?? '',
      email: map['email']?.toString() ?? '',
      address: map['address']?.toString() ?? '',
      paymentTerms: map['payment_terms']?.toString() ?? '',
      notes: map['notes']?.toString() ?? '',
      isActive: map['is_active'] != false,
      createdAt: DateTime.tryParse(map['created_at']?.toString() ?? ''),
      paymentTermsType: map['payment_terms_type']?.toString() ?? '',
      paymentTermsDays: _intOrNull(map['payment_terms_days']),
      paymentTermsFrom: map['payment_terms_from']?.toString() ?? '',
      minOrderAmount: _doubleOrNull(map['min_order_amount']),
      leadTimeDays: _intOrNull(map['lead_time_days']),
    );
  }

  static int? _intOrNull(dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toInt();
    return int.tryParse(value.toString());
  }

  static double? _doubleOrNull(dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString());
  }
}

/// PRD 9 Fase 1B — Versión completa de bodega para CRUD (incluye address,
/// is_active, created_at). La virtual `__IN_TRANSIT__` se identifica por
/// el `name` para que la UI la pueda mostrar como read-only.
/// Clase de almacén (F0 Almacenes por sección, migración 20260901_0001).
///
/// `general` es el valor por defecto y el comportamiento de siempre: en un
/// negocio de una sola bodega, todo es general y nada cambia.
enum WarehouseType {
  general,
  production,
  waste,
  loan;

  static WarehouseType fromWire(String? raw) {
    switch (raw) {
      case 'production':
        return WarehouseType.production;
      case 'waste':
        return WarehouseType.waste;
      case 'loan':
        return WarehouseType.loan;
      default:
        return WarehouseType.general;
    }
  }

  String get wire => name;

  String get label {
    switch (this) {
      case WarehouseType.general:
        return 'General';
      case WarehouseType.production:
        return 'Producción';
      case WarehouseType.waste:
        return 'Mermas';
      case WarehouseType.loan:
        return 'Préstamos';
    }
  }

  String get description {
    switch (this) {
      case WarehouseType.general:
        return 'Depósito común: guarda y despacha a los demás';
      case WarehouseType.production:
        return 'Abastece un área (Cocina, Bar) y de ahí sale lo que se vende';
      case WarehouseType.waste:
        return 'Destino de lo dañado, vencido o perdido';
      case WarehouseType.loan:
        return 'Mercancía prestada, pendiente de devolución';
    }
  }
}

/// Opción de un selector del formulario de almacén: el área de producción
/// a la que sirve, o el empleado que responde por él. Los dos son "id +
/// nombre" y no vale la pena una clase por cada uno.
class WarehouseAssignmentOption {
  final String id;
  final String name;

  const WarehouseAssignmentOption({required this.id, required this.name});
}

class InventoryWarehouseDetail {
  final String id;
  final String name;
  final String address;
  final bool isMain;
  final bool isActive;
  final DateTime? createdAt;

  // ── F0 Almacenes por sección (migración 20260901_0001) ─────────────────
  //
  // Las cuatro llegan con esa migración. Mientras no esté aplicada, el
  // SELECT las omite y acá caen en el default: tipo `general`, sin área,
  // sin responsable. La pantalla sigue funcionando igual que antes — la
  // app tiene que andar contra las dos versiones del esquema porque los
  // negocios se actualizan en tiempos distintos.

  final WarehouseType warehouseType;

  /// Área de producción (`print_areas`) que abastece. Null = ninguna.
  final String? productionAreaId;

  /// Nombre del área, resuelto en el mismo SELECT para no pedirlo aparte.
  final String productionAreaName;

  /// Empleado que responde por el almacén. Null = sin responsable.
  final String? keeperEmployeeId;

  /// Nombre del responsable, resuelto en el mismo SELECT.
  final String keeperName;

  /// Solo recibe por requisición aprobada (lo hace cumplir F2).
  final bool requiresRequisition;

  /// El punto de venta muestra Y descuenta la existencia de ESTA bodega
  /// para los productos que no resuelven por área. Una sola por negocio.
  /// Migración 20260901_0005.
  final bool showsInPos;

  const InventoryWarehouseDetail({
    required this.id,
    required this.name,
    required this.address,
    required this.isMain,
    required this.isActive,
    required this.createdAt,
    this.warehouseType = WarehouseType.general,
    this.productionAreaId,
    this.productionAreaName = '',
    this.keeperEmployeeId,
    this.keeperName = '',
    this.requiresRequisition = false,
    this.showsInPos = false,
  });

  bool get isInTransit => name == '__IN_TRANSIT__';

  bool get isProduction => warehouseType == WarehouseType.production;
  bool get isWaste => warehouseType == WarehouseType.waste;
  bool get isLoan => warehouseType == WarehouseType.loan;

  /// True si tiene algo que mostrar de la Fase 0 (para no pintar chips
  /// vacíos en un negocio que todavía no configuró nada).
  bool get hasSectionInfo =>
      warehouseType != WarehouseType.general ||
      productionAreaId != null ||
      keeperEmployeeId != null ||
      showsInPos;

  factory InventoryWarehouseDetail.fromMap(Map<String, dynamic> map) {
    // El nombre del área y del responsable pueden venir embebidos por el
    // join de PostgREST (`print_areas(name)`, `employees(first_name,...)`)
    // o no venir del todo si la migración no está aplicada.
    final area = map['print_areas'];
    final keeper = map['employees'];
    final keeperName = keeper is Map
        ? [
            keeper['first_name']?.toString().trim() ?? '',
            keeper['last_name']?.toString().trim() ?? '',
          ].where((p) => p.isNotEmpty).join(' ')
        : '';

    return InventoryWarehouseDetail(
      id: map['id']?.toString() ?? '',
      name: map['name']?.toString() ?? 'Almacen',
      address: map['address']?.toString() ?? '',
      isMain: map['is_main'] == true,
      isActive: map['is_active'] != false,
      createdAt: DateTime.tryParse(map['created_at']?.toString() ?? ''),
      warehouseType:
          WarehouseType.fromWire(map['warehouse_type']?.toString()),
      productionAreaId: (map['production_area_id']?.toString().isNotEmpty ??
              false)
          ? map['production_area_id'].toString()
          : null,
      productionAreaName:
          area is Map ? (area['name']?.toString() ?? '') : '',
      keeperEmployeeId: (map['keeper_employee_id']?.toString().isNotEmpty ??
              false)
          ? map['keeper_employee_id'].toString()
          : null,
      keeperName: keeperName,
      requiresRequisition: map['requires_requisition'] == true,
      showsInPos: map['shows_in_pos'] == true,
    );
  }
}

class InventoryItemSummary {
  final String id;
  final String sku;
  final String name;
  final String description;
  final String unit; // unidad BASE de stock (ej. ml)
  /// Conversión de empaque: unidad de COMPRA (ej. botella) y cuántas
  /// unidades base contiene (ej. 750). packSize=1 / purchaseUnit vacío =
  /// sin empaque (se compra en la unidad base).
  final String purchaseUnit;
  final double packSize;
  final double cost;
  final double minStock;
  final double? maxStock;
  final bool isActive;
  final double stock;
  // PRD 9 Fase 1D — campos extendidos.
  final String costingMethod; // 'average' | 'fifo'
  final String barcode;
  // Sprint 4 lotes — opt-in para tracking de lote / vencimiento.
  final bool tracksLots;
  // PRD inventario avanzado: clasificación.
  // Valores válidos: 'simple', 'raw_material', 'finished_product',
  // 'combo', 'service'. Default 'simple' = comportamiento legacy.
  final String itemClassification;

  const InventoryItemSummary({
    required this.id,
    required this.sku,
    required this.name,
    required this.description,
    required this.unit,
    this.purchaseUnit = '',
    this.packSize = 1,
    required this.cost,
    required this.minStock,
    required this.maxStock,
    required this.isActive,
    required this.stock,
    this.costingMethod = 'average',
    this.barcode = '',
    this.tracksLots = false,
    this.itemClassification = 'simple',
  });

  /// Bajo mínimo con la MISMA regla que la vista `v_inventory_low_stock`:
  /// activo, con mínimo configurado y stock en o por debajo de ese mínimo.
  ///
  /// Sin el guard de `minStock > 0`, todo insumo sin mínimo y en cero salía
  /// como alerta — ruido que tapaba las reposiciones reales.
  bool get isLowStock => isActive && minStock > 0 && stock <= minStock;

  /// Severidad, alineada con el `alert_level` de la vista SQL. `null` si el
  /// insumo no está bajo mínimo.
  ///   out_of_stock → sin existencia · critical → ≤ 50% del mínimo · low
  String? get lowStockLevel {
    if (!isLowStock) return null;
    if (stock <= 0) return 'out_of_stock';
    if (stock <= minStock * 0.5) return 'critical';
    return 'low';
  }

  /// Cuánto falta para alcanzar el mínimo. 0 si no falta nada.
  double get shortfall {
    if (minStock <= 0) return 0;
    final missing = minStock - stock;
    return missing > 0 ? missing : 0;
  }

  factory InventoryItemSummary.fromMap(
    Map<String, dynamic> map, {
    required double stock,
  }) {
    double toDouble(dynamic value) {
      if (value is num) return value.toDouble();
      return double.tryParse(value?.toString() ?? '') ?? 0;
    }

    return InventoryItemSummary(
      id: map['id']?.toString() ?? '',
      sku: map['sku']?.toString() ?? '',
      name: map['name']?.toString() ?? 'Insumo',
      description: map['description']?.toString() ?? '',
      unit: map['unit']?.toString() ?? 'unidad',
      purchaseUnit: map['purchase_unit']?.toString() ?? '',
      packSize: map['pack_size'] == null ? 1 : toDouble(map['pack_size']),
      cost: toDouble(map['cost']),
      minStock: toDouble(map['min_stock']),
      maxStock: map['max_stock'] == null ? null : toDouble(map['max_stock']),
      isActive: map['is_active'] != false,
      stock: stock,
      costingMethod: map['costing_method']?.toString() ?? 'average',
      barcode: map['barcode']?.toString() ?? '',
      tracksLots: map['tracks_lots'] == true,
      itemClassification:
          map['item_classification']?.toString() ?? 'simple',
    );
  }
}

class InventoryMovementEntry {
  final String id;
  final String itemId;
  final String itemName;
  final String warehouseId;
  final String warehouseName;
  final String movementType;
  final double quantity;
  final String notes;
  final String referenceType;
  final DateTime createdAt;

  const InventoryMovementEntry({
    required this.id,
    required this.itemId,
    required this.itemName,
    required this.warehouseId,
    required this.warehouseName,
    required this.movementType,
    required this.quantity,
    required this.notes,
    required this.referenceType,
    required this.createdAt,
  });

  bool get isOutflow => quantity < 0;

  factory InventoryMovementEntry.fromMap(
    Map<String, dynamic> map, {
    required String itemName,
    required String warehouseName,
  }) {
    double toDouble(dynamic value) {
      if (value is num) return value.toDouble();
      return double.tryParse(value?.toString() ?? '') ?? 0;
    }

    return InventoryMovementEntry(
      id: map['id']?.toString() ?? '',
      itemId: map['item_id']?.toString() ?? '',
      itemName: itemName,
      warehouseId: map['warehouse_id']?.toString() ?? '',
      warehouseName: warehouseName,
      movementType: map['movement_type']?.toString() ?? 'adjustment',
      quantity: toDouble(map['quantity']),
      notes: map['notes']?.toString() ?? '',
      referenceType: map['reference_type']?.toString() ?? '',
      createdAt:
          DateTime.tryParse(map['created_at']?.toString() ?? '') ??
          DateTime.now(),
    );
  }
}

class InventoryState {
  final bool loading;
  final bool saving;
  final String? error;
  final String? businessId;
  final String? selectedWarehouseId;
  final String searchQuery;
  final List<InventoryWarehouse> warehouses;
  final List<InventoryItemSummary> items;
  final List<InventoryMovementEntry> movements;

  const InventoryState({
    this.loading = false,
    this.saving = false,
    this.error,
    this.businessId,
    this.selectedWarehouseId,
    this.searchQuery = '',
    this.warehouses = const [],
    this.items = const [],
    this.movements = const [],
  });

  InventoryState copyWith({
    bool? loading,
    bool? saving,
    String? error,
    String? businessId,
    String? selectedWarehouseId,
    String? searchQuery,
    List<InventoryWarehouse>? warehouses,
    List<InventoryItemSummary>? items,
    List<InventoryMovementEntry>? movements,
    bool clearError = false,
  }) {
    return InventoryState(
      loading: loading ?? this.loading,
      saving: saving ?? this.saving,
      error: clearError ? null : (error ?? this.error),
      businessId: businessId ?? this.businessId,
      selectedWarehouseId: selectedWarehouseId ?? this.selectedWarehouseId,
      searchQuery: searchQuery ?? this.searchQuery,
      warehouses: warehouses ?? this.warehouses,
      items: items ?? this.items,
      movements: movements ?? this.movements,
    );
  }
}

/// Insumos del negocio con su stock DESGLOSADO por bodega.
///
/// La vista de Insumos v2 muestra una fila por insumo y una columna por
/// bodega: necesita el maestro completo (no solo lo presente en una bodega)
/// y la cantidad de cada par (insumo × bodega) en una sola lectura.
///
/// `items[i].stock` es el TOTAL del negocio (suma de las bodegas visibles),
/// no el de una bodega concreta — para eso está [quantityOf].
class InventoryStockMatrix {
  final List<InventoryItemSummary> items;

  /// itemId → { warehouseId → cantidad }. Solo trae los pares con fila en
  /// `inventory_stock`; la ausencia se distingue del cero con [hasStockRow].
  final Map<String, Map<String, double>> byWarehouse;

  /// True si la lectura se resolvió contra el cache local (offline).
  final bool fromCache;

  const InventoryStockMatrix({
    required this.items,
    required this.byWarehouse,
    this.fromCache = false,
  });

  static const empty = InventoryStockMatrix(items: [], byWarehouse: {});

  double quantityOf(String itemId, String warehouseId) =>
      byWarehouse[itemId]?[warehouseId] ?? 0;

  /// True si el insumo tiene fila en esa bodega (aunque sea 0). Permite
  /// distinguir "hay cero" de "nunca estuvo acá".
  bool hasStockRow(String itemId, String warehouseId) =>
      byWarehouse[itemId]?.containsKey(warehouseId) ?? false;

  /// Bodegas (de las visibles) donde el insumo tiene existencia > 0.
  List<String> warehousesWithStock(String itemId) {
    final row = byWarehouse[itemId];
    if (row == null) return const [];
    return row.entries
        .where((e) => e.value > 0)
        .map((e) => e.key)
        .toList(growable: false);
  }
}
