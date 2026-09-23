import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/offline/offline_readiness.dart';

void main() {
  late Map<String, Object?> saved;
  late OfflineReadinessInspector inspector;
  setUp(() {
    saved = {
      'offline_catalog_biz': {
        'products': [
          {'id': 'p1', 'name': 'Café', 'price': 75, 'print_area_code': 'bar'},
        ],
      },
      'offline_business_taxes_biz': {'rows': []},
      'offline_item_options_biz': {
        'modifier_items': {'p1': []},
        'groups': {},
      },
      'offline_business_settings_biz': {'row': {}},
      'offline_zones_snapshot_biz': {
        'zones': [
          {'id': 'z1', 'name': 'Terraza'},
        ],
      },
      'offline_zone_tables_snapshot_z1': {'rows': []},
      'printing_cached_printers_biz_bar': [
        {
          'id': 'printer1',
          'business_id': 'biz',
          'type': 'network',
          'ip_address': '192.168.1.50',
          'is_active': true,
        },
      ],
    };
    inspector = OfflineReadinessInspector(
      read: (key) async =>
          saved.containsKey(key) ? jsonEncode(saved[key]) : null,
      checkAccess: (_) async =>
          const OfflineReadinessCheck('Acceso con PIN', true, 'Disponible'),
    );
  });

  test(
    'verifica datos guardados; impuestos y mesas vacíos son válidos',
    () async {
      final result = await inspector.inspect('biz');
      expect(result.ready, true);
      expect(result.checks, hasLength(7));
    },
  );

  test('no confunde ausencia de impuestos con negocio sin impuestos', () async {
    saved.remove('offline_business_taxes_biz');
    expect((await inspector.inspect('biz')).ready, false);
    saved['offline_business_taxes_biz'] = {'rows': []};
    expect((await inspector.inspect('biz')).ready, true);
  });

  test('leer otro negocio nunca reutiliza los datos del anterior', () async {
    expect((await inspector.inspect('other')).ready, false);
    expect((await inspector.inspect('biz')).ready, true);
  });

  test(
    'detecta catálogo corrupto y vuelve a leer después de borrarlo',
    () async {
      saved['offline_catalog_biz'] = {
        'products': ['dato inválido'],
      };
      expect((await inspector.inspect('biz')).ready, false);
      saved.remove('offline_catalog_biz');
      expect((await inspector.inspect('biz')).ready, false);
    },
  );

  test('opciones parciales no preparan todos los productos', () async {
    saved['offline_item_options_biz'] = {'modifier_items': {}, 'groups': {}};
    final checks = (await inspector.inspect('biz')).checks;
    expect(
      checks.firstWhere((c) => c.label == 'Modificadores y combos').ready,
      false,
    );
  });

  test('los combos necesitan sus propias opciones descargadas', () async {
    final product =
        ((saved['offline_catalog_biz'] as Map)['products'] as List).single
            as Map;
    product['item_type'] = 'combo';
    expect((await inspector.inspect('biz')).ready, false);
    (saved['offline_item_options_biz'] as Map)['combo_items'] = {'p1': []};
    expect((await inspector.inspect('biz')).ready, true);
  });

  test(
    'verifica cada zona, aunque la lista de zonas sí esté guardada',
    () async {
      saved.remove('offline_zone_tables_snapshot_z1');
      final result = await inspector.inspect('biz');
      expect(result.ready, false);
      expect(
        result.checks.firstWhere((c) => c.label == 'Zonas y mesas').detail,
        contains('Terraza'),
      );
    },
  );

  test('un producto en cocina y bar requiere ambas asignaciones', () async {
    final product =
        ((saved['offline_catalog_biz'] as Map)['products'] as List).single
            as Map;
    product['menu_item_print_areas'] = [
      {
        'print_areas': {'code': 'bar', 'is_active': true},
      },
      {
        'print_areas': {'code': 'kitchen_hot', 'is_active': true},
      },
    ];
    final result = await inspector.inspect('biz');
    expect(result.ready, false);
    expect(
      result.checks.firstWhere((c) => c.label == 'Rutas de cocina').detail,
      contains('kitchen_hot'),
    );
  });

  test('impresora sin IP o de otro negocio no cuenta como preparada', () async {
    final printer =
        (saved['printing_cached_printers_biz_bar'] as List).single as Map;
    printer.remove('ip_address');
    expect((await inspector.inspect('biz')).ready, false);
    printer['ip_address'] = '192.168.1.50';
    printer['business_id'] = 'other';
    expect((await inspector.inspect('biz')).ready, false);
  });

  test('cocina sin impresión no requiere impresoras asignadas', () async {
    saved.remove('printing_cached_printers_biz_bar');
    saved['offline_business_settings_biz'] = {
      'row': {'printerless_kitchen': true},
    };
    expect((await inspector.inspect('biz')).ready, true);
  });

  test('fallo de almacenamiento o acceso nunca anuncia listo', () async {
    final broken = OfflineReadinessInspector(
      read: (_) async => throw StateError('disk'),
      checkAccess: (_) async => throw StateError('keychain'),
    );
    expect((await broken.inspect('biz')).ready, false);
  });
}
