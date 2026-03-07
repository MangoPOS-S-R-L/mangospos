import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:mangopos/presentation/cashier/state/cash_close_formatters.dart';

void main() {
  setUpAll(() async {
    await initializeDateFormatting('es_DO');
  });

  test('formatea moneda RD\$ sin decimales', () {
    expect(formatRD(28500), 'RD\$ 28,500');
    expect(formatRD(0), 'RD\$ 0');
  });

  test('formatea fecha y hora en es_DO', () {
    final dt = DateTime(2026, 2, 27, 14, 35);
    expect(formatDateEsDo(dt), '27/02/2026');
    expect(formatTimeEsDo(dt), '14:35');
  });
}
