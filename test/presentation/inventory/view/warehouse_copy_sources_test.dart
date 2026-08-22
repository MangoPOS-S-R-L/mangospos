// Alta de bodega — de dónde se copia la lista de insumos.
//
// Al crear una bodega se pregunta si se copia la lista de insumos de otra.
// Lo que se copia es la LISTA, nunca las existencias (eso lo garantiza la
// función SQL `fn_inventory_copy_warehouse_items`, que inserta siempre en
// cero). Acá se fija la otra mitad: qué bodegas pueden ser el origen.
//
// No se monta el diálogo porque necesita un `SupabaseClient`, que arranca
// timers de refresco de sesión y ensucia el test; la decisión vive en
// `CopySourceOptions`, que es pura.

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/presentation/inventory/state/inventory_state.dart';
import 'package:mangopos/presentation/inventory/view/widgets/warehouse_form_dialog.dart';

InventoryWarehouseDetail _w(
  String id, {
  required String name,
  bool isMain = false,
  bool isActive = true,
}) => InventoryWarehouseDetail(
  id: id,
  name: name,
  address: '',
  isMain: isMain,
  isActive: isActive,
  createdAt: null,
);

void main() {
  group('CopySourceOptions', () {
    test('la principal viene elegida por defecto', () {
      final options = CopySourceOptions.from([
        _w('cocina', name: 'Cocina'),
        _w('principal', name: 'Principal', isMain: true),
      ]);
      expect(options.defaultSourceId, 'principal');
      expect(options.sources.length, 2);
    });

    test('sin principal, la primera de la lista', () {
      final options = CopySourceOptions.from([
        _w('cocina', name: 'Cocina'),
        _w('bar', name: 'Bar'),
      ]);
      expect(options.defaultSourceId, 'cocina');
    });

    test('la de tránsito y las inactivas no son un origen válido', () {
      final options = CopySourceOptions.from([
        _w('principal', name: 'Principal', isMain: true),
        _w('naco', name: 'Depósito Naco', isActive: false),
        _w('transito', name: '__IN_TRANSIT__'),
      ]);
      expect(options.sources.map((w) => w.id).toList(), ['principal']);
    });

    test('sin ninguna bodega usable queda "todo el catálogo"', () {
      final options = CopySourceOptions.from([
        _w('transito', name: '__IN_TRANSIT__'),
      ]);
      expect(options.sources, isEmpty);
      expect(options.defaultSourceId, kCopyFromWholeCatalog);
    });

    test('la primera bodega del negocio también cae en "todo el catálogo"', () {
      final options = CopySourceOptions.from(const []);
      expect(options.defaultSourceId, kCopyFromWholeCatalog);
    });
  });
}
