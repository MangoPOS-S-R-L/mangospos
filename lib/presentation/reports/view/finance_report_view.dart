import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/core/theme/app_breakpoints.dart';
import 'package:mangopos/core/theme/app_colors.dart';
import 'package:mangopos/core/theme/app_spacing.dart';
import 'package:mangopos/core/utils/app_time.dart';
import 'package:mangopos/core/utils/app_toast.dart';
import 'package:mangopos/presentation/cashier/services/print_service.dart';
import 'package:mangopos/presentation/reports/viewmodel/reports_viewmodel.dart';
import 'package:mangopos/presentation/reports/widgets/report_scaffold.dart';
import 'package:mangopos/presentation/reports/widgets/report_widgets.dart';
import 'package:mangopos/presentation/printing/widgets/ticket_preview_dialog.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class FinanceReportView extends StatelessWidget {
  const FinanceReportView({super.key});

  @override
  Widget build(BuildContext context) {
    return ReportScaffold(
      title: 'Cierres de caja',
      category: ReportCategory.finances,
      body: (state, viewModel) =>
          _FinanceReportBody(state: state, viewModel: viewModel),
    );
  }
}

class _FinanceReportBody extends StatelessWidget {
  const _FinanceReportBody({required this.state, required this.viewModel});

  final ReportsState state;
  final ReportsViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final currency = state.currency.formatter;
    final cachedAt = viewModel.financesDataCachedAt;
    final metrics = viewModel.getFinanceMetricCards();
    final typeRows = viewModel.getFinanceTypeRows();
    final sessionRows = viewModel.getFinanceSessionRows();
    final closures = viewModel.getCashClosureDetails();
    final balancedClosures =
        closures.where((row) => row['is_balanced'] == true).length;
    final reviewedClosures =
        closures.where((row) => row['status']?.toString() == 'closed').length;
    // El "Detalle de cierre y cuadre" es solo para sesiones CERRADAS: una
    // sesión abierta aún no tiene reportado → saldría "Reportado: 0" con un
    // cuadre engañoso. Las abiertas se cuentan en el resumen, no en el detalle.
    final closedDetails = closures
        .where((row) => row['status']?.toString() == 'closed')
        .toList(growable: false);

    return ListView(
      padding: reportBodyPadding(context),
      children: [
        ReportHeroCard(
          title: 'Cierres de caja',
          subtitle:
              'Seguimiento operativo del cuadre, diferencias y movimientos manuales en un solo lugar.',
          period: formatReportPeriod(state),
          accentColor: MangoColors.primaryOrange,
          trailing: [
            ReportHeroStat(
                label: 'Cierres revisados', value: '$reviewedClosures'),
            ReportHeroStat(label: 'Cuadrados', value: '$balancedClosures'),
          ],
        ),
        if (state.error != null) ...[
          const SizedBox(height: AppSpacing.itemGap),
          Text(
            state.error!,
            style: const TextStyle(color: AppColors.destructive),
          ),
        ],
        if (cachedAt != null) ...[
          const SizedBox(height: AppSpacing.itemGap),
          OfflineDataBanner(cachedAt: cachedAt),
        ],
        const SizedBox(height: AppSpacing.xl),
        buildMetricsWrap(metrics),
        const SizedBox(height: AppSpacing.sectionGap),
        ReportChartCard(
          title: 'Movimientos de caja',
          rows: typeRows,
          color: MangoColors.primaryOrange,
        ),
        const SizedBox(height: AppSpacing.itemGap),
        LayoutBuilder(
          builder: (context, constraints) {
            final singleColumn = constraints.maxWidth < AppBreakpoints.tablet;
            final cards = [
              ReportBreakdownCard(
                title: 'Movimientos por tipo',
                emptyText: 'No hay movimientos de caja en el rango.',
                emptyIcon: Icons.swap_vert_outlined,
                children: typeRows
                    .map(
                      (row) => ReportAmountRow(
                        label: row.label,
                        trailing:
                            '${currency.format(row.amount)} · ${row.count} movs',
                      ),
                    )
                    .toList(),
              ),
              ReportBreakdownCard(
                title: 'Estado de sesiones',
                emptyText: 'No hay sesiones de caja en el rango.',
                emptyIcon: Icons.lock_clock_outlined,
                children: sessionRows.map((row) {
                  final trailing = row.amount != 0
                      ? currency.format(row.amount)
                      : '${row.count} sesiones';
                  return ReportAmountRow(label: row.label, trailing: trailing);
                }).toList(),
              ),
            ];

            if (singleColumn) {
              return Column(
                children: [
                  for (int i = 0; i < cards.length; i++) ...[
                    if (i > 0) const SizedBox(height: AppSpacing.itemGap),
                    cards[i],
                  ],
                ],
              );
            }

            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (int i = 0; i < cards.length; i++) ...[
                  if (i > 0) const SizedBox(width: AppSpacing.itemGap),
                  Expanded(child: cards[i]),
                ],
              ],
            );
          },
        ),
        const SizedBox(height: AppSpacing.sectionGap),
        const ReportSectionLabel(
          title: 'Detalle de cierre y cuadre',
          subtitle:
              'Comparación clara entre lo esperado por el sistema y lo reportado en el cierre.',
        ),
        const SizedBox(height: AppSpacing.itemGap),
        if (closedDetails.isEmpty)
          const ReportSurfaceCard(
            child: ReportEmptyPlaceholder(
              icon: Icons.point_of_sale_outlined,
              message:
                  'No hay cierres de caja para mostrar en el rango seleccionado.',
            ),
          )
        else
          ...closedDetails.take(12).map(
                (closure) => Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.itemGap),
                  child:
                      _CashClosureCard(closure: closure, currency: currency),
                ),
              ),
      ],
    );
  }
}

class _CashClosureCard extends StatelessWidget {
  const _CashClosureCard({required this.closure, required this.currency});

  final Map<String, dynamic> closure;
  final NumberFormat currency;

  @override
  Widget build(BuildContext context) {
    final expectedTotal =
        (closure['expected_total'] as num?)?.toDouble() ?? 0;
    final reportedTotal =
        (closure['reported_total'] as num?)?.toDouble() ?? 0;
    final difference = (closure['difference'] as num?)?.toDouble() ?? 0;
    final openedAt =
        DateTime.tryParse(closure['opened_at']?.toString() ?? '');
    final closedAt =
        DateTime.tryParse(closure['closed_at']?.toString() ?? '');
    // Color por signo: faltante (negativo) → rojo; cuadrado o sobrante → verde.
    final diffColor = difference < -0.009
        ? AppColors.destructive
        : MangoColors.successGreen;

    return ReportSurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      closure['cashier_name']?.toString() ?? 'Cajero',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      '${closure['cash_register_name'] ?? 'Caja'} · ${openedAt != null ? DateFormat('dd/MM/yyyy HH:mm').format(AppTime.astFromInstant(openedAt)) : '-'}',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.mutedForeground,
                      ),
                    ),
                    if (closedAt != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          'Cierre: ${DateFormat('dd/MM/yyyy HH:mm').format(AppTime.astFromInstant(closedAt))}',
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppColors.mutedForeground,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              ReportStatusTag(
                label:
                    difference.abs() < 0.009 ? 'Cuadrado' : 'Con diferencia',
                tone: diffColor,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          LayoutBuilder(
            builder: (context, constraints) {
              // En teléfono las 3 cajas de dinero no caben en una fila
              // (el monto se corta con ellipsis). Debajo de 640 las apilamos
              // a ancho completo — mismo umbral que el ledger de más abajo.
              final stacked = constraints.maxWidth < 640;
              final diffBox = Container(
                padding: const EdgeInsets.all(AppSpacing.cardPadding),
                decoration: BoxDecoration(
                  color: diffColor.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(reportRadius),
                  border: Border.all(
                    color: diffColor.withValues(alpha: 0.25),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Diferencia',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.mutedForeground,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      currency.format(difference),
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: diffColor,
                      ),
                    ),
                  ],
                ),
              );
              final boxes = <Widget>[
                ReportHeroStat(
                  label: 'Esperado',
                  value: currency.format(expectedTotal),
                ),
                ReportHeroStat(
                  label: 'Reportado',
                  value: currency.format(reportedTotal),
                ),
                diffBox,
              ];
              if (stacked) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (int i = 0; i < boxes.length; i++) ...[
                      if (i > 0) const SizedBox(height: AppSpacing.itemGap),
                      boxes[i],
                    ],
                  ],
                );
              }
              return Row(
                children: [
                  for (int i = 0; i < boxes.length; i++) ...[
                    if (i > 0) const SizedBox(width: AppSpacing.itemGap),
                    Expanded(child: boxes[i]),
                  ],
                ],
              );
            },
          ),
          const SizedBox(height: AppSpacing.lg),
          LayoutBuilder(
            builder: (context, constraints) {
              final vertical = constraints.maxWidth < 640;
              final items = [
                ReportLedgerRow(
                  label: 'Esperado efectivo',
                  primaryValue: currency.format(
                    (closure['expected_cash'] as num?)?.toDouble() ?? 0,
                  ),
                  secondaryValue: 'Sistema',
                ),
                ReportLedgerRow(
                  label: 'Reportado efectivo',
                  primaryValue: currency.format(
                    (closure['reported_cash'] as num?)?.toDouble() ?? 0,
                  ),
                  secondaryValue: 'Conteo final',
                ),
                ReportLedgerRow(
                  label: 'Tarjetas / transferencias',
                  primaryValue: currency.format(
                    ((closure['expected_card'] as num?)?.toDouble() ?? 0) +
                        ((closure['expected_transfer'] as num?)?.toDouble() ??
                            0),
                  ),
                  secondaryValue:
                      '${currency.format((closure['reported_card'] as num?)?.toDouble() ?? 0)} reportado en tarjetas · ${currency.format((closure['reported_transfer'] as num?)?.toDouble() ?? 0)} en transferencias',
                ),
              ];
              if (vertical) {
                return Column(children: items);
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (int i = 0; i < items.length; i++) ...[
                    if (i > 0) const SizedBox(width: AppSpacing.itemGap),
                    Expanded(child: items[i]),
                  ],
                ],
              );
            },
          ),
          if ((closure['id']?.toString() ?? '').isNotEmpty) ...[
            const SizedBox(height: AppSpacing.lg),
            Align(
              alignment: Alignment.centerRight,
              child: _ReprintClosureButton(
                sessionId: closure['id'].toString(),
                cashierName: closure['cashier_name']?.toString(),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Botón de reimpresión del ticket de cierre desde el reporte de finanzas.
/// Stateful para su propio spinner/guard porque `_CashClosureCard` es
/// stateless. Reusa `CashClosePrintService.reprintForSession` (mismo formato
/// que el cierre original, marcado como REIMPRESION).
class _ReprintClosureButton extends StatefulWidget {
  const _ReprintClosureButton({required this.sessionId, this.cashierName});

  final String sessionId;
  final String? cashierName;

  @override
  State<_ReprintClosureButton> createState() => _ReprintClosureButtonState();
}

class _ReprintClosureButtonState extends State<_ReprintClosureButton> {
  bool _busy = false;

  Future<void> _run() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      var shownOnScreen = false;
      await CashClosePrintService(Supabase.instance.client).reprintForSession(
        sessionId: widget.sessionId,
        cashierName: widget.cashierName,
        // Modo sin impresora: el cierre se muestra en pantalla con opción
        // de compartir PDF en vez de exigir una térmica.
        presentOnScreen: (plainText) async {
          if (!mounted) return;
          shownOnScreen = true;
          await showTicketPreviewDialog(
            context,
            title: 'Cierre de caja',
            plainText: plainText,
            fileNamePrefix: 'cierre_caja',
          );
        },
      );
      if (!mounted || shownOnScreen) return;
      AppToast.success(context, 'Cierre reimpreso correctamente');
    } catch (e) {
      if (!mounted) return;
      AppToast.error(context, 'No se pudo reimprimir el cierre: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: _busy ? null : _run,
      icon: _busy
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.print_outlined, size: 18),
      label: const Text('Reimprimir cierre'),
      style: OutlinedButton.styleFrom(
        foregroundColor: MangoColors.primaryOrange,
        side: BorderSide(
          color: MangoColors.primaryOrange.withValues(alpha: 0.4),
        ),
      ),
    );
  }
}
