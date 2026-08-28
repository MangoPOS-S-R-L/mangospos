// Lo que decide si el archivo sirve o no es de qué TIPO llega cada celda:
// un costo que viaja como texto no se suma, y un código de barras que viaja
// como número pierde el cero de la izquierda. Acá se arma el .xlsx de
// verdad y se vuelve a abrir con el mismo paquete para verificarlo.

import 'package:excel/excel.dart' as xlsx;
import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/utils/export/report_exporter.dart';

void main() {
  group('ReportExporter.buildXlsxBytes', () {
    late xlsx.Sheet sheet;

    setUp(() {
      final bytes = ReportExporter.buildXlsxBytes(
        sheetName: 'Maestro',
        headers: const [
          'Código',
          'Nombre',
          'Código de barras',
          'Costo',
          'Existencia',
        ],
        rows: const [
          ['0012', 'Ron Barceló añejo', '0759123456789', '1234.50', '4500'],
          ['ART-2', 'Piña', '', '', '2.5'],
        ],
        moneyColumns: const [3],
        numericColumns: const [4],
      );
      expect(bytes, isNotNull);
      sheet = xlsx.Excel.decodeBytes(bytes!)['Maestro'];
    });

    xlsx.CellValue? cell(int col, int row) => sheet
        .cell(xlsx.CellIndex.indexByColumnRow(columnIndex: col, rowIndex: row))
        .value;

    test('el importe llega como número', () {
      expect(cell(3, 1), isA<xlsx.DoubleCellValue>());
      expect((cell(3, 1) as xlsx.DoubleCellValue).value, 1234.5);
    });

    test('la cantidad entera llega como entero y la fraccionaria como doble',
        () {
      expect(cell(4, 1), isA<xlsx.IntCellValue>());
      expect((cell(4, 1) as xlsx.IntCellValue).value, 4500);
      expect(cell(4, 2), isA<xlsx.DoubleCellValue>());
      expect((cell(4, 2) as xlsx.DoubleCellValue).value, 2.5);
    });

    test('código y código de barras siguen siendo texto, con su cero', () {
      expect(cell(0, 1), isA<xlsx.TextCellValue>());
      expect(cell(0, 1).toString(), '0012');
      expect(cell(2, 1), isA<xlsx.TextCellValue>());
      expect(cell(2, 1).toString(), '0759123456789');
    });

    test('la celda vacía de una columna numérica no se inventa un cero', () {
      final value = cell(3, 2);
      expect(value, isNot(isA<xlsx.DoubleCellValue>()));
      expect(value.toString(), '');
    });

    test('los acentos sobreviven al viaje', () {
      expect(cell(1, 2).toString(), 'Piña');
      expect(cell(1, 1).toString(), 'Ron Barceló añejo');
    });

    test('el encabezado se escribe en la primera fila', () {
      expect(cell(0, 0).toString(), 'Código');
      expect(cell(4, 0).toString(), 'Existencia');
    });
  });
}
