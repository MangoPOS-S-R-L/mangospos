// Resolución del "modo sin impresora": el override del dispositivo manda
// sobre el flag del negocio. Los casos `alwaysPrint`/`neverPrint` cortan
// antes de tocar la red, que es justamente lo que los hace testeables (y lo
// que hace que una caja sin internet siga respetando su configuración).

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/printing/printerless_mode.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PrinterlessMode.invalidate();
  });

  group('PrinterlessDeviceOverride', () {
    test('fromWire tolera valores desconocidos y nulos', () {
      expect(
        PrinterlessDeviceOverride.fromWire('alwaysPrint'),
        PrinterlessDeviceOverride.alwaysPrint,
      );
      expect(
        PrinterlessDeviceOverride.fromWire('neverPrint'),
        PrinterlessDeviceOverride.neverPrint,
      );
      expect(
        PrinterlessDeviceOverride.fromWire(null),
        PrinterlessDeviceOverride.inherit,
      );
      expect(
        PrinterlessDeviceOverride.fromWire('basura'),
        PrinterlessDeviceOverride.inherit,
      );
    });
  });

  group('PrinterlessMode', () {
    test('sin configurar, el dispositivo hereda del negocio', () async {
      expect(
        await PrinterlessMode.deviceOverride(),
        PrinterlessDeviceOverride.inherit,
      );
    });

    test('el override sobrevive un roundtrip por SharedPreferences', () async {
      await PrinterlessMode.setDeviceOverride(
        PrinterlessDeviceOverride.neverPrint,
      );
      PrinterlessMode.invalidate(); // fuerza releer del disco

      expect(
        await PrinterlessMode.deviceOverride(),
        PrinterlessDeviceOverride.neverPrint,
      );
    });

    test('neverPrint activa el modo sin consultar al negocio', () async {
      await PrinterlessMode.setDeviceOverride(
        PrinterlessDeviceOverride.neverPrint,
      );

      // businessId inexistente a propósito: si el override no cortara, esto
      // intentaría pegarle a Supabase.
      expect(await PrinterlessMode.isEnabled('negocio-que-no-existe'), isTrue);
    });

    test('alwaysPrint desactiva el modo aunque el negocio lo pida', () async {
      await PrinterlessMode.setDeviceOverride(
        PrinterlessDeviceOverride.alwaysPrint,
      );

      expect(await PrinterlessMode.isEnabled('negocio-que-no-existe'), isFalse);
    });

    test('sin negocio resuelto no se activa solo', () async {
      expect(await PrinterlessMode.businessEnabled(''), isFalse);
      expect(await PrinterlessMode.kitchenEnabled(''), isFalse);
    });

    test('el override del device NO toca las comandas', () async {
      // La impresora de cocina es compartida: que esta tablet no tenga
      // impresora propia no puede dejar a la cocina sin comanda.
      await PrinterlessMode.setDeviceOverride(
        PrinterlessDeviceOverride.neverPrint,
      );

      expect(await PrinterlessMode.isEnabled('negocio-que-no-existe'), isTrue);
      expect(await PrinterlessMode.kitchenEnabled(''), isFalse);
    });
  });
}
