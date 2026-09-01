// La resolución del código escaneado. Es la mitad del trabajo de la pistola
// que NO se puede probar con hardware en CI, y es donde un error mete
// mercancía en el insumo equivocado sin que nadie se entere.

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/presentation/inventory/services/inventory_scan.dart';
import 'package:mangopos/presentation/inventory/state/inventory_state.dart';

InventoryItemSummary _item({
  required String id,
  required String name,
  String sku = '',
  String barcode = '',
  bool isActive = true,
}) {
  return InventoryItemSummary(
    id: id,
    sku: sku,
    name: name,
    description: '',
    unit: 'unidad',
    cost: 10,
    minStock: 0,
    maxStock: null,
    isActive: isActive,
    stock: 0,
    barcode: barcode,
  );
}

void main() {
  group('resolveScannedItem', () {
    final ron = _item(
      id: 'ron',
      name: 'Brugal Añejo 750ml',
      sku: 'LIC-001',
      barcode: '7461323129336',
    );
    final cerveza = _item(
      id: 'cerveza',
      name: 'Presidente 12oz',
      sku: 'CER-001',
      barcode: '74653294',
    );
    // El caso que rompe una búsqueda de tipo "contiene": su NOMBRE lleva los
    // dígitos del código de otro insumo.
    final trampa = _item(
      id: 'trampa',
      name: 'Combo 74653294 aniversario',
      sku: 'COMBO-1',
      barcode: '',
    );
    final catalogo = [ron, cerveza, trampa];

    test('código de barras exacto gana', () {
      final r = resolveScannedItem(catalogo, '7461323129336');
      expect(r.isResolved, isTrue);
      expect(r.item!.id, 'ron');
    });

    test('un nombre que contiene el código NO se lleva el escaneo', () {
      // Sin esto, escanear la cerveza podría agregar el combo.
      final r = resolveScannedItem(catalogo, '74653294');
      expect(r.isResolved, isTrue);
      expect(r.item!.id, 'cerveza');
    });

    test('sin código de barras, resuelve por SKU exacto', () {
      final r = resolveScannedItem(catalogo, 'COMBO-1');
      expect(r.isResolved, isTrue);
      expect(r.item!.id, 'trampa');
    });

    test('el espacio y las mayúsculas no importan', () {
      final r = resolveScannedItem(catalogo, '  lic-001  ');
      expect(r.isResolved, isTrue);
      expect(r.item!.id, 'ron');
    });

    test('un código que no existe devuelve notFound', () {
      final r = resolveScannedItem(catalogo, '0000000000');
      expect(r.outcome, ScanOutcome.notFound);
    });

    test('dos insumos con el mismo código NO se resuelven al azar', () {
      // Datos mal cargados: hay que arreglarlos, no taparlos eligiendo uno.
      final duplicado = _item(
        id: 'otro',
        name: 'Brugal repetido',
        barcode: '7461323129336',
      );
      final r = resolveScannedItem([...catalogo, duplicado], '7461323129336');
      expect(r.outcome, ScanOutcome.ambiguous);
      expect(r.candidates.length, 2);
    });

    test('un insumo inactivo no responde al escaneo', () {
      final baja = _item(
        id: 'baja',
        name: 'Descontinuado',
        barcode: '999',
        isActive: false,
      );
      expect(
        resolveScannedItem([baja], '999').outcome,
        ScanOutcome.notFound,
      );
      // …salvo que la pantalla pida explícitamente incluirlos.
      expect(
        resolveScannedItem([baja], '999', onlyActive: false).isResolved,
        isTrue,
      );
    });

    test('coincidencia parcial única: cubre el cero de más del lector', () {
      final r = resolveScannedItem(catalogo, '746132312933');
      expect(r.isResolved, isTrue);
      expect(r.item!.id, 'ron');
    });

    test('coincidencia parcial ambigua no resuelve', () {
      final otro = _item(id: 'otro', name: 'Otro', barcode: '7461323129337');
      final r = resolveScannedItem([...catalogo, otro], '746132312933');
      expect(r.outcome, ScanOutcome.ambiguous);
    });

    test('un código vacío no hace nada', () {
      expect(resolveScannedItem(catalogo, '   ').outcome, ScanOutcome.notFound);
    });
  });
}
