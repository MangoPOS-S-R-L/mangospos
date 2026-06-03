import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/utils/catalog_csv_parser.dart';

/// Tests del parser de catálogo (CSV + tabla de Excel). Lógica pura.
void main() {
  group('CatalogCsvParser.parse (CSV)', () {
    test('headers en español + coma decimal + miles', () {
      const csv = 'nombre,precio,costo,sku,barcode,categoria,impuesto\n'
          'Coca Cola,75.00,40,049000,049000,REFRESCOS,ITBIS 18%\n'
          'Arroz,"1.250,50",900,ARZ,,GRANOS,EXENTO';
      final r = CatalogCsvParser.parse(csv);
      expect(r.errors, isEmpty);
      expect(r.rows.length, 2);

      expect(r.rows[0].name, 'Coca Cola');
      expect(r.rows[0].price, 75.0);
      expect(r.rows[0].cost, 40);
      expect(r.rows[0].sku, '049000');
      expect(r.rows[0].category, 'REFRESCOS');
      expect(r.rows[0].tax, 'ITBIS 18%');

      // "1.250,50" → 1250.50 (punto = miles, coma = decimal).
      expect(r.rows[1].price, 1250.50);
      expect(r.rows[1].barcode, isNull);
    });

    test('delimitador ; autodetectado y headers en inglés', () {
      const csv = 'name;price;cost\n'
          'Water;15;6';
      final r = CatalogCsvParser.parse(csv);
      expect(r.rows.single.name, 'Water');
      expect(r.rows.single.price, 15);
      expect(r.rows.single.cost, 6);
    });

    test('comillas con comas internas', () {
      const csv = 'nombre,precio\n'
          '"Ron, 750ml",1200';
      final r = CatalogCsvParser.parse(csv);
      expect(r.rows.single.name, 'Ron, 750ml');
      expect(r.rows.single.price, 1200);
    });

    test('fila sin nombre / precio inválido → errores, no rompe', () {
      const csv = 'nombre,precio\n'
          ',100\n'
          'Sin precio,abc\n'
          'Bueno,50';
      final r = CatalogCsvParser.parse(csv);
      expect(r.rows.single.name, 'Bueno');
      expect(r.errors.length, 2);
    });

    test('falta columna obligatoria → error de header', () {
      const csv = 'nombre,costo\nX,10';
      final r = CatalogCsvParser.parse(csv);
      expect(r.rows, isEmpty);
      expect(r.errors.single.message, contains('precio'));
    });
  });

  group('CatalogCsvParser.fromRows (Excel)', () {
    test('mapea por header sin importar el orden de columnas', () {
      final table = <List<String?>>[
        ['Precio', 'Nombre', 'Impuesto'],
        ['200', 'Cerveza', 'EXENTO'],
      ];
      final r = CatalogCsvParser.fromRows(table);
      expect(r.rows.single.name, 'Cerveza');
      expect(r.rows.single.price, 200);
      expect(r.rows.single.tax, 'EXENTO');
    });

    test('ignora filas totalmente vacías', () {
      final table = <List<String?>>[
        ['nombre', 'precio'],
        [null, null],
        ['Item', '10'],
      ];
      final r = CatalogCsvParser.fromRows(table);
      expect(r.rows.length, 1);
    });
  });
}
