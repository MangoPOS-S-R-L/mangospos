// Fase 2 Bodegas — la regla del mínimo y el armado del mapa.
//
// El bug que estas pruebas evitan es de negocio, no de pantalla: comparar el
// `min_stock` GLOBAL del insumo contra el stock de UNA bodega. Con Cocina
// guardando 3 kg de queso y el negocio pidiendo 10, la Cocina aparecería
// siempre en falta aunque la Principal esté llena — y al revés, un almacén
// vacío pasaría por sano porque el total del negocio alcanza.
//
// El armado es puro, así que se prueba sin Supabase ni widgets.

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/presentation/inventory/state/inventory_state.dart';
import 'package:mangopos/presentation/inventory/state/warehouse_overview_state.dart';

InventoryItemSummary _item(
  String id, {
  String name = 'Insumo',
  double cost = 10,
  double minStock = 0,
  bool isActive = true,
  double stock = 0,
}) => InventoryItemSummary(
  id: id,
  sku: id.toUpperCase(),
  name: name,
  description: '',
  unit: 'kg',
  cost: cost,
  minStock: minStock,
  maxStock: null,
  isActive: isActive,
  stock: stock,
);

InventoryWarehouseDetail _warehouse(
  String id, {
  String? name,
  bool isMain = false,
  bool isActive = true,
}) => InventoryWarehouseDetail(
  id: id,
  name: name ?? id,
  address: '',
  isMain: isMain,
  isActive: isActive,
  createdAt: null,
);

void main() {
  group('WarehouseMinStock', () {
    final queso = _item('queso', minStock: 10);

    test('el mínimo propio de la bodega manda sobre el global', () {
      const rule = WarehouseMinStock(overrides: {'queso': 3});
      expect(rule.minFor(queso), 3);
      expect(rule.isLow(queso, 4), isFalse, reason: '4 kg supera el mínimo 3');
      expect(rule.isLow(queso, 3), isTrue, reason: 'en el mínimo ya alerta');
      expect(rule.shortfall(queso, 1), 2);
    });

    test(
      'con varias bodegas y sin mínimo propio NO hay alerta local',
      () {
        // Es el caso que motiva todo: 4 kg en Cocina contra el mínimo del
        // negocio (10) parecería faltante, y no lo es.
        const rule = WarehouseMinStock();
        expect(rule.minFor(queso), isNull);
        expect(rule.isLow(queso, 4), isFalse);
        expect(rule.shortfall(queso, 0), 0);
      },
    );

    test('con UNA sola bodega el mínimo global sí aplica', () {
      const rule = WarehouseMinStock(singleWarehouse: true);
      expect(rule.minFor(queso), 10);
      expect(rule.isLow(queso, 4), isTrue);
      expect(rule.shortfall(queso, 4), 6);
    });

    test('un mínimo propio de 0 es "acá nunca falta", no una alerta', () {
      const rule = WarehouseMinStock(overrides: {'queso': 0});
      expect(rule.minFor(queso), 0);
      expect(rule.isLow(queso, 0), isFalse);
    });

    test('el insumo dado de baja no alerta aunque esté en cero', () {
      final baja = _item('viejo', minStock: 5, isActive: false);
      const rule = WarehouseMinStock(singleWarehouse: true);
      expect(rule.isLow(baja, 0), isFalse);
    });
  });

  group('InventoryWarehousesOverview.build', () {
    final items = [
      _item('harina', name: 'Harina', cost: 30, minStock: 20),
      _item('queso', name: 'Queso', cost: 100, minStock: 10),
    ];

    final warehouses = [
      _warehouse('principal', name: 'Principal', isMain: true),
      _warehouse('cocina', name: 'Cocina'),
      _warehouse('naco', name: 'Depósito Naco', isActive: false),
      _warehouse('transito', name: '__IN_TRANSIT__'),
    ];

    final stock = {
      'principal': {'harina': 40.0, 'queso': 8.0},
      'cocina': {'harina': 5.0, 'queso': 2.0},
      'transito': {'queso': 1.0},
    };

    test('valora las existencias y cuenta los insumos presentes', () {
      final overview = InventoryWarehousesOverview.build(
        warehouses: warehouses,
        items: items,
        stockByWarehouse: stock,
      );

      final principal = overview.byId('principal')!;
      expect(principal.stockValue, 40 * 30 + 8 * 100);
      expect(principal.itemsWithStock, 2);

      final cocina = overview.byId('cocina')!;
      expect(cocina.stockValue, 5 * 30 + 2 * 100);

      // El total del negocio NO incluye lo que está en tránsito: esa
      // mercancía ya salió de una bodega y todavía no llegó a la otra.
      expect(overview.totalValue, principal.stockValue + cocina.stockValue);
    });

    test('sin mínimos propios y con varias bodegas nadie está bajo mínimo', () {
      final overview = InventoryWarehousesOverview.build(
        warehouses: warehouses,
        items: items,
        stockByWarehouse: stock,
      );
      expect(overview.byId('cocina')!.lowStockCount, 0);
      expect(overview.byId('cocina')!.minimumsConfigured, 0);
    });

    test('con mínimos propios cuenta sólo lo que falta EN esa bodega', () {
      final overview = InventoryWarehousesOverview.build(
        warehouses: warehouses,
        items: items,
        stockByWarehouse: stock,
        minByWarehouse: {
          'cocina': {'harina': 8, 'queso': 1},
          'principal': {'harina': 20},
        },
        perWarehouseMinSupported: true,
      );

      // Cocina: harina 5 contra mínimo 8 → falta. Queso 2 contra 1 → sobra.
      final cocina = overview.byId('cocina')!;
      expect(cocina.lowStockCount, 1);
      expect(cocina.minimumsConfigured, 2);

      // Principal: 40 de harina contra 20 → nada que reponer.
      expect(overview.byId('principal')!.lowStockCount, 0);
    });

    test('un mínimo propio sin fila de stock también cuenta como faltante', () {
      final overview = InventoryWarehousesOverview.build(
        warehouses: warehouses,
        items: items,
        stockByWarehouse: {
          'cocina': {'harina': 30.0},
        },
        minByWarehouse: {
          // El queso se configuró para reponerse en Cocina y nunca llegó.
          'cocina': {'harina': 10, 'queso': 4},
        },
        perWarehouseMinSupported: true,
      );
      expect(overview.byId('cocina')!.lowStockCount, 1);
    });

    test('la virtual de tránsito sale de la lista y va aparte', () {
      final overview = InventoryWarehousesOverview.build(
        warehouses: warehouses,
        items: items,
        stockByWarehouse: stock,
        transfersInTransit: 2,
      );
      expect(overview.warehouses.map((w) => w.id), isNot(contains('transito')));
      expect(overview.inTransit, isNotNull);
      expect(overview.inTransit!.stockValue, 100);
      expect(overview.transfersInTransit, 2);
    });

    test('orden: principal primero, la inactiva al final', () {
      final overview = InventoryWarehousesOverview.build(
        warehouses: warehouses,
        items: items,
        stockByWarehouse: stock,
      );
      expect(
        overview.warehouses.map((w) => w.id).toList(),
        ['principal', 'cocina', 'naco'],
      );
      expect(overview.activeCount, 2);
    });

    test('con una sola bodega activa el mínimo global vuelve a valer', () {
      final overview = InventoryWarehousesOverview.build(
        warehouses: [_warehouse('unica', name: 'Única', isMain: true)],
        items: items,
        stockByWarehouse: {
          'unica': {'harina': 5.0, 'queso': 50.0},
        },
      );
      // Harina: 5 contra el mínimo global 20 → falta. Queso: 50 contra 10.
      expect(overview.byId('unica')!.lowStockCount, 1);
      expect(overview.byId('unica')!.minimumsConfigured, 2);
    });

    test('transferencias entrantes y último conteo llegan a la tarjeta', () {
      final counted = DateTime.now().subtract(const Duration(days: 47));
      final overview = InventoryWarehousesOverview.build(
        warehouses: warehouses,
        items: items,
        stockByWarehouse: stock,
        incomingTransfers: {'cocina': 1},
        lastCountByWarehouse: {'cocina': counted},
      );
      final cocina = overview.byId('cocina')!;
      expect(cocina.incomingTransfers, 1);
      expect(cocina.daysSinceCount(), 47);
      expect(overview.byId('principal')!.daysSinceCount(), isNull);
    });
  });
}
