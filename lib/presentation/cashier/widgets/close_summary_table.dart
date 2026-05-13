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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _BreakdownCard(input: input),
        if (input.movements.isNotEmpty) ...[
          const SizedBox(height: 14),
          _MovementsListCard(movements: input.movements),
        ],
        const SizedBox(height: 14),
        _buildExpectedVsReported(),
      ],
    );
  }

  Widget _buildExpectedVsReported() {
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
        isDigital: true,
      ),
      _SummaryRowData(
        concept: 'Transferencias',
        expected: input.expectedTransfer,
        reported: result.numericTransfer,
        isDigital: true,
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
        isDigital: true,
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
                _BodyCell(row.isDigital ? formatRDigital(row.expected) : formatRD(row.expected), alignEnd: true),
                _BodyCell(row.isDigital ? formatRDigital(row.reported) : formatRD(row.reported), alignEnd: true),
                _BodyCell(
                  '${diff >= 0 ? '+' : '-'} ${row.isDigital ? formatRDigital(diff.abs()) : formatRD(diff.abs())}',
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

/// Sprint Caja Pro — Desglose Toast-style de cómo se calculó el
/// efectivo esperado. Aparece arriba de la tabla de comparación
/// expected vs reported.
class _BreakdownCard extends StatelessWidget {
  final CashCloseInput input;
  const _BreakdownCard({required this.input});

  @override
  Widget build(BuildContext context) {
    final apertura = input.startAmount;
    final ventas = input.cashSalesNet;
    final depositos = input.totalDeposits;
    final retiros = input.totalWithdrawals;
    final gastos = input.totalExpenses;
    final esperado = input.expectedCash;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFFFFF7ED), Color(0xFFFFEDD5)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFFED7AA)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Cómo se calcula el efectivo esperado',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w800,
              color: Color(0xFF9A3412),
            ),
          ),
          const SizedBox(height: 10),
          _BreakdownRow(label: 'Apertura',          amount: apertura,  isOut: false),
          _BreakdownRow(label: 'Ventas en efectivo', amount: ventas,    isOut: false),
          _BreakdownRow(label: 'Depósitos',          amount: depositos, isOut: false),
          _BreakdownRow(label: 'Retiros',            amount: retiros,   isOut: true),
          _BreakdownRow(label: 'Gastos',             amount: gastos,    isOut: true),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 6),
            child: Divider(height: 1, color: Color(0xFFFED7AA)),
          ),
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Esperado en caja',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w900,
                    color: Color(0xFF7C2D12),
                  ),
                ),
              ),
              Text(
                formatRD(esperado),
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                  color: MangoColors.primaryOrange,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _BreakdownRow extends StatelessWidget {
  final String label;
  final num amount;
  final bool isOut;
  const _BreakdownRow({
    required this.label,
    required this.amount,
    required this.isOut,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 18,
            child: Text(
              isOut ? '−' : '+',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w900,
                color: isOut ? const Color(0xFFEF4444) : MangoColors.successGreen,
              ),
            ),
          ),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 13,
                color: Color(0xFF7C2D12),
              ),
            ),
          ),
          Text(
            formatRD(amount),
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: isOut ? const Color(0xFFEF4444) : const Color(0xFF7C2D12),
            ),
          ),
        ],
      ),
    );
  }
}

/// Sprint Caja Pro — Listado detallado de movimientos manuales del
/// turno (depósitos, retiros, gastos) con razón y monto. Se renderiza
/// debajo del breakdown card en la hoja de cierre.
class _MovementsListCard extends StatelessWidget {
  final List<CashMovementEntry> movements;
  const _MovementsListCard({required this.movements});

  @override
  Widget build(BuildContext context) {
    final deposits = movements.where((m) => m.type == 'deposit').toList();
    final withdrawals = movements.where((m) => m.type == 'withdrawal').toList();
    final expenses = movements.where((m) => m.type == 'expense').toList();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: MangoColors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Movimientos manuales del turno',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w800,
              color: MangoColors.darkGray,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Cada depósito, retiro o gasto registrado durante este turno.',
            style: TextStyle(fontSize: 11, color: MangoColors.muted),
          ),
          const SizedBox(height: 12),
          if (deposits.isNotEmpty)
            _MovementsGroup(
              title: 'Depósitos',
              entries: deposits,
              accent: MangoColors.successGreen,
              sign: '+',
            ),
          if (withdrawals.isNotEmpty) ...[
            if (deposits.isNotEmpty) const SizedBox(height: 12),
            _MovementsGroup(
              title: 'Retiros',
              entries: withdrawals,
              accent: const Color(0xFFEF4444),
              sign: '−',
            ),
          ],
          if (expenses.isNotEmpty) ...[
            if (deposits.isNotEmpty || withdrawals.isNotEmpty)
              const SizedBox(height: 12),
            _MovementsGroup(
              title: 'Gastos',
              entries: expenses,
              accent: const Color(0xFFEF4444),
              sign: '−',
            ),
          ],
        ],
      ),
    );
  }
}

class _MovementsGroup extends StatelessWidget {
  final String title;
  final List<CashMovementEntry> entries;
  final Color accent;
  final String sign;
  const _MovementsGroup({
    required this.title,
    required this.entries,
    required this.accent,
    required this.sign,
  });

  String _fmt(double v) {
    final whole = v.truncate();
    final decimals = ((v - whole) * 100).round().toString().padLeft(2, '0');
    final wholeStr = whole.toString().replaceAllMapped(
          RegExp(r'(\d)(?=(\d{3})+(?!\d))'),
          (m) => '${m[1]},',
        );
    return 'RD\$ $wholeStr.$decimals';
  }

  String _hhmm(DateTime dt) {
    final local = dt.toLocal();
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  @override
  Widget build(BuildContext context) {
    final total = entries.fold<double>(0, (sum, m) => sum + m.amount);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: accent,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                title,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                ),
              ),
            ),
            const Spacer(),
            Text(
              '$sign ${_fmt(total)}',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: accent,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ...entries.map(
          (m) => Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              children: [
                SizedBox(
                  width: 44,
                  child: Text(
                    _hhmm(m.createdAt),
                    style: const TextStyle(
                      fontSize: 11,
                      color: MangoColors.muted,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    m.reasonLabel?.trim().isNotEmpty == true
                        ? m.reasonLabel!.trim()
                        : '—',
                    style: const TextStyle(
                      fontSize: 12,
                      color: MangoColors.darkGray,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  _fmt(m.amount),
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: MangoColors.darkGray,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _SummaryRowData {
  final String concept;
  final num expected;
  final num reported;
  final bool isDigital;

  const _SummaryRowData({
    required this.concept,
    required this.expected,
    required this.reported,
    this.isDigital = false,
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
