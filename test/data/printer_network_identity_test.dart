import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/data/models/printing.dart';

PrinterConfig _printer({
  String type = 'network',
  String? mac,
  String? ip,
  int? port,
  Map<String, dynamic> connection = const {},
}) => PrinterConfig(
  id: 'printer-1',
  businessId: 'business-1',
  name: 'Cocina',
  type: type,
  mac: mac,
  ipAddress: ip,
  port: port,
  isActive: true,
  createdAt: DateTime.utc(2026),
  connectionConfig: connection,
);

void main() {
  test('normaliza los formatos habituales de MAC física', () {
    for (final value in [
      ' A0-B1-C2-D3-E4-F5 ',
      'a0:b1:c2:d3:e4:f5',
      'a0b1.c2d3.e4f5',
      'A0B1C2D3E4F5',
    ]) {
      expect(normalizeNetworkPrinterMac(value), 'a0:b1:c2:d3:e4:f5');
    }
  });

  test('rechaza IP, UUID, MAC vacía, multicast y broadcast', () {
    for (final value in [
      null,
      '',
      '192.168.1.20',
      'e712f694-145d-4739-80ca-bb764af9b0bd',
      '00:00:00:00:00:00',
      'ff:ff:ff:ff:ff:ff',
      '01:00:5e:00:00:01',
      'MAC a0:b1:c2:d3:e4:f5',
      'a0-b1:c2:d3:e4:f5',
      'a0b1-c2d3.e4f5',
      ':a0:b1:c2:d3:e4:f5',
    ]) {
      expect(normalizeNetworkPrinterMac(value), isNull, reason: '$value');
    }
  });

  test('configuración vacía o inválida conserva fallback legacy válido', () {
    final printer = _printer(
      ip: '192.168.1.20',
      mac: 'A0-B1-C2-D3-E4-F5',
      port: 9100,
      connection: {'ip': ' ', 'mac': '192.168.1.20', 'port': 'invalid'},
    );
    expect(printer.effectiveIp, '192.168.1.20');
    expect(printer.effectiveMac, 'a0:b1:c2:d3:e4:f5');
    expect(printer.effectivePort, 9100);
  });

  test('valores v2 efectivos llegan a la tarjeta y al diálogo', () {
    final printer = _printer(
      ip: '192.168.1.20',
      port: 9100,
      connection: {
        'ip': ' 192.168.1.25 ',
        'mac': 'A0B1.C2D3.E4F5',
        'port': '9101',
      },
    );
    final device = PrinterDevice.fromConfig(printer);
    expect(device.ip, '192.168.1.25');
    expect(device.mac, 'a0:b1:c2:d3:e4:f5');
    expect(device.port, 9101);
  });

  test('puertos fuera de rango caen al puerto legacy', () {
    for (final value in [0, -1, 65536, '0']) {
      expect(
        _printer(port: 9100, connection: {'port': value}).effectivePort,
        9100,
      );
    }
  });

  test('mapa v2 sin columnas legacy usa IP, MAC y puerto del config', () {
    final map = <String, dynamic>{
      'id': 'p1',
      'business_id': 'b1',
      'transport': 'lan',
      'is_active': true,
      'connection_config':
          '{"ip":"192.168.1.25","mac_address":"a0b1c2d3e4f5","port":"9101"}',
    };
    for (final device in [
      PrinterDevice.fromMap(map),
      PrinterDevice.fromConfig(PrinterConfig.fromMap(map)),
    ]) {
      expect(device.ip, '192.168.1.25');
      expect(device.mac, 'a0:b1:c2:d3:e4:f5');
      expect(device.port, 9101);
    }
  });

  test('identidad Bluetooth opaca se conserva', () {
    const uuid = 'e712f694-145d-4739-80ca-bb764af9b0bd';
    final printer = _printer(type: 'bluetooth', mac: uuid);
    expect(printer.effectiveMac, uuid);
    expect(PrinterDevice.fromConfig(printer).mac, uuid);
    expect(PrinterDevice.fromMap(printer.toMap()).mac, uuid);
  });

  test('roundtrip de tarjeta conserva configuración e identidades de host', () {
    final device = PrinterDevice(
      id: 'p1',
      businessId: 'b1',
      name: 'USB',
      type: PrinterType.usb,
      online: true,
      createdAt: DateTime.utc(2026),
      hostDeviceId: 'host1',
      fallbackPrinterId: 'p2',
      connectionConfig: const {'print_speed': 'fast'},
    );
    final restored = PrinterDevice.fromMap(device.toMap());
    expect(restored.hostDeviceId, 'host1');
    expect(restored.fallbackPrinterId, 'p2');
    expect(restored.connectionConfig, {'print_speed': 'fast'});
  });
}
