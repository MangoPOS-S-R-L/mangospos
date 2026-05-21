import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mangopos/data/models/printing.dart';
import 'package:mangopos/data/models/printing_v2.dart';
import 'package:mangopos/services/printing/print_destination.dart';
import 'package:mangopos/presentation/sales/widgets/precheck/print_destination_picker.dart';

PrinterConfig _makePrinter({
  required String id,
  required String name,
  PrinterTransport transport = PrinterTransport.lan,
  String? ip,
  String? mac,
}) {
  return PrinterConfig(
    id: id,
    businessId: 'biz-1',
    name: name,
    type: 'network',
    ipAddress: ip,
    port: ip != null ? 9100 : null,
    mac: mac,
    isActive: true,
    createdAt: DateTime.utc(2026, 5, 21),
    transport: transport,
    connectionConfig: {
      if (ip != null) 'ip': ip,
      if (mac != null) 'mac': mac,
    },
  );
}

void main() {
  group('PrintDestination.fromPrinter', () {
    test('subtítulo incluye transport y IP para LAN', () {
      final p = _makePrinter(id: 'p1', name: 'Caja 1', ip: '192.168.1.50');
      final d = PrintDestination.fromPrinter(p);

      expect(d.displayName, 'Caja 1');
      expect(d.subtitle, 'LAN · 192.168.1.50');
      expect(d.kind, PrintDestinationKind.printer);
      expect(d.printer, same(p));
    });

    test('subtítulo incluye transport y MAC para Bluetooth', () {
      final p = _makePrinter(
        id: 'p2',
        name: 'BT Mozo',
        transport: PrinterTransport.bluetooth,
        mac: '00:11:22:33:44:55',
      );
      final d = PrintDestination.fromPrinter(p);

      expect(d.subtitle, 'BLUETOOTH · 00:11:22:33:44:55');
    });

    test('subtítulo solo transport si no hay IP/MAC/devicePath', () {
      final p = _makePrinter(
        id: 'p3',
        name: 'USB',
        transport: PrinterTransport.usb,
      );
      final d = PrintDestination.fromPrinter(p);
      expect(d.subtitle, 'USB');
    });

    test('health se asigna correctamente cuando se pasa', () {
      final p = _makePrinter(id: 'p4', name: 'X', ip: '1.1.1.1');
      final h = PrinterHealthRecord(
        printerId: 'p4',
        status: PrinterHealthStatus.noPaper,
        lastCheckedAt: DateTime.utc(2026, 5, 21),
        updatedAt: DateTime.utc(2026, 5, 21),
      );
      final d = PrintDestination.fromPrinter(p, health: h);
      expect(d.health, h);
    });
  });

  group('PrintDestination.screenOnly', () {
    test('kind = screenOnly y persistKey con prefijo __', () {
      final d = PrintDestination.screenOnly();
      expect(d.kind, PrintDestinationKind.screenOnly);
      expect(d.printer, isNull);
      expect(d.persistKey, '__screenOnly');
    });
  });

  group('PrintDestination.persistKey', () {
    test('printer → id del printer', () {
      final p = _makePrinter(id: 'p-9', name: 'Caja');
      final d = PrintDestination.fromPrinter(p);
      expect(d.persistKey, 'p-9');
    });

    test('persistKey distinto entre printer y screenOnly', () {
      final p = _makePrinter(id: 'p-9', name: 'Caja');
      expect(
        PrintDestination.fromPrinter(p).persistKey,
        isNot(PrintDestination.screenOnly().persistKey),
      );
    });
  });

  group('PrechecPrinterPreference', () {
    setUp(() {
      WidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
    });

    test('read retorna null cuando no hay valor guardado', () async {
      final v = await PrechecPrinterPreference.read('dev-1');
      expect(v, isNull);
    });

    test('save + read roundtrip por device', () async {
      await PrechecPrinterPreference.save('dev-1', 'printer-uuid-abc');
      final v = await PrechecPrinterPreference.read('dev-1');
      expect(v, 'printer-uuid-abc');
    });

    test('save no afecta a otro device', () async {
      await PrechecPrinterPreference.save('dev-1', 'A');
      await PrechecPrinterPreference.save('dev-2', 'B');
      expect(await PrechecPrinterPreference.read('dev-1'), 'A');
      expect(await PrechecPrinterPreference.read('dev-2'), 'B');
    });

    test('save sobreescribe valor previo del mismo device', () async {
      await PrechecPrinterPreference.save('dev-1', 'old');
      await PrechecPrinterPreference.save('dev-1', 'new');
      expect(await PrechecPrinterPreference.read('dev-1'), 'new');
    });
  });
}
