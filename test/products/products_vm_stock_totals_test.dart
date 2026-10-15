// El total de todos los almacenes se lee aparte de la lista (no la frena),
// se aplica al llegar y se conserva al recargar productos para no parpadear.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mangopos/data/repositories/products_repository.dart';
import 'package:mangopos/presentation/products/viewmodel/products_viewmodel.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Map<String, dynamic> _beer() => {
  'id': 'cerveza',
  'name': 'Presidente',
  'is_inventory_tracked': true,
  'stock': {'available_units': 20, 'unit': 'und'},
};

class _Repo extends ProductsRepository {
  _Repo(super.client);

  final totals = <Completer<Map<String, int>>>[];
  int productReloads = 0;

  @override
  Future<
    ({
      List<Map<String, dynamic>> products,
      List<Map<String, dynamic>> categories,
      List<Map<String, dynamic>> menus,
    })
  >
  getProductsCatalog(String businessId) async => (
    products: [_beer()],
    categories: const <Map<String, dynamic>>[],
    menus: const <Map<String, dynamic>>[],
  );

  @override
  Future<Map<String, List<Map<String, dynamic>>>> getPrintAreasByProduct(
    String businessId,
  ) async => const {};

  @override
  Future<List<Map<String, dynamic>>> getProducts(String businessId) async {
    productReloads++;
    return [_beer()];
  }

  @override
  Future<void> toggleAvailability({
    required String id,
    required bool isActive,
  }) async {}

  @override
  Future<Map<String, int>> getStockAcrossWarehouses(String businessId) {
    final c = Completer<Map<String, int>>();
    totals.add(c);
    return c.future;
  }
}

void main() {
  late SupabaseClient client;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    client = SupabaseClient('http://localhost:54321', 'test-key');
    await Supabase.initialize(
      url: 'http://localhost:54321',
      publishableKey: 'test',
      httpClient: MockClient(
        (request) async => http.Response(
          request.method == 'GET' ? '[]' : 'null',
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        ),
      ),
    );
  });

  tearDownAll(() async {
    await client.dispose();
    await Supabase.instance.dispose();
  });

  test('la lista sale sin esperar el total; el total llega después y se '
      'conserva al recargar', () async {
    final repo = _Repo(client);
    final vm = ProductsViewModel(repo);
    addTearDown(vm.dispose);

    await vm.init(businessId: 'biz-1');
    expect(vm.isLoading, isFalse, reason: 'no esperó el total');
    expect(vm.products.single['stock_total_units'], isNull);

    var notified = 0;
    vm.addListener(() => notified++);
    repo.totals.single.complete({'cerveza': 120});
    await pumpEventQueue();
    expect(vm.products.single['stock_total_units'], 120);
    expect(notified, greaterThan(0));

    // Recarga (p. ej. al apagar el producto): el total anterior se aplica de
    // inmediato a la lista nueva y se vuelve a leer.
    await vm.toggleAvailability('cerveza', true);
    expect(repo.productReloads, 1);
    expect(vm.products.single['stock_total_units'], 120);
    expect(repo.totals, hasLength(2));

    repo.totals.last.complete({'cerveza': 90});
    await pumpEventQueue();
    expect(vm.products.single['stock_total_units'], 90);
  });

  test('si la lectura del total falla, la lista queda con la existencia de '
      'venta', () async {
    final repo = _Repo(client);
    final vm = ProductsViewModel(repo);
    addTearDown(vm.dispose);

    await vm.init(businessId: 'biz-2');
    repo.totals.single.completeError(Exception('sin permiso'));
    await pumpEventQueue();
    expect(vm.error, isNull);
    expect(vm.products.single['stock_total_units'], isNull);
    expect(vm.products.single['stock'], isNotNull);
  });

  test('una lectura vieja no pisa a la más nueva', () async {
    final repo = _Repo(client);
    final vm = ProductsViewModel(repo);
    addTearDown(vm.dispose);

    await vm.init(businessId: 'biz-3');
    await vm.toggleAvailability('cerveza', true);
    repo.totals.last.complete({'cerveza': 7});
    await pumpEventQueue();
    repo.totals.first.complete({'cerveza': 999});
    await pumpEventQueue();
    expect(vm.products.single['stock_total_units'], 7);
  });
}
