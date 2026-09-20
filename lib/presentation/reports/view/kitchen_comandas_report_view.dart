import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:mangopos/core/theme/app_breakpoints.dart';
import 'package:mangopos/core/theme/app_colors.dart';
import 'package:mangopos/core/theme/app_spacing.dart';
import 'package:mangopos/data/models/kitchen_comanda_report.dart';
import 'package:mangopos/presentation/reports/services/report_ticket_printing.dart';
import 'package:mangopos/presentation/reports/viewmodel/reports_viewmodel.dart';
import 'package:mangopos/presentation/reports/widgets/kitchen_charge_comparison_view.dart';
import 'package:mangopos/presentation/reports/widgets/kitchen_missing_section.dart';
import 'package:mangopos/presentation/reports/widgets/report_scaffold.dart';
import 'package:mangopos/presentation/reports/widgets/report_widgets.dart';
import 'package:mangopos/services/printing/kitchen_comandas_summary_ticket.dart';

const Color _kComandasAccent = Color(0xFFEA580C);

final _qty = NumberFormat('#,##0.##', 'en_US');

/// Reporte "Comandas": cada envío a cocina del rango (hora, mesa, orden,
/// mesero y productos), cuántas órdenes se enviaron y cuánto salió de cada
/// producto. Se filtra por estación (Cocina, Bar…) y se imprime como resumen
/// en la térmica. Fuente: [KitchenComandaReportRepository.getReport].
class KitchenComandasReportView extends StatelessWidget {
  const KitchenComandasReportView({super.key});

  @override
  Widget build(BuildContext context) {
    return ReportScaffold(
      title: 'Comandas',
      category: ReportCategory.comandas,
      body: (state, viewModel) =>
          _ComandasReportBody(state: state, viewModel: viewModel),
    );
  }
}

class _ComandasReportBody extends ConsumerStatefulWidget {
  const _ComandasReportBody({required this.state, required this.viewModel});

  final ReportsState state;
  final ReportsViewModel viewModel;

  @override
  ConsumerState<_ComandasReportBody> createState() =>
      _ComandasReportBodyState();
}

/// Qué se ve: las comandas, o lo enviado a cocina contra lo cobrado.
enum _ComandasMode { comandas, comparison }

/// Qué se imprime.
enum _PrintMode { full, totals, differences }

class _ComandasReportBodyState extends ConsumerState<_ComandasReportBody> {
  bool _printing = false;
  _ComandasMode _mode = _ComandasMode.comandas;

  Future<void> _print() async {
    if (_printing) return;
    final mode = await _askPrintMode(
      context,
      suggested: _mode == _ComandasMode.comparison
          ? _PrintMode.differences
          : _PrintMode.full,
    );
    if (mode == null || !mounted) return;
    final vm = widget.viewModel;
    final report = vm.comandasView;
    final station = vm.comandasStationLabel;
    final openNow = widget.state.comandasOpenReport == null
        ? null
        : vm.comandasOpenView;
    final withoutComanda = widget.state.comandasWithoutComandaReport == null
        ? null
        : vm.comandasWithoutComandaView;
    final missing = vm.comandasMissingView;
    final sold = widget.state.comandasSalesItemsSold;
    final salesItemsSold =
        vm.effectiveComandasArea == null && sold != null && sold >= 0
        ? sold
        : null;
    setState(() => _printing = true);
    try {
      await ReportTicketPrinting.print(
        context,
        ref,
        title: mode == _PrintMode.differences
            ? 'Comandas vs. cobrado'
            : 'Resumen de comandas',
        fileNamePrefix: mode == _PrintMode.differences
            ? 'comandas_vs_cobrado'
            : 'resumen_comandas',
        kind: 'kitchen_comandas_summary',
        build:
            ({required businessName, required currency, required paperWidth}) =>
                mode == _PrintMode.differences
                ? KitchenComandasSummaryTicket.generateComparison(
                    report: report,
                    withoutComanda: withoutComanda,
                    missing: missing,
                    businessName: businessName,
                    from: widget.state.salesFrom,
                    to: widget.state.salesTo,
                    stationLabel: station,
                    paperWidth: paperWidth,
                    salesItemsSold: salesItemsSold,
                    openNow: openNow,
                  )
                : KitchenComandasSummaryTicket.generate(
                    report: report,
                    businessName: businessName,
                    from: widget.state.salesFrom,
                    to: widget.state.salesTo,
                    stationLabel: station,
                    includeComandas: mode == _PrintMode.full,
                    missing: missing,
                    includeMissingDetail: mode == _PrintMode.full,
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
    final vm = widget.viewModel;
    final full = state.comandasReport ?? KitchenComandaReport.empty;
    final report = vm.comandasView;
    final selectedArea = vm.effectiveComandasArea;
    final areas = full.areas;
    final missing = vm.comandasMissingView;
    final hasMissing = missing != null && !missing.isEmpty;
    // ¿Hace falta el día en cada hora? salesTo es EXCLUSIVO, así que el
    // último instante incluido es un pelo antes. Un turno de 6 p. m. a 6
    // a. m. cruza la medianoche: sin el día, "06:00" y "23:00" no dicen de
    // cuál de los dos días son.
    final lastInstant = state.salesTo.subtract(const Duration(microseconds: 1));
    final multiDay =
        lastInstant.year != state.salesFrom.year ||
        lastInstant.month != state.salesFrom.month ||
        lastInstant.day != state.salesFrom.day;

    return ListView(
      padding: reportBodyPadding(context),
      children: [
        ReportHeroCard(
          title: 'Comandas enviadas',
          subtitle:
              'Cada envío a cocina del rango con su mesa, mesero y productos, '
              'y cuánto salió de cada producto. No incluye productos anulados.',
          period: formatReportPeriod(state),
          accentColor: _kComandasAccent,
          trailing: [
            ReportHeroStat(label: 'Comandas', value: '${report.comandasCount}'),
            ReportHeroStat(label: 'Órdenes', value: '${report.ordersCount}'),
            ReportHeroStat(
              label: 'Productos',
              value: _qty.format(report.units),
            ),
            // Lo que alguien quitó de la cuenta después de mandarlo a
            // cocina. Sin el registro (migración 20260919_0002) no se
            // muestra: un 0 diría "no se borró nada", que sería falso.
            if (missing != null)
              ReportHeroStat(
                label: 'Eliminaciones',
                value: '${missing.removals.length}',
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
        SegmentedButton<_ComandasMode>(
          segments: const [
            ButtonSegment(
              value: _ComandasMode.comandas,
              icon: Icon(Icons.soup_kitchen_outlined, size: 18),
              label: Text('Comandas'),
            ),
            ButtonSegment(
              value: _ComandasMode.comparison,
              icon: Icon(Icons.compare_arrows, size: 18),
              label: Text('Enviado vs. cobrado'),
            ),
          ],
          selected: {_mode},
          showSelectedIcon: false,
          onSelectionChanged: (s) => setState(() => _mode = s.first),
        ),
        const SizedBox(height: AppSpacing.itemGap),
        _HourRangeBar(state: state, viewModel: vm),
        const SizedBox(height: AppSpacing.itemGap),
        Wrap(
          spacing: AppSpacing.tightGap,
          runSpacing: AppSpacing.tightGap,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (areas.length > 1 ||
                areas.any(
                  (a) => a.code == KitchenComandaReport.noAreaCode,
                )) ...[
              ReportRangeChip(
                label: 'Todas',
                selected: selectedArea == null,
                onTap: () => vm.setComandasArea(null),
              ),
              for (final a in areas)
                ReportRangeChip(
                  label: a.name,
                  selected: selectedArea == a.code,
                  onTap: () => vm.setComandasArea(a.code),
                ),
            ],
            FilledButton.icon(
              onPressed: _printing || state.comandasReport == null
                  ? null
                  : _print,
              style: FilledButton.styleFrom(
                backgroundColor: _kComandasAccent,
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 14,
                ),
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
              label: const Text('Imprimir resumen'),
            ),
          ],
        ),
        // Solo anulados también cuenta: el comparador los muestra. Y aunque
        // el rango esté vacío, puede haber cuentas abiertas de antes.
        if (_mode == _ComandasMode.comparison && !report.hasChargeData) ...[
          // Con la RPC vieja toda orden parece abierta: mejor no comparar
          // que mostrar como "pendiente" una orden anulada.
          const SizedBox(height: AppSpacing.sectionGap),
          const ReportSurfaceCard(
            child: ReportEmptyPlaceholder(
              icon: Icons.system_update_alt,
              message:
                  'El servidor tiene una versión vieja del reporte de comandas. '
                  'Falta volver a correr la migración 20260919_0001: sin eso '
                  'no se puede saber qué se cobró, qué se anuló ni qué sigue '
                  'abierto.',
            ),
          ),
        ] else if (_mode == _ComandasMode.comparison &&
            (report.allComandas.isNotEmpty ||
                vm.comandasOpenView.allComandas.isNotEmpty ||
                hasMissing)) ...[
          const SizedBox(height: AppSpacing.sectionGap),
          KitchenChargeComparisonView(
            report: report,
            openNow: state.comandasOpenReport == null
                ? null
                : vm.comandasOpenView,
            withoutComanda: state.comandasWithoutComandaReport == null
                ? null
                : vm.comandasWithoutComandaView,
            missing: missing,
            multiDay: multiDay,
            // El número de Ventas es de todas las estaciones: con filtro no
            // es comparable.
            salesItemsSold:
                selectedArea == null &&
                    (state.comandasSalesItemsSold ?? -1) >= 0
                ? state.comandasSalesItemsSold
                : null,
          ),
        ] else ...[
          // Lo que salió a cocina y ninguna cuenta tiene: arriba de todo,
          // aunque el rango no tenga otras comandas.
          if (_mode == _ComandasMode.comandas && hasMissing) ...[
            const SizedBox(height: AppSpacing.sectionGap),
            KitchenMissingSection(missing: missing, multiDay: multiDay),
          ],
          ..._comandasBody(report, multiDay),
        ],
      ],
    );
  }

  List<Widget> _comandasBody(KitchenComandaReport report, bool multiDay) {
    return [
      if (report.isEmpty)
        const Padding(
          padding: EdgeInsets.only(top: AppSpacing.itemGap),
          child: ReportSurfaceCard(
            child: ReportEmptyPlaceholder(
              icon: Icons.soup_kitchen_outlined,
              message: 'No se enviaron comandas en el rango seleccionado.',
            ),
          ),
        )
      else ...[
        const SizedBox(height: AppSpacing.sectionGap),
        LayoutBuilder(
          builder: (context, constraints) {
            final totals = _ProductTotalsSection(report: report);
            final list = _ComandasSection(
              comandas: report.comandas,
              multiDay: multiDay,
              showCharge: report.hasChargeData,
            );
            // Escritorio: lado a lado. Teléfono/tablet angosta: el total
            // arriba, para no dejarlo debajo de cien comandas.
            if (constraints.maxWidth < AppBreakpoints.tablet) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  totals,
                  const SizedBox(height: AppSpacing.sectionGap),
                  list,
                ],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 3, child: list),
                const SizedBox(width: AppSpacing.itemGap),
                Expanded(flex: 2, child: totals),
              ],
            );
          },
        ),
      ],
    ];
  }
}

/// Pregunta qué imprimir; `null` = canceló. [suggested] sale resaltado.
Future<_PrintMode?> _askPrintMode(
  BuildContext context, {
  required _PrintMode suggested,
}) {
  Widget option(
    BuildContext ctx,
    _PrintMode mode,
    IconData icon,
    String title,
    String detail,
  ) {
    final highlighted = mode == suggested;
    return ListTile(
      leading: Icon(
        icon,
        color: highlighted ? _kComandasAccent : AppColors.mutedForeground,
      ),
      title: Text(
        title,
        style: TextStyle(
          fontWeight: highlighted ? FontWeight.w800 : FontWeight.w600,
        ),
      ),
      subtitle: Text(detail),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(reportRadius),
      ),
      tileColor: highlighted ? _kComandasAccent.withValues(alpha: 0.08) : null,
      onTap: () => Navigator.of(ctx).pop(mode),
    );
  }

  return showDialog<_PrintMode>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('¿Qué quieres imprimir?'),
      contentPadding: const EdgeInsets.fromLTRB(12, 16, 12, 0),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            option(
              ctx,
              _PrintMode.full,
              Icons.receipt_long_outlined,
              'Todas las comandas',
              'Cuántas comandas y órdenes, cada comanda, las desaparecidas '
                  'y al final cuánto salió de cada producto.',
            ),
            const SizedBox(height: 4),
            option(
              ctx,
              _PrintMode.totals,
              Icons.format_list_numbered,
              'Solo total por producto',
              'El conteo y cuánto salió de cada producto, sin el detalle.',
            ),
            const SizedBox(height: 4),
            option(
              ctx,
              _PrintMode.differences,
              Icons.compare_arrows,
              'Enviado vs. cobrado',
              'Lo que salió a cocina y no se cobró: sin cobrar, pendiente, '
                  'cortesía, anulado y desaparecido.',
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Cancelar'),
        ),
      ],
    ),
  );
}

// ---------------------------------------------------------------------------
// Rango con horas (el turno cruza la medianoche)
// ---------------------------------------------------------------------------

/// Barra con el rango que se está viendo y el botón para elegir las horas.
/// Un bar cierra de madrugada: "ayer 6:00 p. m. → hoy 6:00 a. m." es un
/// servicio, y por día completo sale partido en dos.
class _HourRangeBar extends StatelessWidget {
  const _HourRangeBar({required this.state, required this.viewModel});

  final ReportsState state;
  final ReportsViewModel viewModel;

  static final _dayTime = DateFormat('dd/MM h:mm a');
  static final _day = DateFormat('dd/MM');

  static bool _isMidnight(DateTime d) => d.hour == 0 && d.minute == 0;

  @override
  Widget build(BuildContext context) {
    final from = state.salesFrom;
    final to = state.salesTo;
    final wholeDays = _isMidnight(from) && _isMidnight(to);
    final label = wholeDays
        ? 'Días completos: ${_day.format(from)} → '
              '${_day.format(to.subtract(const Duration(days: 1)))}'
        : '${_dayTime.format(from)} → ${_dayTime.format(to)}';

    return Wrap(
      spacing: AppSpacing.tightGap,
      runSpacing: AppSpacing.tightGap,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: wholeDays
                ? AppColors.secondary.withValues(alpha: 0.6)
                : _kComandasAccent.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(reportRadius),
            border: Border.all(
              color: wholeDays
                  ? AppColors.border
                  : _kComandasAccent.withValues(alpha: 0.4),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                wholeDays ? Icons.calendar_today_outlined : Icons.schedule,
                size: 16,
                color: wholeDays ? AppColors.mutedForeground : _kComandasAccent,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: wholeDays
                      ? AppColors.mutedForeground
                      : _kComandasAccent,
                ),
              ),
            ],
          ),
        ),
        OutlinedButton.icon(
          style: reportOutlineButtonStyle(),
          onPressed: () async {
            final picked = await showDialog<({DateTime from, DateTime to})>(
              context: context,
              builder: (ctx) => _HourRangeDialog(from: from, to: to),
            );
            if (picked == null) return;
            await viewModel.setSalesRangeWithHours(picked.from, picked.to);
          },
          icon: const Icon(Icons.more_time, size: 18),
          label: const Text('Elegir horas'),
        ),
      ],
    );
  }
}

/// Elige desde qué día y hora hasta qué día y hora. La hora final es el
/// límite: "hasta las 6:00 a. m." incluye todo lo enviado antes de esa hora.
class _HourRangeDialog extends StatefulWidget {
  const _HourRangeDialog({required this.from, required this.to});

  final DateTime from;
  final DateTime to;

  @override
  State<_HourRangeDialog> createState() => _HourRangeDialogState();
}

class _HourRangeDialogState extends State<_HourRangeDialog> {
  late DateTime _from = widget.from;
  late DateTime _to = widget.to;

  static final _dayTime = DateFormat('EEE dd/MM · h:mm a');

  bool get _valid => _to.isAfter(_from);

  Future<void> _pick({required bool isFrom}) async {
    final current = isFrom ? _from : _to;
    final date = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(current.year - 2),
      lastDate: DateTime.now().add(const Duration(days: 1)),
      helpText: isFrom ? 'Desde qué día' : 'Hasta qué día',
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(current),
      helpText: isFrom ? 'Desde qué hora' : 'Hasta qué hora',
    );
    if (time == null || !mounted) return;
    final picked = DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    );
    setState(() {
      if (isFrom) {
        _from = picked;
      } else {
        _to = picked;
      }
    });
  }

  /// El servicio de anoche: de las 6:00 p. m. de ayer a las 6:00 a. m. de hoy.
  void _lastShift() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    setState(() {
      _from = today
          .subtract(const Duration(days: 1))
          .add(const Duration(hours: 18));
      _to = today.add(const Duration(hours: 6));
    });
  }

  /// Hoy completo, de medianoche a medianoche.
  void _wholeDay() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    setState(() {
      _from = today;
      _to = today.add(const Duration(days: 1));
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('¿Desde qué hora y hasta cuándo?'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'El turno de la noche cruza la medianoche: así el reporte sale '
              'de un servicio completo y no partido en dos días.',
              style: TextStyle(
                fontSize: 12.5,
                color: AppColors.mutedForeground,
              ),
            ),
            const SizedBox(height: AppSpacing.itemGap),
            _PickerTile(
              label: 'Desde',
              value: _dayTime.format(_from),
              onTap: () => _pick(isFrom: true),
            ),
            const SizedBox(height: AppSpacing.sm),
            _PickerTile(
              label: 'Hasta',
              value: _dayTime.format(_to),
              onTap: () => _pick(isFrom: false),
            ),
            if (!_valid) ...[
              const SizedBox(height: AppSpacing.sm),
              const Text(
                'La hora final tiene que ser después de la inicial.',
                style: TextStyle(fontSize: 12.5, color: AppColors.destructive),
              ),
            ],
            const SizedBox(height: AppSpacing.itemGap),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                ActionChip(
                  avatar: const Icon(Icons.nightlight_outlined, size: 16),
                  label: const Text('Turno de anoche (6 p. m. → 6 a. m.)'),
                  onPressed: _lastShift,
                ),
                ActionChip(
                  avatar: const Icon(Icons.today_outlined, size: 16),
                  label: const Text('Hoy completo'),
                  onPressed: _wholeDay,
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: _kComandasAccent),
          onPressed: _valid
              ? () => Navigator.of(context).pop((from: _from, to: _to))
              : null,
          child: const Text('Aplicar'),
        ),
      ],
    );
  }
}

class _PickerTile extends StatelessWidget {
  const _PickerTile({
    required this.label,
    required this.value,
    required this.onTap,
  });

  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      style: OutlinedButton.styleFrom(
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        side: const BorderSide(color: AppColors.border),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(reportRadius),
        ),
      ),
      onPressed: onTap,
      child: Row(
        children: [
          SizedBox(
            width: 64,
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: AppColors.mutedForeground,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: AppColors.foreground,
              ),
            ),
          ),
          const Icon(Icons.edit_calendar_outlined, size: 18),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Total por producto
// ---------------------------------------------------------------------------

class _ProductTotalsSection extends StatelessWidget {
  const _ProductTotalsSection({required this.report});

  final KitchenComandaReport report;

  @override
  Widget build(BuildContext context) {
    final totals = report.productTotals;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const ReportSectionLabel(
          title: 'Total por producto',
          subtitle: 'Cuánto salió de cada producto en el rango.',
        ),
        const SizedBox(height: AppSpacing.itemGap),
        ReportSurfaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    _headerCell('Producto', flex: 5),
                    _headerCell('Cantidad', flex: 2, end: true),
                    _headerCell('Comandas', flex: 2, end: true),
                  ],
                ),
              ),
              Divider(
                height: 1,
                color: AppColors.border.withValues(alpha: 0.6),
              ),
              for (var i = 0; i < totals.length; i++) ...[
                if (i > 0)
                  Divider(
                    height: 1,
                    color: AppColors.border.withValues(alpha: 0.4),
                  ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 9),
                  child: Row(
                    children: [
                      _textCell(totals[i].productName, flex: 5, bold: true),
                      _textCell(
                        _qty.format(totals[i].quantity),
                        flex: 2,
                        end: true,
                        bold: true,
                        color: _kComandasAccent,
                      ),
                      _textCell(
                        '${totals[i].comandas}',
                        flex: 2,
                        end: true,
                        muted: true,
                      ),
                    ],
                  ),
                ),
              ],
              Divider(
                height: 1,
                color: AppColors.border.withValues(alpha: 0.6),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Row(
                  children: [
                    _textCell('Total', flex: 5, bold: true),
                    _textCell(
                      _qty.format(report.units),
                      flex: 2,
                      end: true,
                      bold: true,
                    ),
                    _textCell(
                      '${report.comandasCount}',
                      flex: 2,
                      end: true,
                      bold: true,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Comandas
// ---------------------------------------------------------------------------

class _ComandasSection extends StatefulWidget {
  const _ComandasSection({
    required this.comandas,
    required this.multiDay,
    this.showCharge = true,
  });

  final List<KitchenComanda> comandas;
  final bool multiDay;

  /// false con la RPC vieja: sin datos de cobro no se marca nada.
  final bool showCharge;

  @override
  State<_ComandasSection> createState() => _ComandasSectionState();
}

class _ComandasSectionState extends State<_ComandasSection> {
  bool _onlyUncharged = false;

  /// "No se cobró": sin cobrar (nunca) o pendiente (todavía no).
  static bool _uncharged(KitchenComanda c) =>
      c.unitsIn(KitchenChargeState.unpaid) > 0.005 ||
      c.unitsIn(KitchenChargeState.pending) > 0.005;

  @override
  Widget build(BuildContext context) {
    final time = DateFormat(widget.multiDay ? 'dd/MM HH:mm' : 'HH:mm');
    final uncharged = widget.showCharge
        ? widget.comandas.where(_uncharged).toList()
        : const <KitchenComanda>[];
    final shown = _onlyUncharged ? uncharged : widget.comandas;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ReportSectionLabel(
          title: 'Comandas',
          subtitle:
              '${widget.comandas.length} '
              '${widget.comandas.length == 1 ? 'envío' : 'envíos'} a cocina, '
              'del primero al último.',
        ),
        if (uncharged.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.sm),
          Align(
            alignment: Alignment.centerLeft,
            child: FilterChip(
              label: Text('Solo las no cobradas (${uncharged.length})'),
              selected: _onlyUncharged,
              selectedColor: AppColors.destructive.withValues(alpha: 0.12),
              onSelected: (v) => setState(() => _onlyUncharged = v),
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.itemGap),
        for (final c in shown)
          _ComandaCard(comanda: c, time: time, showCharge: widget.showCharge),
      ],
    );
  }
}

class _ComandaCard extends StatelessWidget {
  const _ComandaCard({
    required this.comanda,
    required this.time,
    this.showCharge = true,
  });

  final bool showCharge;

  final KitchenComanda comanda;
  final DateFormat time;

  @override
  Widget build(BuildContext context) {
    final c = comanda;
    final waiter = c.waiterName;
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.tightGap),
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(reportRadius),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                time.format(c.sentAt),
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 13,
                  color: _kComandasAccent,
                ),
              ),
              Text(
                c.tableName,
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 14,
                  color: AppColors.foreground,
                ),
              ),
              Text(
                '#${c.orderNumber}',
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.mutedForeground,
                ),
              ),
              for (final area in c.areaNames)
                ReportStatusTag(label: area, tone: AppColors.info),
              // Lo que no se cobró de esta comanda, a la vista.
              if (showCharge)
                for (final state in const [
                  KitchenChargeState.unpaid,
                  KitchenChargeState.pending,
                  KitchenChargeState.courtesy,
                ])
                  if (c.unitsIn(state) > 0.005)
                    ReportStatusTag(
                      label: '${state.label}: ${_qty.format(c.unitsIn(state))}',
                      tone: kitchenChargeStateColor(state),
                    ),
            ],
          ),
          if (waiter != null) ...[
            const SizedBox(height: 2),
            Text(
              'Mesero: $waiter',
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.mutedForeground,
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.sm),
          for (final i in c.displayItems) ...[
            Text(
              '${_qty.format(i.quantity)} × ${i.productName}',
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.foreground,
              ),
            ),
            for (final m in i.modifiers)
              Padding(
                padding: const EdgeInsets.only(left: 16),
                child: Text(
                  '+ ${m.name}${m.qty > 1 ? ' ×${_qty.format(m.qty)}' : ''}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.mutedForeground,
                  ),
                ),
              ),
            if (i.notes != null)
              Padding(
                padding: const EdgeInsets.only(left: 16),
                child: Text(
                  'Nota: ${i.notes}',
                  style: const TextStyle(
                    fontSize: 12,
                    fontStyle: FontStyle.italic,
                    color: AppColors.mutedForeground,
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Celdas (mismo estilo que los reportes de Delivery y Abonos)
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
  Color? color,
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
        color:
            color ?? (muted ? AppColors.mutedForeground : AppColors.foreground),
      ),
    ),
  );
}
