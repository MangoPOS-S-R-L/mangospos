// "Contexto que viaja": la bodega elegida en Insumos manda en el resto del
// módulo (cuadre, salidas, kardex). Esas pantallas NO saben trabajar en
// "Todas", así que la resolución del fallback es lo que decide en qué bodega
// terminan escribiendo — se prueba acá porque equivocarse significa registrar
// un movimiento en un almacén que nadie eligió.
//
// Solo se ejercita la parte pura: `ensureRestored`/`select` persistidos
// necesitan `StorageService`, pero `select` sin `ensureRestored` previo no
// toca disco (no hay negocio al que asociar la clave), así que sirve para
// posicionar el estado.

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/presentation/inventory/state/inventory_warehouse_scope.dart';

void main() {
  const ids = ['principal', 'cocina', 'bar'];

  group('InventoryWarehouseScope', () {
    test('arranca en "Todas · comparar"', () {
      expect(InventoryWarehouseScope().state, isNull);
    });

    test('en "Todas" las pantallas de una sola bodega caen al fallback', () {
      final scope = InventoryWarehouseScope();
      expect(scope.effectiveId(ids, 'principal'), 'principal');
    });

    test('con contexto elegido, ese gana sobre el fallback', () async {
      final scope = InventoryWarehouseScope();
      await scope.select('bar');
      expect(scope.state, 'bar');
      expect(scope.effectiveId(ids, 'principal'), 'bar');
    });

    test('un contexto que apunta a una bodega borrada cae al fallback', () async {
      final scope = InventoryWarehouseScope();
      await scope.select('naco-desactivada');
      expect(scope.effectiveId(ids, 'principal'), 'principal');
    });

    test('sin bodegas válidas ni fallback no se inventa ninguna', () async {
      final scope = InventoryWarehouseScope();
      await scope.select('bar');
      expect(scope.effectiveId(const [], null), isNull);
    });

    test('volver a "Todas" limpia el contexto', () async {
      final scope = InventoryWarehouseScope();
      await scope.select('cocina');
      await scope.select(null);
      expect(scope.state, isNull);
      expect(scope.effectiveId(ids, 'principal'), 'principal');
    });
  });
}
