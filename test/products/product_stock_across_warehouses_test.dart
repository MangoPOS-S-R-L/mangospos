// Productos: la existencia se suma en TODOS los almacenes activos (pedido del
// dueño, 13-oct). `v_menu_items_stock` suma solo los almacenes del punto de
// venta, así que en un negocio con un almacén por área (o un Principal que no
// vende) la lista mostraba una fracción de lo que hay.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mangopos/data/repositories/products_repository.dart';
import 'package:mangopos/presentation/products/widgets/product_stock_summary.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  group('unitsAcrossWarehouses', () {
    test('suma el insumo en todos los almacenes y divide por lo que lleva '
        'cada unidad, con piso como la vista', () {
      final units = ProductsRepository.unitsAcrossWarehouses(
        links: [
          {
            'menu_item_id': 'cerveza',
            'inventory_item_id': 'ins-cerveza',
            'ingredient_per_unit': 1,
          },
          {
            'menu_item_id': 'trago',
            'inventory_item_id': 'ins-ron',
            'ingredient_per_unit': '0.1',
          },
          {
            'menu_item_id': 'sin-existencia',
            'inventory_item_id': 'ins-nada',
            'ingredient_per_unit': 1,
          },
        ],
        stockRows: [
          {'item_id': 'ins-cerveza', 'quantity': 24},
          {'item_id': 'ins-cerveza', 'quantity': 96},
          {'item_id': 'ins-cerveza', 'quantity': '5.5'},
          // 0.3 / 0.1 da 2.999… en coma flotante: deben ser 3.
          {'item_id': 'ins-ron', 'quantity': 0.3},
        ],
      );
      expect(units, {'cerveza': 125, 'trago': 3, 'sin-existencia': 0});
    });

    test('existencia negativa baja con piso y un vínculo sin cantidad por '
        'unidad no inventa un total', () {
      final units = ProductsRepository.unitsAcrossWarehouses(
        links: [
          {
            'menu_item_id': 'a',
            'inventory_item_id': 'ins-a',
            'ingredient_per_unit': 1,
          },
          {
            'menu_item_id': 'b',
            'inventory_item_id': 'ins-b',
            'ingredient_per_unit': 0,
          },
          {'menu_item_id': 'c', 'inventory_item_id': 'ins-c'},
        ],
        stockRows: [
          {'item_id': 'ins-a', 'quantity': 10},
          {'item_id': 'ins-a', 'quantity': -12.5},
          {'item_id': 'ins-b', 'quantity': 10},
        ],
      );
      expect(units, {'a': -3});
    });
  });

  test('getStockAcrossWarehouses: solo almacenes activos del negocio y lee '
      'todas las páginas de existencia', () async {
    final stockRequests = <Map<String, String>>[];
    final client = SupabaseClient(
      'http://localhost:54321',
      'test-key',
      httpClient: MockClient((request) async {
        final path = request.url.path;
        final query = request.url.queryParameters;
        Object body;
        if (path.endsWith('/v_menu_items_stock')) {
          body = [
            {
              'menu_item_id': 'cerveza',
              'inventory_item_id': 'ins-cerveza',
              'ingredient_per_unit': 1,
            },
          ];
        } else if (path.endsWith('/warehouses')) {
          expect(query['business_id'], 'eq.biz-1');
          body = [
            {'id': 'w-principal', 'is_active': true},
            {'id': 'w-barra', 'is_active': null},
            {'id': 'w-cerrado', 'is_active': false},
          ];
        } else if (path.endsWith('/inventory_stock')) {
          stockRequests.add(query);
          final filter = query['warehouse_id']!;
          expect(filter, contains('w-principal'));
          expect(filter, contains('w-barra'));
          expect(filter, isNot(contains('w-cerrado')));
          // Primera página llena (1000 filas de 1) y una segunda con 3 más.
          final offset = int.parse(query['offset'] ?? '0');
          body = offset == 0
              ? List.generate(
                  1000,
                  (_) => {'item_id': 'ins-cerveza', 'quantity': 1},
                )
              : [
                  {'item_id': 'ins-cerveza', 'quantity': 3},
                ];
        } else {
          fail('consulta inesperada: $path');
        }
        return http.Response(
          jsonEncode(body),
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      }),
    );
    addTearDown(client.dispose);

    final units = await ProductsRepository(
      client,
    ).getStockAcrossWarehouses('biz-1');

    expect(units, {'cerveza': 1003});
    expect(stockRequests, hasLength(2), reason: 'leyó la segunda página');
  });

  group('productStockSummary', () {
    Map<String, dynamic> product({Object? total, Object? sale = 20}) => {
      'is_inventory_tracked': true,
      'stock': {'available_units': sale, 'unit': 'und'},
      'stock_total_units': ?total,
    };

    test('total distinto de lo vendible: muestra los dos', () {
      final s = productStockSummary(product(total: 120))!;
      expect(s.text, 'Total: 120 und · Venta: 20');
      expect(s.isLow, isFalse);
    });

    test('total igual a lo vendible: solo el total', () {
      expect(productStockSummary(product(total: 20))!.text, 'Total: 20 und');
    });

    test('sin total todavía: la existencia de venta, como antes', () {
      expect(productStockSummary(product())!.text, 'Stock: 20 und');
    });

    test('hay en otros almacenes pero nada para vender: se marca bajo', () {
      final s = productStockSummary(product(total: 50, sale: 0))!;
      expect(s.text, 'Total: 50 und · Venta: 0');
      expect(s.isLow, isTrue);
    });

    test('producto sin inventario no muestra existencia', () {
      expect(
        productStockSummary({
          'is_inventory_tracked': false,
          'stock': {'available_units': 3},
          'stock_total_units': 9,
        }),
        isNull,
      );
    });
  });
}
