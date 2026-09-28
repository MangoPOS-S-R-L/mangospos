import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/offline/customers_offline_cache.dart';

/// Búsqueda local de clientes (sin internet): mismos campos que la del
/// servidor (`CustomersQueries.searchFields`).
void main() {
  final rows = <Map<String, dynamic>>[
    {'name': 'Juan Pérez', 'legal_name': null, 'phone': '809-555-1234'},
    {'name': 'Ferretería', 'legal_name': 'Ferre SRL', 'tax_id': '131245678'},
    {'name': 'Ana', 'email': 'ana@correo.com'},
  ];

  test('sin texto devuelve todos', () {
    expect(CustomersOfflineCache.filter(rows, '  '), hasLength(3));
  });

  test('busca sin distinguir mayúsculas en nombre y razón social', () {
    expect(CustomersOfflineCache.filter(rows, 'JUAN').single['name'],
        'Juan Pérez');
    expect(CustomersOfflineCache.filter(rows, 'srl').single['name'],
        'Ferretería');
  });

  test('busca por RNC, teléfono y correo', () {
    expect(CustomersOfflineCache.filter(rows, '1312').single['name'],
        'Ferretería');
    expect(CustomersOfflineCache.filter(rows, '555').single['name'],
        'Juan Pérez');
    expect(CustomersOfflineCache.filter(rows, '@correo').single['name'], 'Ana');
  });

  test('campos nulos no rompen la búsqueda', () {
    expect(CustomersOfflineCache.filter(rows, 'zzz'), isEmpty);
  });
}
