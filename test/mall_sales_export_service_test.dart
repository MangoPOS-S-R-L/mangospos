import 'package:flutter_test/flutter_test.dart';

import 'package:mangopos/core/services/mall_sales_export_service.dart';
import 'package:mangopos/data/repositories/mall_sales_export_repository.dart';

void main() {
  const config = MallSalesExportConfig(
    businessId: 'b1',
    enabled: true,
    host: 'agorasantiagocenter.serveftp.net',
    username: 'lacocinamx',
    password: 'x',
    clientCode: '341',
    filePrefix: 'Ventas_4_8',
    exchangeRate: 1.0,
  );

  final date = DateTime(2018, 3, 27);

  test('buildFileName sigue el patrón del manual (prefijo_ddMMyyyy.txt)', () {
    expect(
      MallSalesExportService.buildFileName(config, date),
      'Ventas_4_8_27032018.txt',
    );
  });

  test('buildCsv emite cabecera exacta y filas por hora', () {
    // Fixture calcado de la fila de ejemplo del manual de la plaza:
    //   270318,341,27/03/2018,10:23,18,22.000000,1,60885.60,10959.40
    // Ahí 10 959.40 es exactamente el 18% de 60 885.60, así que ese primer
    // monto es la BASE, no el cobrado. La plaza lo confirmó el 2026-08-13:
    // TOTALNETO = TOTALBRUTO + TOTALIMPUESTOS.
    //
    // En la nomenclatura interna es al revés: `totalGross` es lo que pagó el
    // cliente y `totalNet` la base. De ahí el mapeo cruzado que valida el
    // expect de abajo.
    const rows = [
      MallHourlySalesRow(
        hour: 10,
        txCount: 18,
        totalItems: 22,
        totalGross: 71845.00, // cobrado → va en TOTALNETO
        totalTax: 10959.40,
        totalNet: 60885.60, // base → va en TOTALBRUTO
      ),
    ];
    final csv =
        MallSalesExportService.buildCsv(config: config, date: date, rows: rows);
    final lines = csv.trimRight().split('\r\n');
    expect(lines, hasLength(2));
    expect(lines.first, MallSalesExportService.csvHeader);
    expect(
      lines[1],
      '27031810,341,27/03/2018,10,18,22.000000,1,60885.60,10959.40,71845.00',
    );
  });

  test('TOTALNETO es la suma de TOTALBRUTO y TOTALIMPUESTOS', () {
    const rows = [
      MallHourlySalesRow(
        hour: 20,
        txCount: 29,
        totalItems: 92,
        totalGross: 44450.00,
        totalTax: 9518.65,
        totalNet: 34931.35,
      ),
    ];
    final csv =
        MallSalesExportService.buildCsv(config: config, date: date, rows: rows);
    final campos = csv.trimRight().split('\r\n')[1].split(',');
    final bruto = double.parse(campos[7]);
    final impuestos = double.parse(campos[8]);
    final neto = double.parse(campos[9]);

    expect(bruto, 34931.35);
    expect(impuestos, 9518.65);
    expect(neto, 44450.00);
    expect((bruto + impuestos - neto).abs() < 0.005, isTrue);
  });

  test('buildCsv sin ventas produce solo la cabecera', () {
    final csv = MallSalesExportService.buildCsv(
      config: config,
      date: date,
      rows: const [],
    );
    expect(csv, '${MallSalesExportService.csvHeader}\r\n');
  });
}
