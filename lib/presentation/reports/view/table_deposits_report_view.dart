import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:mangopos/core/theme/app_breakpoints.dart';
import 'package:mangopos/core/theme/app_colors.dart';
import 'package:mangopos/core/theme/app_spacing.dart';
import 'package:mangopos/data/models/table_deposit_report.dart';
import 'package:mangopos/services/printing/table_deposit_report_ticket.dart';
import 'package:mangopos/presentation/reports/services/report_ticket_printing.dart';
import 'package:mangopos/presentation/reports/viewmodel/reports_viewmodel.dart';
import 'package:mangopos/presentation/reports/widgets/report_scaffold.dart';
import 'package:mangopos/presentation/reports/widgets/report_widgets.dart';

const Color _kDepositsAccent = Color(0xFF0D9488);

/// Reporte "Abonos": saldo prepagado por mesa. Arriba, cada mesa con su
/// abono vigente (a nombre de quién, referencia, abonado, consumido y
/// balance de HOY); abajo, los movimientos del rango. Se imprime en la
/// térmica del POS o sale en PDF/CSV desde la barra de Reportes.
/// Fuente: [TableDepositRepository.getReport].
class TableDepositsReportView extends StatelessWidget {
  const TableDepositsReportView({super.key});

  @override
  Widget build(BuildContext context) {
    return ReportScaffold(
      title: 'Abonos',
      category: ReportCategory.deposits,
      body: (state, viewModel) => _DepositsReportBody(state: state),
    );
  }
}

class _DepositsReportBody extends ConsumerStatefulWidget {
  const _DepositsReportBody({required this.state});

  final ReportsState state;

  @override
  ConsumerState<_DepositsReportBody> createState() =>
      _DepositsReportBodyState();
}

class _DepositsReportBodyState extends ConsumerState<_DepositsReportBody> {
  bool _printing = false;

  Future<void> _print(TableDepositReport report) async {
    if (_printing) return;
    setState(() => _printing = true);
    try {
      await ReportTicketPrinting.print(
        context,
        ref,
        title: 'Reporte de abonos',
        fileNamePrefix: 'reporte_abonos',
        kind: 'table_deposit_report',
        build:
            ({required businessName, required currency, required paperWidth}) =>
                TableDepositReportTicket.generate(
                  report: report,
                  businessName: businessName,
                  from: widget.state.salesFrom,
                  to: widget.state.salesTo,
                  currency: currency,
                  paperWidth: paperWidth,
                ),
      );
    } finally {
      if (mounted) setState(() => _printing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final currency = state.currency.formatter;
    final report = state.depositsReport ?? TableDepositReport.empty;

    return ListView(
      padding: reportBodyPadding(context),
      children: [
        ReportHeroCard(
          title: 'Abonos de mesa',
          subtitle:
              'Saldo prepagado por mesa: a nombre de quién está, su '
              'referencia y cuánto le queda. El balance es el de hoy; los '
              'movimientos son los del rango.',
          period: formatReportPeriod(state),
          accentColor: _kDepositsAccent,
          trailing: [
            ReportHeroStat(
              label: 'Saldo vigente',
              value: currency.format(report.outstandingBalance),
            ),
            ReportHeroStat(
              label: 'Mesas con saldo',
              value: '${report.accountsWithBalance}',
            ),
            ReportHeroStat(
              label: 'Abonado en el rango',
              value: currency.format(report.periodDeposited),
            ),
            ReportHeroStat(
              label: 'Consumido en el rango',
              value: currency.format(report.periodConsumed),
            ),
          ],
        ),
        if (state.error != null) ...[
          const SizedBox(height: AppSpacing.itemGap),
          Text(
            state.error!,
            style: const TextStyle(color: AppColors.destructive),
          ),
        ],
        const SizedBox(height: AppSpacing.itemGap),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.icon(
            onPressed: _printing || state.depositsReport == null
                ? null
                : () => _print(report),
            style: FilledButton.styleFrom(
              backgroundColor: _kDepositsAccent,
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(reportRadius),
              ),
            ),
            icon: _printing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.print_outlined, size: 18),
            label: const Text('Imprimir reporte'),
          ),
        ),
        if (report.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: AppSpacing.itemGap),
            child: ReportSurfaceCard(
              child: ReportEmptyPlaceholder(
                icon: Icons.account_balance_wallet_outlined,
                message:
                    'Ninguna mesa tiene saldo abonado y no hubo movimientos '
                    'de abonos en el rango seleccionado.',
              ),
            ),
          )
        else ...[
          const SizedBox(height: AppSpacing.itemGap),
          const ReportSectionLabel(
            title: 'Saldos por mesa',
            subtitle:
                'Mesas con saldo hoy o con movimiento en el rango. Abonado y '
                'consumido son del abono vigente de cada mesa.',
          ),
          const SizedBox(height: AppSpacing.itemGap),
          _AccountsTable(report: report, currency: currency),
          const SizedBox(height: AppSpacing.sectionGap),
          const ReportSectionLabel(
            title: 'Movimientos del rango',
            subtitle:
                'Abonos, consumos, anulaciones y devoluciones, con el balance '
                'con que quedó la mesa después de cada uno.',
          ),
          const SizedBox(height: AppSpacing.itemGap),
          _MovementsTable(movements: report.movements, currency: currency),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Saldos por mesa
// ---------------------------------------------------------------------------

class _AccountsTable extends StatelessWidget {
  const _AccountsTable({required this.report, required this.currency});

  final TableDepositReport report;
  final NumberFormat currency;

  @override
  Widget build(BuildContext context) {
    final accounts = report.accounts;
    final isMobile = ResponsiveHelper.isMobile(context);

    if (isMobile) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final a in accounts)
            ReportRecordCard(
              title: a.zoneName == null
                  ? a.tableLabel
                  : '${a.tableLabel} · ${a.zoneName}',
              fields: [
                ReportRecordField('A nombre de', a.holderName ?? '—'),
                ReportRecordField(
                  'Referencia',
                  a.references.isEmpty ? '—' : a.referenceLabel,
                ),
                ReportRecordField('Abonado', currency.format(a.deposited)),
                ReportRecordField('Consumido', currency.format(a.consumed)),
                if (a.returned > 0.005)
                  ReportRecordField(
                    'Devuelto / movido',
                    currency.format(a.returned),
                  ),
                ReportRecordField(
                  'Balance',
                  currency.format(a.balance),
                  emphasize: true,
                  valueColor: a.hasBalance ? _kDepositsAccent : null,
                ),
              ],
            ),
          ReportRecordCard(
            title: 'Total',
            highlight: true,
            fields: [
              ReportRecordField(
                'Mesas con saldo',
                '${report.accountsWithBalance}',
              ),
              ReportRecordField(
                'Saldo vigente',
                currency.format(report.outstandingBalance),
                emphasize: true,
              ),
            ],
          ),
        ],
      );
    }

    final dateFormat = DateFormat('dd/MM/yyyy HH:mm');
    return ReportSurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                _headerCell('Mesa', flex: 3),
                _headerCell('A nombre de', flex: 4),
                _headerCell('Referencia', flex: 3),
                _headerCell('Abonado', flex: 2, end: true),
                _headerCell('Consumido', flex: 2, end: true),
                _headerCell('Balance', flex: 2, end: true),
              ],
            ),
          ),
          Divider(height: 1, color: AppColors.border.withValues(alpha: 0.6)),
          for (var i = 0; i < accounts.length; i++) ...[
            if (i > 0)
              Divider(
                height: 1,
                color: AppColors.border.withValues(alpha: 0.4),
              ),
            _accountRow(accounts[i], dateFormat),
          ],
          Divider(height: 1, color: AppColors.border.withValues(alpha: 0.6)),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(
              children: [
                Expanded(
                  flex: 14,
                  child: Text(
                    'Saldo vigente (${report.accountsWithBalance} '
                    '${report.accountsWithBalance == 1 ? 'mesa' : 'mesas'} '
                    'con saldo)',
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 13,
                      color: AppColors.foreground,
                    ),
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Text(
                    currency.format(report.outstandingBalance),
                    textAlign: TextAlign.end,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 13.5,
                      color: _kDepositsAccent,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _accountRow(TableDepositReportAccount a, DateFormat dateFormat) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  a.tableLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 12.5,
                    color: AppColors.foreground,
                  ),
                ),
                if (a.zoneName != null)
                  Text(
                    a.zoneName!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: AppColors.mutedForeground,
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            flex: 4,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  a.holderName ?? 'Sin nombre',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 12.5,
                    color: a.holderName == null
                        ? AppColors.mutedForeground
                        : AppColors.foreground,
                  ),
                ),
                if (a.openedAt != null)
                  Text(
                    'Desde ${dateFormat.format(a.openedAt!)}',
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: AppColors.mutedForeground,
                    ),
                  ),
              ],
            ),
          ),
          _textCell(
            a.references.isEmpty ? '—' : a.referenceLabel,
            flex: 3,
            muted: a.references.isEmpty,
          ),
          _textCell(currency.format(a.deposited), flex: 2, end: true),
          _textCell(currency.format(a.consumed), flex: 2, end: true),
          Expanded(
            flex: 2,
            child: Text(
              currency.format(a.balance),
              textAlign: TextAlign.end,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 13,
                color: a.hasBalance
                    ? _kDepositsAccent
                    : AppColors.mutedForeground,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Movimientos del rango
// ---------------------------------------------------------------------------

class _MovementsTable extends StatelessWidget {
  const _MovementsTable({required this.movements, required this.currency});

  final List<TableDepositReportMovement> movements;
  final NumberFormat currency;

  static Color _tone(String type) => switch (type) {
    'deposit' || 'transfer_in' => const Color(0xFF16A34A),
    'consumption' => AppColors.primary,
    'reversal' => AppColors.info,
    'refund' => AppColors.destructive,
    _ => AppColors.mutedForeground,
  };

  String _signed(double amount) =>
      '${amount > 0 ? '+' : '−'}${currency.format(amount.abs())}';

  @override
  Widget build(BuildContext context) {
    if (movements.isEmpty) {
      return const ReportSurfaceCard(
        child: ReportEmptyPlaceholder(
          icon: Icons.receipt_long_outlined,
          message: 'Sin movimientos de abonos en el rango seleccionado.',
        ),
      );
    }

    final isMobile = ResponsiveHelper.isMobile(context);
    final dateFormat = DateFormat(
      isMobile ? 'dd/MM HH:mm' : 'dd/MM/yyyy HH:mm',
    );

    if (isMobile) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final m in movements)
            ReportRecordCard(
              title: '${m.typeLabel} · ${m.tableLabel}',
              leadingDot: _tone(m.type),
              fields: [
                ReportRecordField('Fecha', dateFormat.format(m.createdAt)),
                ReportRecordField('A nombre de', m.holderName ?? '—'),
                if (m.reference != null)
                  ReportRecordField('Referencia', m.reference!),
                if (m.note != null) ReportRecordField('Nota', m.note!),
                if (m.methodName != null)
                  ReportRecordField('Método', m.methodName!),
                if (m.createdByName != null)
                  ReportRecordField('Registrado por', m.createdByName!),
                ReportRecordField(
                  'Monto',
                  _signed(m.amount),
                  emphasize: true,
                  valueColor: _tone(m.type),
                ),
                ReportRecordField('Balance', currency.format(m.balanceAfter)),
              ],
            ),
        ],
      );
    }

    return ReportSurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                _headerCell('Fecha', flex: 3),
                _headerCell('Mesa', flex: 2),
                _headerCell('A nombre de', flex: 3),
                _headerCell('Tipo', flex: 3),
                _headerCell('Referencia / nota', flex: 3),
                _headerCell('Monto', flex: 2, end: true),
                _headerCell('Balance', flex: 2, end: true),
              ],
            ),
          ),
          Divider(height: 1, color: AppColors.border.withValues(alpha: 0.6)),
          for (var i = 0; i < movements.length; i++) ...[
            if (i > 0)
              Divider(
                height: 1,
                color: AppColors.border.withValues(alpha: 0.4),
              ),
            _movementRow(movements[i], dateFormat),
          ],
        ],
      ),
    );
  }

  Widget _movementRow(TableDepositReportMovement m, DateFormat dateFormat) {
    final tone = _tone(m.type);
    final detail = m.reference ?? m.note;
    final byLine = [
      if (m.methodName != null) m.methodName!,
      if (m.createdByName != null) m.createdByName!,
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _textCell(dateFormat.format(m.createdAt), flex: 3, muted: true),
          _textCell(m.tableLabel, flex: 2, bold: true),
          _textCell(m.holderName ?? '—', flex: 3, muted: m.holderName == null),
          Expanded(
            flex: 3,
            child: Align(
              alignment: Alignment.centerLeft,
              child: ReportStatusTag(label: m.typeLabel, tone: tone),
            ),
          ),
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  detail ?? '—',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                    color: detail == null
                        ? AppColors.mutedForeground
                        : AppColors.foreground,
                  ),
                ),
                if (byLine.isNotEmpty)
                  Text(
                    byLine,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: AppColors.mutedForeground,
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              _signed(m.amount),
              textAlign: TextAlign.end,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 12.5,
                color: tone,
              ),
            ),
          ),
          _textCell(currency.format(m.balanceAfter), flex: 2, end: true),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Celdas (mismo estilo que el reporte de Delivery)
// ---------------------------------------------------------------------------

Widget _headerCell(String label, {required int flex, bool end = false}) {
  return Expanded(
    flex: flex,
    child: Text(
      label,
      textAlign: end ? TextAlign.end : TextAlign.start,
      style: const TextStyle(
        fontWeight: FontWeight.w700,
        fontSize: 12.5,
        color: AppColors.mutedForeground,
      ),
    ),
  );
}

Widget _textCell(
  String value, {
  required int flex,
  bool end = false,
  bool bold = false,
  bool muted = false,
}) {
  return Expanded(
    flex: flex,
    child: Text(
      value,
      textAlign: end ? TextAlign.end : TextAlign.start,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
        fontSize: 12.5,
        color: muted ? AppColors.mutedForeground : AppColors.foreground,
      ),
    ),
  );
}
