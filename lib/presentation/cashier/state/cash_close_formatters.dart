import 'package:intl/intl.dart';

import '../../../core/utils/app_time.dart';

final NumberFormat _moneyNoDecimals = NumberFormat('#,##0', 'en_US');
final NumberFormat _moneyWithDecimals = NumberFormat('#,##0.00', 'en_US');
final DateFormat _dateFormat = DateFormat('dd/MM/yyyy', 'es_DO');
final DateFormat _timeFormat = DateFormat('HH:mm', 'es_DO');

/// Formatea un monto en pesos dominicanos. DOP no circula con centavos
/// (no hay billetes ni monedas fraccionarias), así que se redondea siempre
/// al peso entero más cercano.
String formatRD(num amount) {
  return 'RD\$ ${_moneyNoDecimals.format(amount.round())}';
}

/// Formatea un monto digital (tarjetas, transferencias) que SÍ puede tener centavos.
String formatRDigital(num amount) {
  return 'RD\$ ${_moneyWithDecimals.format(amount)}';
}
String formatDateEsDo(DateTime dt) =>
    _dateFormat.format(AppTime.astFromInstant(dt));
String formatTimeEsDo(DateTime dt) =>
    _timeFormat.format(AppTime.astFromInstant(dt));
