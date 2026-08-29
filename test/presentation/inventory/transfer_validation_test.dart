// Transferencias entre bodegas: qué bloquea y qué NO.
//
// El caso que motivó la regla: en una bodega con un artículo cuadrado en
// negativo, el sistema no dejaba transferir NINGÚN otro producto. La
// validación recorría todos los ítems y comparaba `qty > stock`; para un ítem
// no seleccionado eso es `0 > -5`, que es cierto. Un problema de un artículo
// no puede congelar el movimiento de los demás.

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/presentation/inventory/state/inventory_state.dart';
import 'package:mangopos/presentation/inventory/utils/transfer_validation.dart';

InventoryItemSummary _item({
  required String id,
  required String name,
  required double stock,
  String unit = 'unidad',
}) {
  return InventoryItemSummary(
    id: id,
    sku: id.toUpperCase(),
    name: name,
    description: '',
    unit: unit,
    cost: 10,
    minStock: 0,
    maxStock: null,
    isActive: true,
    stock: stock,
  );
}

void main() {
  group('validateTransferLines', () {
    final ajo = _item(id: 'ajo', name: 'Ajo molido', stock: -5);
    final arroz = _item(id: 'arroz', name: 'Arroz', stock: 40);
    final aceite = _item(id: 'aceite', name: 'Aceite', stock: 0);

    test('un artículo en negativo NO bloquea transferir otro', () {
      // El caso reportado: el ajo está en -5 y no se está moviendo.
      final error = validateTransferLines(
        items: [ajo, arroz],
        quantities: const {'arroz': 10},
      );
      expect(error, isNull);
    });

    test('nada seleccionado no produce error de stock', () {
      final error = validateTransferLines(
        items: [ajo, arroz, aceite],
        quantities: const {},
      );
      expect(error, isNull);
    });

    test('una cantidad en cero explícita tampoco valida esa línea', () {
      final error = validateTransferLines(
        items: [ajo, arroz],
        quantities: const {'ajo': 0, 'arroz': 5},
      );
      expect(error, isNull);
    });

    test('sí bloquea el artículo en negativo cuando ES el que se transfiere',
        () {
      final error = validateTransferLines(
        items: [ajo, arroz],
        quantities: const {'ajo': 2},
      );
      expect(error, isNotNull);
      expect(error, contains('Ajo molido'));
      expect(error, contains('no hay existencia'));
    });

    test('stock en cero se bloquea con el mismo mensaje', () {
      final error = validateTransferLines(
        items: [aceite],
        quantities: const {'aceite': 1},
      );
      expect(error, contains('Aceite'));
      expect(error, contains('no hay existencia'));
    });

    test('pedir más de lo que hay se bloquea nombrando ambas cifras', () {
      final error = validateTransferLines(
        items: [arroz],
        quantities: const {'arroz': 50},
      );
      expect(error, contains('Arroz'));
      expect(error, contains('50.00'));
      expect(error, contains('40.00'));
    });

    test('transferir exactamente todo el stock se permite', () {
      final error = validateTransferLines(
        items: [arroz],
        quantities: const {'arroz': 40},
      );
      expect(error, isNull);
    });

    test('reporta el primer problema en el orden de la lista', () {
      final error = validateTransferLines(
        items: [ajo, arroz],
        quantities: const {'ajo': 1, 'arroz': 999},
      );
      expect(error, contains('Ajo molido'));
    });
  });
}
