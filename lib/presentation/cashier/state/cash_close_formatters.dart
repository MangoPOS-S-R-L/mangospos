import 'package:intl/intl.dart';

import '../../../core/utils/app_time.dart';

final NumberFormat _moneyNoDecimals = NumberFormat('#,##0', 'en_US');
final DateFormat _dateFormat = DateFormat('dd/MM/yyyy', 'es_DO');
final DateFormat _timeFormat = DateFormat('HH:mm', 'es_DO');

String formatRD(int amount) => 'RD\$ ${_moneyNoDecimals.format(amount)}';
String formatDateEsDo(DateTime dt) =>
    _dateFormat.format(AppTime.astFromInstant(dt));
String formatTimeEsDo(DateTime dt) =>
    _timeFormat.format(AppTime.astFromInstant(dt));
