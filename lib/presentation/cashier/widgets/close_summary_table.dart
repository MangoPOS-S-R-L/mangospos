import 'package:flutter/material.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/presentation/cashier/state/blind_cash_close_models.dart';
import 'package:mangopos/presentation/cashier/state/cash_close_formatters.dart';

class CloseSummaryTable extends StatelessWidget {
  final CashCloseInput input;
  final CashCloseResult result;

  const CloseSummaryTable({
    super.key,
    required this.input,
    required this.result,
  });

  @override
  Widget build(BuildContext context) {
    final rows = <_SummaryRowData>[
      _SummaryRowData(
        concept: 'Efectivo',
        expected: input.expectedCash,
        reported: result.totalCounted,
      ),
      _SummaryRowData(
        concept: 'Tarjetas',
        expected: input.expectedCard,
        reported: result.numericCard,
      ),
      _SummaryRowData(
        concept: 'Transferencias',
        expected: input.expectedTransfer,
        reported: result.numericTransfer,
      ),
      _SummaryRowData(
        concept: 'CIERRE CAJA',
        expected: input.expectedClosureAmount,
        reported: result.totalCounted,
      ),
      _SummaryRowData(
        concept: 'TOTAL GENERAL',
        expected: input.expectedTotal,
        reported: result.totalReported,
      ),
    ];

    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: Table(
        border: TableBorder.all(color: MangoColors.cardBorder),
        columnWidths: const {
          0: FlexColumnWidth(2.2),
          1: FlexColumnWidth(1.6),
          2: FlexColumnWidth(1.6),
          3: FlexColumnWidth(1.6),
        },
        children: [
          const TableRow(
            decoration: BoxDecoration(color: MangoColors.bgLight),
            children: [
              _HeaderCell('Concepto'),
              _HeaderCell('Esperado'),
              _HeaderCell('Reportado'),
              _HeaderCell('Diferencia'),
            ],
          ),
          ...rows.map((row) {
            final diff = row.reported - row.expected;
            return TableRow(
              decoration: const BoxDecoration(color: Colors.white),
              children: [
                _BodyCell(row.concept, isBold: row.concept == 'TOTAL GENERAL'),
                _BodyCell(formatRD(row.expected), alignEnd: true),
                _BodyCell(formatRD(row.reported), alignEnd: true),
                _BodyCell(
                  '${diff >= 0 ? '+' : '-'} ${formatRD(diff.abs())}',
                  alignEnd: true,
                  color: diff == 0
                      ? MangoColors.successGreen
                      : (diff > 0 ? MangoColors.successGreen : Colors.red),
                  isBold: true,
                ),
              ],
            );
          }),
        ],
      ),
    );
  }
}

class _SummaryRowData {
  final String concept;
  final int expected;
  final int reported;

  const _SummaryRowData({
    required this.concept,
    required this.expected,
    required this.reported,
  });
}

class _HeaderCell extends StatelessWidget {
  final String text;

  const _HeaderCell(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      child: Text(
        text,
        style: const TextStyle(fontWeight: FontWeight.w700),
        textAlign: TextAlign.center,
      ),
    );
  }
}

class _BodyCell extends StatelessWidget {
  final String text;
  final bool alignEnd;
  final Color? color;
  final bool isBold;

  const _BodyCell(
    this.text, {
    this.alignEnd = false,
    this.color,
    this.isBold = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      child: Text(
        text,
        textAlign: alignEnd ? TextAlign.end : TextAlign.start,
        style: TextStyle(
          color: color ?? MangoColors.darkGray,
          fontWeight: isBold ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
    );
  }
}
