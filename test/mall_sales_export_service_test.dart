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
    const rows = [
      MallHourlySalesRow(
        hour: 10,
        txCount: 18,
        totalItems: 22,
        totalGross: 60885.60,
        totalTax: 10959.40,
        totalNet: 49926.20,
      ),
    ];
    final csv =
        MallSalesExportService.buildCsv(config: config, date: date, rows: rows);
    final lines = csv.trimRight().split('\r\n');
    expect(lines, hasLength(2));
    expect(lines.first, MallSalesExportService.csvHeader);
    expect(
      lines[1],
      '27031810,341,27/03/2018,10,18,22.000000,1,60885.60,10959.40,49926.20',
    );
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
