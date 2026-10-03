import 'package:intl/intl.dart';

import '../../../core/utils/app_time.dart';
import 'blind_cash_close_models.dart';

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
/// "US$ 280.00 a RD$ 50.00 = RD$ 14,000" — los dólares de la gaveta con la
/// tasa usada. Mismo texto en "Revisar y firmar" y en la confirmación.
String usdBreakdownLabel(UsdCashCount usd) =>
    '${usd.symbol} ${_moneyWithDecimals.format(usd.totalUsd)} a '
    '${formatRDigital(usd.rate.toDouble())} = ${formatRD(usd.totalDop)}';

String formatDateEsDo(DateTime dt) =>
    _dateFormat.format(AppTime.astFromInstant(dt));
String formatTimeEsDo(DateTime dt) =>
    _timeFormat.format(AppTime.astFromInstant(dt));
