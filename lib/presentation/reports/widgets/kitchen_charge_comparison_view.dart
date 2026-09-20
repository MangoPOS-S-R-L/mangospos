import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mangopos/core/theme/app_breakpoints.dart';
import 'package:mangopos/core/theme/app_colors.dart';
import 'package:mangopos/core/theme/app_spacing.dart';
import 'package:mangopos/data/models/kitchen_comanda_report.dart';
import 'package:mangopos/data/models/kitchen_missing_report.dart';
import 'package:mangopos/presentation/reports/widgets/kitchen_missing_section.dart';
import 'package:mangopos/presentation/reports/widgets/report_widgets.dart';

final _qty = NumberFormat('#,##0.##', 'en_US');

/// Color de cada estado de cobro. "Sin cobrar" es la alerta.
Color kitchenChargeStateColor(KitchenChargeState state) => switch (state) {
  KitchenChargeState.charged => const Color(0xFF16A34A),
  KitchenChargeState.courtesy => AppColors.reserved,
  KitchenChargeState.zeroCharge => AppColors.info,
  KitchenChargeState.pending => AppColors.warning,
  KitchenChargeState.unpaid => AppColors.destructive,
  KitchenChargeState.voided => AppColors.mutedForeground,
};

/// Título de cada grupo del detalle.
String kitchenChargeGroupTitle(KitchenChargeState state) => switch (state) {
  KitchenChargeState.unpaid => 'Sin cobrar',
  KitchenChargeState.pending => 'Pendiente — mesa abierta',
  KitchenChargeState.courtesy => 'Cortesía',
  KitchenChargeState.zeroCharge => 'Cobrado a 0',
  KitchenChargeState.voided => 'Anulado después de enviar a cocina',
  KitchenChargeState.charged => 'Cobrado',
};

/// Comparador "enviado a cocina vs. cobrado" del reporte de comandas.
class KitchenChargeComparisonView extends StatefulWidget {
  const KitchenChargeComparisonView({
    super.key,
    required this.report,
    required this.multiDay,
    this.salesItemsSold,
    this.openNow,
    this.withoutComanda,
    this.missing,
    this.showMissing = true,
  });

  /// Comandas desaparecidas (borradas/reducidas después de enviarse o fuera
  /// de toda cuenta). Null = no se pudieron cargar.
  final KitchenMissingReport? missing;

  /// false = no se muestra la sección (p. ej. en pruebas del comparador).
  final bool showMissing;

  /// Las comandas del rango (con la estación ya filtrada).
  final KitchenComandaReport report;
  final bool multiDay;

  /// Lo que sigue sin cobrar ahora, sin importar el rango. Null = no se
  /// pudo cargar.
  final KitchenComandaReport? openNow;

  /// Lo cobrado en el rango que nunca pasó por cocina. Null = no se pudo
  /// cargar.
  final KitchenComandaReport? withoutComanda;

  /// Productos cobrados del período según el reporte de Ventas, para
  /// cuadrar. Null = no aplica (filtro por estación) o no se pudo leer.
  final double? salesItemsSold;

  @override
  State<KitchenChargeComparisonView> createState() =>
      _KitchenChargeComparisonViewState();
}

class _KitchenChargeComparisonViewState
    extends State<KitchenChargeComparisonView> {
  bool _showAll = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.report.comparison;
    final toReview = c.products.where((p) => p.needsReview).toList();
    final rows = _showAll ? c.products : toReview;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Summary(
          comparison: c,
          salesItemsSold: widget.salesItemsSold,
          withoutComandaUnits: widget.withoutComanda?.accounts.fold<double>(
            0,
            (s, a) => s + a.units,
          ),
          removedUnits: widget.missing?.removedUnits,
        ),
        if (c.differences.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.sectionGap),
          _UnchargedComandasSection(
            report: widget.report,
            multiDay: widget.multiDay,
          ),
        ],
        if (widget.showMissing) ...[
          const SizedBox(height: AppSpacing.sectionGap),
          KitchenMissingSection(
            missing: widget.missing,
            multiDay: widget.multiDay,
          ),
        ],
        const SizedBox(height: AppSpacing.sectionGap),
        ReportSectionLabel(
          title: 'Por producto',
          subtitle: _showAll
              ? 'Todos los productos que salieron a cocina.'
              : 'Solo los productos con algo que revisar: pendiente, sin '
                    'cobrar, cortesía o anulado.',
        ),
        const SizedBox(height: AppSpacing.sm),
        Align(
          alignment: Alignment.centerLeft,
          child: FilterChip(
            label: Text('Ver todos los productos (${c.products.length})'),
            selected: _showAll,
            onSelected: (v) => setState(() => _showAll = v),
          ),
        ),
        const SizedBox(height: AppSpacing.itemGap),
        if (rows.isEmpty)
          const ReportSurfaceCard(
            child: ReportEmptyPlaceholder(
              icon: Icons.verified_outlined,
              message:
                  'Todo lo que salió a cocina en el rango está cobrado, sin '
                  'cortesías ni anulados.',
            ),
          )
        else
          _ProductsTable(rows: rows),
        if (widget.withoutComanda != null &&
            widget.withoutComanda!.allComandas.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.sectionGap),
          _WithoutComandaSection(report: widget.withoutComanda!),
        ],
        if (widget.openNow != null) ...[
          const SizedBox(height: AppSpacing.sectionGap),
          _OpenNowSection(openNow: widget.openNow!),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Resumen
// ---------------------------------------------------------------------------

/// "incluye 7 de cortesía y 3 a 0": lo que está dentro de lo cobrado sin
/// haber cobrado dinero.
String? _chargedHint(KitchenChargeComparison c) {
  final parts = [
    if (c.courtesy > 0.005) '${_qty.format(c.courtesy)} de cortesía',
    if (c.zeroCharge > 0.005) '${_qty.format(c.zeroCharge)} a 0',
  ];
  return parts.isEmpty ? null : 'incluye ${parts.join(' y ')}';
}

class _Summary extends StatelessWidget {
  const _Summary({
    required this.comparison,
    this.salesItemsSold,
    this.withoutComandaUnits,
    this.removedUnits,
  });

  final KitchenChargeComparison comparison;
  final double? salesItemsSold;

  /// Borrado o reducido después de enviarse: ya no está en ninguna cuenta,
  /// así que no entra en "Enviado". Null = no se pudo cargar.
  final double? removedUnits;

  /// Cobrado en el rango sin pasar por cocina. Null = no se pudo cargar.
  final double? withoutComandaUnits;

  @override
  Widget build(BuildContext context) {
    final c = comparison;
    final hasDiff = c.difference > 0.005;
    final sold = salesItemsSold;
    return ReportSurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: AppSpacing.itemGap,
            runSpacing: AppSpacing.itemGap,
            children: [
              _Stat(label: 'Enviado a cocina', value: c.sent),
              _Stat(
                label: 'Cobrado',
                value: c.charged,
                color: kitchenChargeStateColor(KitchenChargeState.charged),
                hint: _chargedHint(c),
              ),
              _Stat(
                label: 'Diferencia',
                value: c.difference,
                color: hasDiff ? AppColors.destructive : null,
                emphasize: true,
                hint: 'pendiente + sin cobrar',
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          Text(
            hasDiff
                ? 'La diferencia se explica así:'
                : 'Todo lo que salió a cocina quedó en una factura.',
            style: const TextStyle(
              fontSize: 12.5,
              color: AppColors.mutedForeground,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              _Pill(
                state: KitchenChargeState.pending,
                value: c.pending,
                label: 'Pendiente (mesa abierta)',
              ),
              _Pill(state: KitchenChargeState.unpaid, value: c.unpaid),
              _Pill(
                state: KitchenChargeState.courtesy,
                value: c.courtesy,
                label: 'Cortesía (dentro de lo cobrado)',
              ),
              if (c.zeroCharge > 0.005)
                _Pill(
                  state: KitchenChargeState.zeroCharge,
                  value: c.zeroCharge,
                  label: 'Cobrado a 0 (dentro de lo cobrado)',
                ),
              _Pill(
                state: KitchenChargeState.voided,
                value: c.voided,
                label: 'Anulado (aparte)',
              ),
              if (withoutComandaUnits != null)
                _Pill(
                  state: KitchenChargeState.charged,
                  value: withoutComandaUnits!,
                  label: 'Cobrado sin comanda (aparte)',
                ),
              if (removedUnits != null)
                _Pill(
                  state: KitchenChargeState.unpaid,
                  value: removedUnits!,
                  label: 'Borrado o reducido después de enviar (aparte)',
                ),
            ],
          ),
          if (sold != null) ...[
            const SizedBox(height: AppSpacing.lg),
            _SalesCrossCheck(
              charged: c.charged,
              withoutComanda: withoutComandaUnits ?? 0,
              sold: sold,
            ),
          ],
        ],
      ),
    );
  }
}

/// Cuadre con el reporte de Ventas: el mismo número que ese reporte muestra
/// como productos cobrados en el período.
class _SalesCrossCheck extends StatelessWidget {
  const _SalesCrossCheck({
    required this.charged,
    required this.sold,
    this.withoutComanda = 0,
  });

  final double charged;
  final double sold;

  /// Cobrado sin comanda: también está en Ventas.
  final double withoutComanda;

  @override
  Widget build(BuildContext context) {
    final total = charged + withoutComanda;
    final gap = sold - total;
    final matches = gap.abs() < 0.5;
    final composition = withoutComanda > 0.005
        ? 'Cobrado en comandas ${_qty.format(charged)} + sin comanda '
              '${_qty.format(withoutComanda)} = ${_qty.format(total)}. '
        : '';
    final String detail;
    if (matches) {
      detail = '${composition}Cuadra con Ventas.';
    } else if (gap > 0) {
      detail =
          '$composition${_qty.format(gap)} de los productos de Ventas se '
          'enviaron a cocina en otro día (Ventas cuenta por la fecha del '
          'pago).';
    } else {
      detail =
          '${composition}Hay ${_qty.format(-gap)} productos cobrados más que '
          'en Ventas: se enviaron en este período pero se cobraron en otro '
          'día.';
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: matches ? AppColors.successSurface : AppColors.infoSurface,
        borderRadius: BorderRadius.circular(reportRadius),
        border: Border.all(
          color: (matches ? AppColors.success : AppColors.info).withValues(
            alpha: 0.3,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Según el reporte de Ventas se cobraron ${_qty.format(sold)} '
            'productos en el período.',
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: AppColors.foreground,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            detail,
            style: const TextStyle(
              fontSize: 12.5,
              color: AppColors.mutedForeground,
            ),
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({
    required this.label,
    required this.value,
    this.color,
    this.emphasize = false,
    this.hint,
  });

  final String label;
  final double value;
  final Color? color;
  final bool emphasize;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 130),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: AppColors.mutedForeground,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            _qty.format(value),
            style: TextStyle(
              fontSize: emphasize ? 26 : 22,
              fontWeight: FontWeight.w800,
              color: color ?? AppColors.foreground,
            ),
          ),
          if (hint != null)
            Text(
              hint!,
              style: const TextStyle(
                fontSize: 11.5,
                color: AppColors.mutedForeground,
              ),
            ),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.state, required this.value, this.label});

  final KitchenChargeState state;
  final double value;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final color = kitchenChargeStateColor(state);
    final active = value > 0.005;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: active
            ? color.withValues(alpha: 0.1)
            : AppColors.secondary.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(reportRadius),
        border: Border.all(
          color: active ? color.withValues(alpha: 0.35) : AppColors.border,
        ),
      ),
      child: Text(
        '${label ?? state.label}: ${_qty.format(value)}',
        style: TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w700,
          color: active ? color : AppColors.mutedForeground,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Por producto
// ---------------------------------------------------------------------------

class _ProductsTable extends StatelessWidget {
  const _ProductsTable({required this.rows});

  final List<KitchenChargeProductRow> rows;

  static String _n(double v) => v.abs() < 0.005 ? '—' : _qty.format(v);

  @override
  Widget build(BuildContext context) {
    if (ResponsiveHelper.isMobile(context)) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final r in rows)
            ReportRecordCard(
              title: r.productName,
              fields: [
                ReportRecordField('Enviado a cocina', _qty.format(r.sent)),
                ReportRecordField('Cobrado', _qty.format(r.charged)),
                ReportRecordField(
                  'Diferencia',
                  _qty.format(r.difference),
                  emphasize: true,
                  valueColor: r.difference > 0.005
                      ? AppColors.destructive
                      : null,
                ),
                for (final (state, value) in [
                  (KitchenChargeState.pending, r.pending),
                  (KitchenChargeState.unpaid, r.unpaid),
                  (KitchenChargeState.courtesy, r.courtesy),
                  (KitchenChargeState.voided, r.voided),
                ])
                  if (value > 0.005)
                    ReportRecordField(
                      state.label,
                      _qty.format(value),
                      valueColor: kitchenChargeStateColor(state),
                    ),
              ],
            ),
        ],
      );
    }

    return ReportSurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                _header('Producto', flex: 4),
                _header('Enviado', flex: 2),
                _header('Cobrado', flex: 2),
                _header('Cortesía', flex: 2),
                _header('Pendiente', flex: 2),
                _header('Sin cobrar', flex: 2),
                _header('Diferencia', flex: 2),
                _header('Anulado', flex: 2),
              ],
            ),
          ),
          Divider(height: 1, color: AppColors.border.withValues(alpha: 0.6)),
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0)
              Divider(
                height: 1,
                color: AppColors.border.withValues(alpha: 0.4),
              ),
            _row(rows[i]),
          ],
        ],
      ),
    );
  }

  Widget _row(KitchenChargeProductRow r) {
    return Container(
      color: r.unpaid > 0.005
          ? AppColors.destructive.withValues(alpha: 0.05)
          : null,
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(
        children: [
          Expanded(
            flex: 4,
            child: Text(
              r.productName,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 12.5,
                color: AppColors.foreground,
              ),
            ),
          ),
          _cell(_qty.format(r.sent)),
          _cell(_qty.format(r.charged)),
          _cell(
            _n(r.courtesy),
            color: kitchenChargeStateColor(KitchenChargeState.courtesy),
          ),
          _cell(
            _n(r.pending),
            color: kitchenChargeStateColor(KitchenChargeState.pending),
          ),
          _cell(
            _n(r.unpaid),
            color: kitchenChargeStateColor(KitchenChargeState.unpaid),
          ),
          _cell(
            _n(r.difference),
            color: r.difference > 0.005 ? AppColors.destructive : null,
            bold: true,
          ),
          _cell(_n(r.voided), color: AppColors.mutedForeground),
        ],
      ),
    );
  }

  static Widget _header(String label, {required int flex}) {
    return Expanded(
      flex: flex,
      child: Text(
        label,
        textAlign: flex == 4 ? TextAlign.start : TextAlign.end,
        style: const TextStyle(
          fontWeight: FontWeight.w700,
          fontSize: 12,
          color: AppColors.mutedForeground,
        ),
      ),
    );
  }

  static Widget _cell(String value, {Color? color, bool bold = false}) {
    final isZero = value == '—';
    return Expanded(
      flex: 2,
      child: Text(
        value,
        textAlign: TextAlign.end,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontWeight: bold || !isZero ? FontWeight.w700 : FontWeight.w400,
          fontSize: 12.5,
          color: isZero
              ? AppColors.mutedForeground
              : (color ?? AppColors.foreground),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Comandas no cobradas
// ---------------------------------------------------------------------------

/// "Cuáles fueron las comandas": cada comanda con sus productos en el estado
/// elegido (sin cobrar, pendiente, cortesía o anulado).
class _UnchargedComandasSection extends StatefulWidget {
  const _UnchargedComandasSection({
    required this.report,
    required this.multiDay,
  });

  final KitchenComandaReport report;
  final bool multiDay;

  @override
  State<_UnchargedComandasSection> createState() =>
      _UnchargedComandasSectionState();
}

class _UnchargedComandasSectionState extends State<_UnchargedComandasSection> {
  static const _states = [
    KitchenChargeState.unpaid,
    KitchenChargeState.pending,
    KitchenChargeState.courtesy,
    KitchenChargeState.voided,
  ];

  KitchenChargeState? _selected;

  @override
  Widget build(BuildContext context) {
    final byState = {for (final s in _states) s: widget.report.comandasIn(s)};
    final available = [
      for (final s in _states)
        if (byState[s]!.isNotEmpty) s,
    ];
    if (available.isEmpty) return const SizedBox.shrink();
    // Por defecto lo más grave que haya: sin cobrar, luego pendiente…
    final selected = available.contains(_selected)
        ? _selected!
        : available.first;
    final comandas = byState[selected]!;
    final time = DateFormat(widget.multiDay ? 'dd/MM HH:mm' : 'HH:mm');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const ReportSectionLabel(
          title: 'Comandas no cobradas',
          subtitle:
              'Cuáles fueron las comandas y qué productos de cada una no se '
              'cobraron normal.',
        ),
        const SizedBox(height: AppSpacing.sm),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: [
            for (final s in available)
              ChoiceChip(
                label: Text(
                  '${kitchenChargeGroupTitle(s)} (${byState[s]!.length})',
                ),
                selected: s == selected,
                selectedColor: kitchenChargeStateColor(
                  s,
                ).withValues(alpha: 0.15),
                onSelected: (_) => setState(() => _selected = s),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.itemGap),
        for (final c in comandas)
          _ComandaDifferenceCard(
            comanda: c,
            state: selected,
            noteLabel: selected == KitchenChargeState.voided
                ? widget.report.voidNoteLabel(c)
                : null,
            header:
                '${time.format(c.sentAt)} · ${c.tableName} · '
                '#${c.orderNumber}',
          ),
      ],
    );
  }
}

class _ComandaDifferenceCard extends StatelessWidget {
  const _ComandaDifferenceCard({
    required this.comanda,
    required this.state,
    required this.header,
    this.noteLabel,
  });

  /// "Nota: …" de la anulación (solo en lo anulado).
  final String? noteLabel;

  final KitchenComanda comanda;
  final KitchenChargeState state;
  final String header;

  @override
  Widget build(BuildContext context) {
    final color = kitchenChargeStateColor(state);
    final waiter = comanda.waiterName;
    // Todos los productos de una comanda son de la misma orden: el motivo
    // es el mismo para todos.
    final reason = comanda.items.first.stateReason;
    return KitchenStripeCard(
      color: color,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: 2,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                header,
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 13.5,
                  color: AppColors.foreground,
                ),
              ),
              if (waiter != null)
                Text(
                  'Mesero: $waiter',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.mutedForeground,
                  ),
                ),
              for (final area in comanda.areaNames)
                ReportStatusTag(label: area, tone: AppColors.info),
              // El estado escrito, no solo el color de la franja.
              ReportStatusTag(
                label: kitchenChargeGroupTitle(state),
                tone: color,
              ),
            ],
          ),
          if (reason != null) ...[
            const SizedBox(height: 2),
            Text(
              reason,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ],
          if (noteLabel != null) ...[
            const SizedBox(height: 2),
            Text(
              noteLabel!,
              style: TextStyle(
                fontSize: 12,
                fontStyle: FontStyle.italic,
                color: comanda.voidNote == null
                    ? AppColors.mutedForeground
                    : AppColors.foreground,
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.sm),
          for (final i in comanda.displayItems)
            Text(
              '${_qty.format(i.quantity)} × ${i.productName}',
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.foreground,
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Aún sin cobrar (ahora mismo)
// ---------------------------------------------------------------------------

/// Lo que salió a cocina y sigue sin cobrar AHORA, sin importar el rango:
/// mesas abiertas y órdenes huérfanas (mesa cerrada con la orden viva).
class _OpenNowSection extends StatelessWidget {
  const _OpenNowSection({required this.openNow});

  final KitchenComandaReport openNow;

  @override
  Widget build(BuildContext context) {
    final accounts = openNow.openAccounts;
    final units = accounts.fold(0.0, (s, a) => s + a.units);
    final since = DateFormat('dd/MM HH:mm');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ReportSectionLabel(
          title: 'Aún sin cobrar (ahora mismo)',
          subtitle: accounts.isEmpty
              ? 'Lo que salió a cocina y todavía no se ha cobrado, sin importar '
                    'el rango.'
              : '${_qty.format(units)} productos en ${accounts.length} '
                    '${accounts.length == 1 ? 'cuenta' : 'cuentas'}, sin '
                    'importar cuándo se enviaron.',
        ),
        const SizedBox(height: AppSpacing.itemGap),
        if (accounts.isEmpty)
          const ReportSurfaceCard(
            child: ReportEmptyPlaceholder(
              icon: Icons.verified_outlined,
              message:
                  'No hay nada enviado a cocina pendiente de cobrar en este '
                  'momento.',
            ),
          )
        else
          for (final a in accounts) _OpenAccountCard(account: a, since: since),
      ],
    );
  }
}

class _OpenAccountCard extends StatelessWidget {
  const _OpenAccountCard({required this.account, required this.since});

  final KitchenAccount account;
  final DateFormat since;

  @override
  Widget build(BuildContext context) {
    final a = account;
    final color = a.isOrphan
        ? kitchenChargeStateColor(KitchenChargeState.unpaid)
        : kitchenChargeStateColor(KitchenChargeState.pending);
    final waiter = a.waiterName;
    return KitchenStripeCard(
      color: color,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                a.tableName,
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 14,
                  color: AppColors.foreground,
                ),
              ),
              ReportStatusTag(
                label: a.isOrphan
                    ? 'Mesa cerrada con la orden abierta'
                    : 'Mesa abierta',
                tone: color,
              ),
              Text(
                'Desde ${since.format(a.since)} · #${a.orderNumber}'
                '${waiter == null ? '' : ' · $waiter'}',
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.mutedForeground,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            [
              for (final i in a.displayItems)
                '${_qty.format(i.quantity)} × ${i.productName}',
            ].join(' · '),
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppColors.foreground,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '${_qty.format(a.units)} productos sin cobrar',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

/// La dirección contraria del comparador: se cobró y nunca pasó por cocina.
class _WithoutComandaSection extends StatelessWidget {
  const _WithoutComandaSection({required this.report});

  final KitchenComandaReport report;

  @override
  Widget build(BuildContext context) {
    final accounts = report.accounts;
    final units = accounts.fold(0.0, (s, a) => s + a.units);
    final at = DateFormat('dd/MM HH:mm');
    final color = kitchenChargeStateColor(KitchenChargeState.charged);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ReportSectionLabel(
          title: 'Cobrado sin comanda',
          subtitle:
              '${_qty.format(units)} productos cobrados en el rango que nunca '
              'pasaron por cocina, en ${accounts.length} '
              '${accounts.length == 1 ? 'cuenta' : 'cuentas'}.',
        ),
        const SizedBox(height: AppSpacing.itemGap),
        for (final a in accounts)
          KitchenStripeCard(
            color: color,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      a.tableName,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 14,
                        color: AppColors.foreground,
                      ),
                    ),
                    ReportStatusTag(label: 'Sin comanda', tone: color),
                    Text(
                      'Cobrado ${at.format(a.since)} · #${a.orderNumber}',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.mutedForeground,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  [
                    for (final i in a.displayItems)
                      '${_qty.format(i.quantity)} × ${i.productName}',
                  ].join(' · '),
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppColors.foreground,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Tarjeta con la franja de color a la izquierda. Borde uniforme afuera
/// (Flutter no pinta esquinas redondeadas con bordes de distinto color) y la
/// franja adentro, recortada.
class KitchenStripeCard extends StatelessWidget {
  const KitchenStripeCard({
    super.key,
    required this.color,
    required this.child,
  });

  final Color color;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(reportRadius),
        border: Border.all(color: AppColors.border),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(reportRadius - 1),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: color, width: 3)),
          ),
          child: child,
        ),
      ),
    );
  }
}
