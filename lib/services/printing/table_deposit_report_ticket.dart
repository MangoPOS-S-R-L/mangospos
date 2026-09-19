import '../../core/currency/business_currency.dart';
import '../../core/utils/app_time.dart';
import '../../data/models/printing_models.dart';
import '../../data/models/table_deposit_report.dart';
import 'esc_pos_generator.dart';

/// Ticket del reporte de abonos de mesa para la impresora térmica (58/80mm).
///
/// Lo mismo que la pantalla, en papel: los saldos por mesa (a nombre de
/// quién, referencia, balance) y los abonos que entraron en el rango. Los
/// consumos no van uno por uno —una mesa con abono de temporada tiene uno por
/// factura y el ticket sería kilométrico—; salen sumados en el resumen, y el
/// detalle completo queda en el PDF.
class TableDepositReportTicket {
  const TableDepositReportTicket._();

  static PrintTicket generate({
    required TableDepositReport report,
    required String businessName,
    required DateTime from,
    required DateTime to,
    BusinessCurrency currency = BusinessCurrency.fallbackDop,
    int paperWidth = 80,
    DateTime? printedAt,
  }) {
    final gen = EscPosGenerator(paperWidth: paperWidth);
    final narrow = gen.paperWidth <= 58;
    String money(double v) => currency.formatAmount(v);

    gen.initialize();
    gen.lineFeed();
    gen.setTextSize(width: narrow ? 1 : 2, height: 2);
    gen.setBold(true);
    gen.textCenteredWrapped(businessName);
    gen.setBold(false);
    gen.setTextSize();
    gen.doubleSeparator();

    gen.setTextSize(height: 2);
    gen.setBold(true);
    gen.textCentered('REPORTE DE ABONOS');
    gen.setBold(false);
    gen.setTextSize();
    gen.textCentered('Rango: ${_rangeLabel(from, to)}');
    gen.textCentered(
      'Impreso: ${_dateTime(AppTime.astFromInstant(printedAt ?? DateTime.now()))}',
    );
    gen.separator();

    gen.textRow('Saldo vigente:', money(report.outstandingBalance));
    gen.textRow('Mesas con saldo:', '${report.accountsWithBalance}');
    // Etiquetas cortas bajo un subtítulo: "Consumido en el rango:" + un
    // monto de 6 cifras no cabe en las 32 columnas de 58mm y se trunca.
    gen.text('En el rango:');
    gen.textRow('  Abonado:', money(report.periodDeposited));
    gen.textRow('  Consumido:', money(report.periodConsumed));
    if (report.periodRefunded > 0.005) {
      gen.textRow('  Devuelto:', money(report.periodRefunded));
    }
    gen.doubleSeparator();

    gen.setBold(true);
    gen.text('SALDOS POR MESA');
    gen.setBold(false);
    gen.separator();
    if (report.accounts.isEmpty) {
      gen.textWrapped('No hay mesas con saldo ni movimientos en el rango.');
      gen.separator();
    }
    for (final a in report.accounts) {
      gen.setBold(true);
      gen.textWrapped(
        a.zoneName == null
            ? a.tableLabel.toUpperCase()
            : '${a.tableLabel.toUpperCase()} - ${a.zoneName}',
      );
      gen.setBold(false);
      gen.textWrapped('A nombre de: ${a.holderName?.toUpperCase() ?? '-'}');
      if (a.references.isNotEmpty) gen.textWrapped('Ref: ${a.referenceLabel}');
      gen.textRow('Abonado:', money(a.deposited));
      gen.textRow('Consumido:', money(a.consumed));
      if (a.returned > 0.005) {
        gen.textRow('Devuelto/movido:', money(a.returned));
      }
      gen.setBold(true);
      gen.textRow('BALANCE:', money(a.balance));
      gen.setBold(false);
      gen.separator();
    }
    gen.setBold(true);
    gen.setTextSize(height: 2);
    gen.textRow('TOTAL BALANCE:', money(report.outstandingBalance));
    gen.setTextSize();
    gen.setBold(false);
    gen.doubleSeparator();

    final deposits = report.periodDeposits;
    gen.setBold(true);
    gen.text('ABONOS DEL RANGO');
    gen.setBold(false);
    gen.separator();
    if (deposits.isEmpty) {
      gen.text('Sin abonos en el rango.');
    }
    for (final m in deposits) {
      gen.textRow(_dateTime(m.createdAt), m.tableLabel);
      if (m.holderName != null) gen.textWrapped(m.holderName!.toUpperCase());
      final detail = [
        if (m.reference != null) 'Ref: ${m.reference}',
        if (m.methodName != null) m.methodName!,
      ].join(' - ');
      if (detail.isNotEmpty) gen.textWrapped(detail);
      gen.textRight(money(m.amount));
    }
    gen.separator();
    gen.setBold(true);
    gen.textRow(
      'Total abonado (${deposits.length}):',
      money(report.periodDeposited),
    );
    gen.setBold(false);

    gen.lineFeed(2);
    gen.cut();

    return PrintTicket(
      type: 'table_deposit_report',
      escPosCommands: gen.getCommands(),
      rawText: gen.getPlainText(),
    );
  }

  /// [to] es exclusivo (00:00 del día siguiente): se muestra el último día
  /// incluido, igual que el encabezado de Reportes.
  static String _rangeLabel(DateTime from, DateTime to) {
    final last = to.subtract(const Duration(days: 1));
    final a = _date(from);
    final b = _date(last);
    return a == b ? a : '$a - $b';
  }

  static String _date(DateTime d) =>
      '${_two(d.day)}/${_two(d.month)}/${d.year}';

  static String _dateTime(DateTime d) =>
      '${_date(d)} ${_two(d.hour)}:${_two(d.minute)}';

  static String _two(int v) => v.toString().padLeft(2, '0');
}
