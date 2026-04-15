import 'package:intl/intl.dart';

import '../../../core/utils/app_time.dart';

final NumberFormat _moneyNoDecimals = NumberFormat('#,##0', 'en_US');
final NumberFormat _moneyWithDecimals = NumberFormat('#,##0.00', 'en_US');
final DateFormat _dateFormat = DateFormat('dd/MM/yyyy', 'es_DO');
final DateFormat _timeFormat = DateFormat('HH:mm', 'es_DO');

String formatRD(num amount) {
  if (amount is int || amount == amount.roundToDouble()) {
    return 'RD\$ ${_moneyNoDecimals.format(amount)}';
  }
  return 'RD\$ ${_moneyWithDecimals.format(amount)}';
}
String formatDateEsDo(DateTime dt) =>
    _dateFormat.format(AppTime.astFromInstant(dt));
String formatTimeEsDo(DateTime dt) =>
    _timeFormat.format(AppTime.astFromInstant(dt));
