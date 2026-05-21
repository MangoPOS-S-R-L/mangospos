import 'package:flutter_test/flutter_test.dart';

import 'package:mangopos/data/models/printing_v2.dart';
import 'package:mangopos/data/models/printing.dart';

void main() {
  group('PrinterTransport enum', () {
    test('fromName acepta legacy y aliases', () {
      expect(PrinterTransportX.fromName('lan'), PrinterTransport.lan);
      expect(PrinterTransportX.fromName('network'), PrinterTransport.lan);
      expect(PrinterTransportX.fromName('tcp'), PrinterTransport.lan);
      expect(PrinterTransportX.fromName('bluetooth'), PrinterTransport.bluetooth);
      expect(PrinterTransportX.fromName('bt'), PrinterTransport.bluetooth);
      expect(PrinterTransportX.fromName('usb'), PrinterTransport.usb);
      expect(PrinterTransportX.fromName('serial'), PrinterTransport.serial);
      expect(PrinterTransportX.fromName('cups'), PrinterTransport.cups);
    });

    test('fromName cae a lan en valores desconocidos o null', () {
      expect(PrinterTransportX.fromName(null), PrinterTransport.lan);
      expect(PrinterTransportX.fromName(''), PrinterTransport.lan);
      expect(PrinterTransportX.fromName('zigbee'), PrinterTransport.lan);
    });

    test('wireName matchea valores del CHECK en BD', () {
      expect(PrinterTransport.lan.wireName, 'lan');
      expect(PrinterTransport.usb.wireName, 'usb');
      expect(PrinterTransport.bluetooth.wireName, 'bluetooth');
      expect(PrinterTransport.serial.wireName, 'serial');
      expect(PrinterTransport.cups.wireName, 'cups');
    });
  });

  group('PrinterPurpose enum', () {
    test('roundtrip wireName → fromName', () {
      for (final p in PrinterPurpose.values) {
        expect(PrinterPurposeX.fromName(p.wireName), p);
      }
    });

    test('fromName cae a general en valores desconocidos', () {
      expect(PrinterPurposeX.fromName(null), PrinterPurpose.general);
      expect(PrinterPurposeX.fromName('payroll'), PrinterPurpose.general);
    });
  });

  group('PrinterHealthStatus enum', () {
    test('roundtrip wireName → fromName', () {
      for (final s in PrinterHealthStatus.values) {
        expect(PrinterHealthStatusX.fromName(s.wireName), s);
      }
    });

    test('isOperational y needsAttention son disjuntos para estados claros',
        () {
      expect(PrinterHealthStatus.online.isOperational, isTrue);
      expect(PrinterHealthStatus.online.needsAttention, isFalse);
      expect(PrinterHealthStatus.offline.isOperational, isFalse);
      expect(PrinterHealthStatus.offline.needsAttention, isFalse);
      expect(PrinterHealthStatus.noPaper.needsAttention, isTrue);
      expect(PrinterHealthStatus.noPaper.isOperational, isFalse);
      expect(PrinterHealthStatus.coverOpen.needsAttention, isTrue);
      expect(PrinterHealthStatus.lowPaper.isOperational, isTrue,
          reason: 'low_paper sigue imprimiendo, solo advierte');
    });

    test('fromName tolera variantes de naming', () {
      expect(PrinterHealthStatusX.fromName('low_paper'),
          PrinterHealthStatus.lowPaper);
      expect(PrinterHealthStatusX.fromName('lowpaper'),
          PrinterHealthStatus.lowPaper);
      expect(PrinterHealthStatusX.fromName('NO_PAPER'),
          PrinterHealthStatus.noPaper);
    });
  });

  group('MenuItemPrintArea', () {
    test('fromMap parsea fechas y campos correctamente', () {
      final m = MenuItemPrintArea.fromMap({
        'menu_item_id': 'mi-1',
        'print_area_id': 'pa-1',
        'created_at': '2026-05-21T12:00:00Z',
      });

      expect(m.menuItemId, 'mi-1');
      expect(m.printAreaId, 'pa-1');
      expect(m.createdAt.toUtc().hour, 12);
    });

    test('toMap es simétrico con fromMap', () {
      final original = MenuItemPrintArea(
        menuItemId: 'mi-1',
        printAreaId: 'pa-1',
        createdAt: DateTime.utc(2026, 5, 21, 12, 0, 0),
      );
      final roundtrip = MenuItemPrintArea.fromMap(original.toMap());
      expect(roundtrip, original);
    });
  });

  group('DevicePrinterBinding', () {
    test('fromMap respeta is_local_owner default true cuando ausente', () {
      final b = DevicePrinterBinding.fromMap({
        'device_id': 'dev-1',
        'printer_id': 'pr-1',
        'paired_at': '2026-05-21T12:00:00Z',
      });
      expect(b.isLocalOwner, isTrue);
    });

    test('fromMap respeta is_local_owner=false explícito', () {
      final b = DevicePrinterBinding.fromMap({
        'device_id': 'dev-1',
        'printer_id': 'pr-1',
        'is_local_owner': false,
        'paired_at': '2026-05-21T12:00:00Z',
      });
      expect(b.isLocalOwner, isFalse);
    });

    test('notes vacío se normaliza a null', () {
      final b = DevicePrinterBinding.fromMap({
        'device_id': 'd',
        'printer_id': 'p',
        'notes': '   ',
        'paired_at': '2026-05-21T12:00:00Z',
      });
      expect(b.notes, isNull);
    });

    test('copyWith preserva campos no especificados', () {
      final original = DevicePrinterBinding(
        deviceId: 'd',
        printerId: 'p',
        pairedAt: DateTime.utc(2026, 5, 21),
        notes: 'caja 1',
      );
      final mutated = original.copyWith(isLocalOwner: false);
      expect(mutated.notes, 'caja 1');
      expect(mutated.isLocalOwner, isFalse);
      expect(mutated.deviceId, 'd');
    });
  });

  group('PrinterHealthRecord', () {
    test('fromMap parsea status y consecutive_failures', () {
      final r = PrinterHealthRecord.fromMap({
        'printer_id': 'p-1',
        'status': 'no_paper',
        'consecutive_failures': 3,
        'last_checked_at': '2026-05-21T12:00:00Z',
        'updated_at': '2026-05-21T12:00:00Z',
        'details': {'error_code': 'ENO_PAPER'},
      });

      expect(r.printerId, 'p-1');
      expect(r.status, PrinterHealthStatus.noPaper);
      expect(r.consecutiveFailures, 3);
      expect(r.details['error_code'], 'ENO_PAPER');
    });

    test('toMap usa el wireName correcto del status', () {
      final r = PrinterHealthRecord(
        printerId: 'p',
        status: PrinterHealthStatus.coverOpen,
        lastCheckedAt: DateTime.utc(2026, 5, 21),
        updatedAt: DateTime.utc(2026, 5, 21),
      );
      expect(r.toMap()['status'], 'cover_open');
    });

    test('status desconocido cae a unknown', () {
      final r = PrinterHealthRecord.fromMap({
        'printer_id': 'p',
        'status': 'on_fire',
        'last_checked_at': '2026-05-21T12:00:00Z',
        'updated_at': '2026-05-21T12:00:00Z',
      });
      expect(r.status, PrinterHealthStatus.unknown);
    });
  });

  group('DeviceAgent', () {
    test('fromMap parsea campos legacy + v2', () {
      final a = DeviceAgent.fromMap({
        'id': 'd-1',
        'business_id': 'b-1',
        'device_name': 'Caja 1',
        'agent_url': 'http://192.168.1.10:4000',
        'platform': 'macos',
        'online': true,
        'last_heartbeat_at': '2026-05-21T12:00:00Z',
        'created_at': '2026-05-20T00:00:00Z',
        'updated_at': '2026-05-21T12:00:00Z',
        'agent_version': 'v2.0.0',
        'os': 'Darwin',
        'hostname': 'mac-caja-1',
        'available_transports': ['lan', 'usb'],
        'metadata': {'foo': 'bar'},
      });

      expect(a.id, 'd-1');
      expect(a.online, isTrue);
      expect(a.agentVersion, 'v2.0.0');
      expect(a.availableTransports, ['lan', 'usb']);
      expect(a.metadata['foo'], 'bar');
    });

    test('available_transports default array vacío', () {
      final a = DeviceAgent.fromMap({
        'id': 'd',
        'business_id': 'b',
        'created_at': '2026-05-21T00:00:00Z',
        'updated_at': '2026-05-21T00:00:00Z',
      });
      expect(a.availableTransports, isEmpty);
      expect(a.metadata, isEmpty);
    });

    test('isHeartbeatFresh detecta heartbeat reciente', () {
      final fresh = DeviceAgent(
        id: 'd',
        businessId: 'b',
        lastHeartbeatAt: DateTime.now().toUtc(),
        createdAt: DateTime.utc(2026, 5, 20),
        updatedAt: DateTime.utc(2026, 5, 21),
      );
      expect(fresh.isHeartbeatFresh, isTrue);

      final stale = DeviceAgent(
        id: 'd',
        businessId: 'b',
        lastHeartbeatAt:
            DateTime.now().toUtc().subtract(const Duration(minutes: 5)),
        createdAt: DateTime.utc(2026, 5, 20),
        updatedAt: DateTime.utc(2026, 5, 21),
      );
      expect(stale.isHeartbeatFresh, isFalse);

      final never = DeviceAgent(
        id: 'd',
        businessId: 'b',
        createdAt: DateTime.utc(2026, 5, 20),
        updatedAt: DateTime.utc(2026, 5, 21),
      );
      expect(never.isHeartbeatFresh, isFalse);
    });
  });
}
