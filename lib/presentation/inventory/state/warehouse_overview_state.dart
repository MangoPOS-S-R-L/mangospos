// Fase 2 Bodegas — la bodega como LUGAR, no como registro.
//
// El CRUD anterior sabía nombre, dirección y estado. Nada de eso dice si
// vale la pena entrar. Estos modelos cargan lo que convierte a la fila en
// una puerta: cuánto vale lo que hay adentro, cuántos insumos viven ahí,
// qué está bajo mínimo, qué viene en camino y hace cuánto que nadie cuenta.
//
// Todo el armado es PURO (ver [InventoryWarehousesOverview.build]): el
// repositorio trae filas y esto las cruza. Así la regla del mínimo —la
// parte que se puede equivocar— se prueba sin Supabase.

import 'inventory_state.dart';

/// Mínimo aplicable a los insumos DENTRO de una bodega.
///
/// `inventory_items.min_stock` es el mínimo del NEGOCIO. Compararlo contra
/// el stock de un solo almacén miente en las dos direcciones: si la Cocina
/// guarda 3 kg de queso y el negocio pide 10, la Cocina aparece siempre en
/// falta aunque la Principal esté llena.
///
/// De ahí el modelo híbrido:
///   - Con mínimo propio (`inventory_stock.min_stock`), ese manda.
///   - Sin mínimo propio y con UNA sola bodega activa, el global aplica:
///     el negocio y la bodega son el mismo sitio.
///   - Sin mínimo propio y con varias bodegas, NO hay alerta local. El
///     global se muestra sólo como referencia.
class WarehouseMinStock {
  /// itemId → mínimo propio de esta bodega. La ausencia de clave es
  /// "sin configurar"; un 0 explícito es "acá nunca falta" y tampoco alerta.
  final Map<String, double> overrides;

  /// El negocio opera con una sola bodega real activa.
  final bool singleWarehouse;

  /// El esquema soporta mínimos por bodega (migración aplicada). Cuando es
  /// `false` la UI no ofrece configurarlos y se queda con la referencia
  /// global.
  final bool supported;

  const WarehouseMinStock({
    this.overrides = const {},
    this.singleWarehouse = false,
    this.supported = false,
  });

  static const empty = WarehouseMinStock();

  bool hasOverride(String itemId) => overrides.containsKey(itemId);

  /// Mínimo que hay que respetar en esta bodega, o `null` si no hay ninguno
  /// aplicable (y entonces la bodega no puede estar "bajo mínimo").
  double? minFor(InventoryItemSummary item) {
    final own = overrides[item.id];
    if (own != null) return own;
    if (singleWarehouse && item.minStock > 0) return item.minStock;
    return null;
  }

  /// True si [quantity] de [item] está en o por debajo del mínimo local.
  ///
  /// Mismo guard que `InventoryItemSummary.isLowStock`: sin mínimo (> 0) no
  /// hay alerta, porque si no todo insumo en cero sería una urgencia.
  bool isLow(InventoryItemSummary item, double quantity) {
    if (!item.isActive) return false;
    final min = minFor(item);
    return min != null && min > 0 && quantity <= min;
  }

  /// Cuánto falta para alcanzar el mínimo local. 0 si no falta nada.
  double shortfall(InventoryItemSummary item, double quantity) {
    final min = minFor(item);
    if (min == null || min <= 0) return 0;
    final missing = min - quantity;
    return missing > 0 ? missing : 0;
  }
}

/// Una bodega con lo que hay adentro. Es lo que pinta cada tarjeta del mapa
/// y el encabezado del detalle.
class WarehouseOverview {
  final InventoryWarehouseDetail warehouse;

  /// Valor de las existencias: Σ cantidad × costo del insumo.
  final double stockValue;

  /// Insumos con existencia > 0 acá.
  final int itemsWithStock;

  /// Insumos por debajo del mínimo LOCAL (ver [WarehouseMinStock]).
  final int lowStockCount;

  /// Insumos con un mínimo APLICABLE en esta bodega. Sin ninguno, decir
  /// "todo sobre mínimo" sería mentir: no hay contra qué comparar.
  final int minimumsConfigured;

  /// Transferencias enviadas hacia acá y todavía sin recibir.
  final int incomingTransfers;

  /// Último movimiento de stock conocido (max `inventory_stock.last_updated`).
  final DateTime? lastActivityAt;

  /// Último conteo físico COMPLETADO en esta bodega.
  final DateTime? lastCountAt;

  const WarehouseOverview({
    required this.warehouse,
    this.stockValue = 0,
    this.itemsWithStock = 0,
    this.lowStockCount = 0,
    this.minimumsConfigured = 0,
    this.incomingTransfers = 0,
    this.lastActivityAt,
    this.lastCountAt,
  });

  String get id => warehouse.id;
  String get name => warehouse.isInTransit ? 'En tránsito' : warehouse.name;
  bool get isInTransit => warehouse.isInTransit;
  bool get isActive => warehouse.isActive;
  bool get isMain => warehouse.isMain;

  /// Días desde el último conteo físico. `null` si nunca se contó.
  int? daysSinceCount({DateTime? now}) {
    final last = lastCountAt;
    if (last == null) return null;
    return (now ?? DateTime.now()).difference(last).inDays;
  }
}

/// El mapa completo: las bodegas reales, la virtual de tránsito aparte y los
/// totales del negocio.
class InventoryWarehousesOverview {
  /// Bodegas reales, ordenadas: principal → activas por nombre → inactivas.
  /// La inactiva baja al final porque no compite con las que operan.
  final List<WarehouseOverview> warehouses;

  /// La virtual `__IN_TRANSIT__`. No es un lugar: es mercancía en camino, y
  /// por eso sale de la lista y va a su propia franja.
  final WarehouseOverview? inTransit;

  /// Transferencias enviadas y sin recibir en todo el negocio.
  final int transfersInTransit;

  /// Insumos activos del catálogo (denominador de "6 de 8").
  final int itemsInCatalog;

  /// El esquema soporta mínimos por bodega.
  final bool perWarehouseMinSupported;

  /// La lectura se resolvió contra la copia local.
  final bool fromCache;

  const InventoryWarehousesOverview({
    this.warehouses = const [],
    this.inTransit,
    this.transfersInTransit = 0,
    this.itemsInCatalog = 0,
    this.perWarehouseMinSupported = false,
    this.fromCache = false,
  });

  static const empty = InventoryWarehousesOverview();

  double get totalValue =>
      warehouses.fold<double>(0, (acc, w) => acc + w.stockValue);

  int get activeCount => warehouses.where((w) => w.isActive).length;

  /// Bodegas reales activas, en el formato liviano que piden los diálogos
  /// de ajuste y transferencia.
  List<InventoryWarehouse> get activeWarehouses => warehouses
      .where((w) => w.isActive)
      .map(
        (w) => InventoryWarehouse(
          id: w.warehouse.id,
          name: w.warehouse.name,
          isMain: w.warehouse.isMain,
        ),
      )
      .toList(growable: false);

  WarehouseOverview? byId(String id) {
    for (final w in warehouses) {
      if (w.id == id) return w;
    }
    if (inTransit?.id == id) return inTransit;
    return null;
  }

  /// Cruza el maestro de insumos con la matriz de stock y las señales
  /// operativas. Puro: mismas entradas, mismas salidas.
  ///
  /// [stockByWarehouse] es `warehouseId → (itemId → cantidad)`.
  /// [minByWarehouse] son los mínimos PROPIOS de cada bodega; llega vacío
  /// mientras la migración de `inventory_stock.min_stock` no esté aplicada.
  static InventoryWarehousesOverview build({
    required List<InventoryWarehouseDetail> warehouses,
    required List<InventoryItemSummary> items,
    required Map<String, Map<String, double>> stockByWarehouse,
    Map<String, Map<String, double>> minByWarehouse = const {},
    Map<String, DateTime> lastActivityByWarehouse = const {},
    Map<String, DateTime> lastCountByWarehouse = const {},
    Map<String, int> incomingTransfers = const {},
    int transfersInTransit = 0,
    bool perWarehouseMinSupported = false,
    bool fromCache = false,
  }) {
    final itemsById = <String, InventoryItemSummary>{
      for (final item in items) item.id: item,
    };
    final real = warehouses.where((w) => !w.isInTransit).toList();
    final singleWarehouse = real.where((w) => w.isActive).length == 1;

    WarehouseOverview overviewOf(InventoryWarehouseDetail w) {
      final stock = stockByWarehouse[w.id] ?? const <String, double>{};
      final rule = WarehouseMinStock(
        overrides: minByWarehouse[w.id] ?? const <String, double>{},
        singleWarehouse: singleWarehouse,
        supported: perWarehouseMinSupported,
      );

      var value = 0.0;
      var withStock = 0;
      var low = 0;
      var mins = 0;
      stock.forEach((itemId, qty) {
        final item = itemsById[itemId];
        if (item == null) return;
        if (qty > 0) {
          withStock++;
          value += qty * item.cost;
        }
        final min = rule.minFor(item);
        if (item.isActive && min != null && min > 0) mins++;
        if (rule.isLow(item, qty)) low++;
      });
      // Un insumo con mínimo propio y SIN fila de stock también falta: es el
      // caso de "lo configuré para que se reponga acá y todavía no llegó".
      rule.overrides.forEach((itemId, min) {
        if (stock.containsKey(itemId)) return;
        final item = itemsById[itemId];
        if (item == null || !item.isActive || min <= 0) return;
        low++;
        mins++;
      });

      return WarehouseOverview(
        warehouse: w,
        stockValue: value,
        itemsWithStock: withStock,
        lowStockCount: low,
        minimumsConfigured: mins,
        incomingTransfers: incomingTransfers[w.id] ?? 0,
        lastActivityAt: lastActivityByWarehouse[w.id],
        lastCountAt: lastCountByWarehouse[w.id],
      );
    }

    final cards = real.map(overviewOf).toList()
      ..sort((a, b) {
        // Inactivas al fondo, principal arriba, resto alfabético.
        if (a.isActive != b.isActive) return a.isActive ? -1 : 1;
        if (a.isMain != b.isMain) return a.isMain ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });

    InventoryWarehouseDetail? transit;
    for (final w in warehouses) {
      if (w.isInTransit) transit = w;
    }

    return InventoryWarehousesOverview(
      warehouses: cards,
      inTransit: transit == null ? null : overviewOf(transit),
      transfersInTransit: transfersInTransit,
      itemsInCatalog: items.where((i) => i.isActive).length,
      perWarehouseMinSupported: perWarehouseMinSupported,
      fromCache: fromCache,
    );
  }
}
