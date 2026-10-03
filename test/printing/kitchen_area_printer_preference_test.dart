// Impresora de comanda por dispositivo cuando un área de producción tiene
// 2+ impresoras. Como la precuenta: se pregunta la primera vez al enviar a
// cocina, queda fijada en el dispositivo y sin elección imprime en todas
// (el comportamiento de antes).

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/printing/kitchen_area_printer_preference.dart';
import 'package:mangopos/data/models/printing.dart';
import 'package:shared_preferences/shared_preferences.dart';

PrinterConfig _printer(String id) => PrinterConfig(
  id: id,
  businessId: 'b1',
  name: id,
  type: 'network',
  ipAddress: '192.168.1.50',
  isActive: true,
  createdAt: DateTime(2026, 1, 1),
);

void main() {
  final cocina1 = _printer('cocina-1');
  final cocina2 = _printer('cocina-2');
  final both = [cocina1, cocina2];

  setUp(() => SharedPreferences.setMockInitialValues({}));

  /// Chooser que responde [answer] y cuenta cuántas veces se preguntó.
  ({KitchenAreaPrinterChooser chooser, List<String?> seenCurrent}) answering(
    String? answer,
  ) {
    final seen = <String?>[];
    return (
      chooser: (areaName, printers, current) async {
        seen.add(current);
        return answer;
      },
      seenCurrent: seen,
    );
  }

  Future<List<PrinterConfig>> resolve({
    String device = 'tablet-salon',
    List<PrinterConfig>? printers,
    KitchenAreaPrinterChooser? chooser,
    bool force = false,
  }) => KitchenAreaPrinterPreference.resolve(
    deviceId: device,
    areaCode: 'cocina',
    areaLabel: 'Cocina',
    printers: printers ?? both,
    chooser: chooser,
    forceChoose: force,
  );

  test('con una sola impresora no pregunta', () async {
    final ask = answering('cocina-1');
    final result = await resolve(printers: [cocina1], chooser: ask.chooser);
    expect(result, [cocina1]);
    expect(ask.seenCurrent, isEmpty);
  });

  test(
    'sin elección y sin selector (replay/reimpresión) imprime en todas',
    () async {
      expect(await resolve(), both);
    },
  );

  test(
    'la primera vez pregunta, fija la elección y no vuelve a preguntar',
    () async {
      final first = answering('cocina-2');
      expect(await resolve(chooser: first.chooser), [cocina2]);
      expect(first.seenCurrent, [null]);

      final second = answering('cocina-1');
      expect(await resolve(chooser: second.chooser), [cocina2]);
      expect(second.seenCurrent, isEmpty);

      // Las reimpresiones (sin selector) siguen la elección del dispositivo.
      expect(await resolve(), [cocina2]);
    },
  );

  test('cada dispositivo tiene su propia impresora', () async {
    await resolve(
      device: 'tablet-salon',
      chooser: answering('cocina-1').chooser,
    );
    await resolve(
      device: 'tablet-patio',
      chooser: answering('cocina-2').chooser,
    );
    expect(await resolve(device: 'tablet-salon'), [cocina1]);
    expect(await resolve(device: 'tablet-patio'), [cocina2]);
  });

  test('"Todas" queda fijada como elección', () async {
    final ask = answering(KitchenAreaPrinterPreference.allPrinters);
    expect(await resolve(chooser: ask.chooser), both);
    final again = answering('cocina-1');
    expect(await resolve(chooser: again.chooser), both);
    expect(again.seenCurrent, isEmpty);
  });

  test('mantener presionado vuelve a preguntar y muestra la actual', () async {
    await resolve(chooser: answering('cocina-1').chooser);
    final ask = answering('cocina-2');
    expect(await resolve(chooser: ask.chooser, force: true), [cocina2]);
    expect(ask.seenCurrent, ['cocina-1']);
  });

  test('cerrar sin elegir: usa la fijada, o todas sin guardar', () async {
    expect(await resolve(chooser: answering(null).chooser), both);
    // No quedó guardado: la próxima vez vuelve a preguntar.
    final ask = answering('cocina-1');
    await resolve(chooser: ask.chooser);
    expect(ask.seenCurrent, [null]);

    expect(await resolve(chooser: answering(null).chooser, force: true), [
      cocina1,
    ]);
  });

  test('si quitan la impresora fijada del área, pregunta de nuevo', () async {
    await resolve(chooser: answering('cocina-2').chooser);
    final cocina3 = _printer('cocina-3');
    final ask = answering('cocina-3');
    final result = await resolve(
      printers: [cocina1, cocina3],
      chooser: ask.chooser,
    );
    expect(result, [cocina3]);
    expect(ask.seenCurrent, [null]);
    // Sin selector y con la fijada vieja inválida: todas.
    SharedPreferences.setMockInitialValues({
      'kitchen_area_printer_tablet-salon_cocina': 'cocina-2',
    });
    expect(await resolve(printers: [cocina1, cocina3]), [cocina1, cocina3]);
  });
}
