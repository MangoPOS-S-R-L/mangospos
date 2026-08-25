import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/printing/usb_printer_identity.dart';

/// La identidad USB es lo que permite tener DOS impresoras del mismo modelo:
/// `vendorId:productId` es idéntico en ambas. Estos tests fijan (a) que los
/// formatos históricos siguen leyéndose — hay impresoras ya configuradas en
/// producción — y (b) que el formato nuevo distingue dispositivos.
void main() {
  group('UsbPrinterIdentity.parse — formatos legados', () {
    test('vid:pid decimal (scan Android histórico)', () {
      final id = UsbPrinterIdentity.parse('4611:8215');
      expect(id, isNotNull);
      expect(id!.vendorId, 4611);
      expect(id.productId, 8215);
      expect(id.deviceName, isNull);
      expect(id.serialNumber, isNull);
    });

    test('usb://hex (desktop)', () {
      final id = UsbPrinterIdentity.parse('usb://1a2b:3c4d');
      expect(id!.vendorId, 0x1a2b);
      expect(id.productId, 0x3c4d);
    });

    test('usb://hex/serie conserva la serie en vez de descartarla', () {
      final id = UsbPrinterIdentity.parse('usb://1a2b:3c4d/SN12345');
      expect(id!.vendorId, 0x1a2b);
      expect(id.productId, 0x3c4d);
      expect(id.serialNumber, 'SN12345');
    });

    test('basura devuelve null', () {
      expect(UsbPrinterIdentity.parse(null), isNull);
      expect(UsbPrinterIdentity.parse(''), isNull);
      expect(UsbPrinterIdentity.parse('USB001'), isNull);
      expect(UsbPrinterIdentity.parse('no:parseable'), isNull);
    });
  });

  group('UsbPrinterIdentity — formato actual', () {
    test('round-trip con deviceName y serie', () {
      const original = UsbPrinterIdentity(
        vendorId: 4611,
        productId: 8215,
        deviceName: '/dev/bus/usb/001/003',
        serialNumber: 'SN-A1',
      );
      final parsed = UsbPrinterIdentity.parse(original.storageValue);
      expect(parsed!.vendorId, 4611);
      expect(parsed.productId, 8215);
      // La ruta del bus lleva '/', que sin codificar rompería el parseo.
      expect(parsed.deviceName, '/dev/bus/usb/001/003');
      expect(parsed.serialNumber, 'SN-A1');
    });

    test('round-trip solo con deviceName (térmica sin serie)', () {
      const original = UsbPrinterIdentity(
        vendorId: 1046,
        productId: 20497,
        deviceName: '/dev/bus/usb/002/007',
      );
      final parsed = UsbPrinterIdentity.parse(original.storageValue);
      expect(parsed!.deviceName, '/dev/bus/usb/002/007');
      expect(parsed.serialNumber, isNull);
    });

    test('sin dispositivo concreto no agrega cola', () {
      const bare = UsbPrinterIdentity(vendorId: 4611, productId: 8215);
      expect(bare.storageValue, '4611:8215');
    });
  });

  group('discoveryKey — dos impresoras del mismo modelo', () {
    test('mismo vid:pid, distinto puerto ⇒ claves distintas', () {
      const a = UsbPrinterIdentity(
        vendorId: 4611,
        productId: 8215,
        deviceName: '/dev/bus/usb/001/003',
      );
      const b = UsbPrinterIdentity(
        vendorId: 4611,
        productId: 8215,
        deviceName: '/dev/bus/usb/001/004',
      );
      expect(a.discoveryKey, isNot(b.discoveryKey));
    });

    test('la serie manda sobre el puerto (sobrevive al recableado)', () {
      const a = UsbPrinterIdentity(
        vendorId: 4611,
        productId: 8215,
        deviceName: '/dev/bus/usb/001/003',
        serialNumber: 'SN-A1',
      );
      const b = UsbPrinterIdentity(
        vendorId: 4611,
        productId: 8215,
        deviceName: '/dev/bus/usb/001/009',
        serialNumber: 'SN-A1',
      );
      expect(a.discoveryKey, b.discoveryKey);
    });

    test('sin puerto ni serie cae a vid:pid (comportamiento histórico)', () {
      const a = UsbPrinterIdentity(vendorId: 4611, productId: 8215);
      expect(a.discoveryKey, 'usb:4611:8215');
    });
  });

  group('fromDeviceMap', () {
    test('lee el mapa de listDevices del canal nativo', () {
      final id = UsbPrinterIdentity.fromDeviceMap({
        'vendorId': 4611,
        'productId': 8215,
        'deviceName': '/dev/bus/usb/001/003',
        'serialNumber': 'SN-A1',
        'manufacturer': 'POS-80',
      });
      expect(id!.vendorId, 4611);
      expect(id.deviceName, '/dev/bus/usb/001/003');
      expect(id.serialNumber, 'SN-A1');
    });

    test('serial vacío se normaliza a null', () {
      final id = UsbPrinterIdentity.fromDeviceMap({
        'vendorId': 4611,
        'productId': 8215,
        'deviceName': '/dev/bus/usb/001/003',
        'serialNumber': '',
      });
      expect(id!.serialNumber, isNull);
    });

    test('sin vendor/product devuelve null', () {
      expect(UsbPrinterIdentity.fromDeviceMap({'manufacturer': 'X'}), isNull);
    });
  });
}
