import 'package:intl/intl.dart';

final NumberFormat _moneyNoDecimals = NumberFormat('#,##0', 'en_US');
final DateFormat _dateFormat = DateFormat('dd/MM/yyyy', 'es_DO');
final DateFormat _timeFormat = DateFormat('HH:mm', 'es_DO');

String formatRD(int amount) => 'RD\$ ${_moneyNoDecimals.format(amount)}';
String formatDateEsDo(DateTime dt) => _dateFormat.format(dt);
String formatTimeEsDo(DateTime dt) => _timeFormat.format(dt);
