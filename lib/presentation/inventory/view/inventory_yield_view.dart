// Rendimiento y mermas: de lo que sale del almacén, cuánto va a producción /
// ventas y cuánto se pierde — por insumo y por motivo.
//
// Pedido del dueño (2026-09-30): «qué tanto es de producción de lo que se
// compra y qué tanto es merma», con filtros por la razón de la merma, gráficos
// y buena UI. Datos de `fn_inventory_yield_analysis` (20260930_0050).
//
// Color con significado FIJO en toda la pantalla (validado para daltonismo):
// azul = producción y ventas, naranja = merma. Los motivos NO llevan un color
// cada uno: se comparan por largo de barra, con el nombre al lado.

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/currency/business_currency.dart';
import '../../../core/currency/business_currency_provider.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radius.dart';
import '../../../core/theme/app_shadows.dart';
import '../state/outflow_reasons.dart';
import '../state/yield_state.dart';
import '../viewmodel/yield_viewmodel.dart';
import 'widgets/inventory_back_button.dart';

/// Producción y ventas.
const kYieldProductionColor = Color(0xFF2A78D6);

/// Merma.
const kYieldWasteColor = Color(0xFFEB6834);

String _fmtQty(double v) {
  final s = v.toStringAsFixed(2);
  return s.replaceFirst(RegExp(r'\.?0+$'), '');
}

String _fmtPct(double? share) {
  if (share == null) return '—';
  final pct = share * 100;
  if (pct > 0 && pct < 1) return '${pct.toStringAsFixed(1)}%';
  return '${pct.toStringAsFixed(0)}%';
}

class InventoryYieldView extends ConsumerStatefulWidget {
  const InventoryYieldView({super.key});

  @override
  ConsumerState<InventoryYieldView> createState() => _InventoryYieldViewState();
}

class _InventoryYieldViewState extends ConsumerState<InventoryYieldView> {
  static const _pageSize = 50;
  int _visible = _pageSize;
  final _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => ref.read(yieldViewModelProvider).init(),
    );
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vm = ref.watch(yieldViewModelProvider);
    final state = vm.state;
    final money = currentBusinessCurrencyOrFallback(ref);

    return Scaffold(
      backgroundColor: AppColors.background,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 1100;
          final pad = constraints.maxWidth >= 700 ? 24.0 : 14.0;
          return RefreshIndicator(
            onRefresh: vm.refresh,
            child: SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.all(pad),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _header(state),
                  const SizedBox(height: 16),
                  _filters(vm, state),
                  const SizedBox(height: 20),
                  ..._body(vm, state, money, wide),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _header(YieldState state) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 2),
          child: InventoryBackButton(),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Rendimiento y mermas',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  color: AppColors.foreground,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'De lo que sale del almacén, cuánto se va a producción y '
                'ventas, y cuánto se pierde',
                style: TextStyle(
                  fontSize: 14,
                  color: AppColors.mutedForeground,
                ),
              ),
            ],
          ),
        ),
        IconButton.filledTonal(
          tooltip: 'Actualizar',
          onPressed: state.loading
              ? null
              : () => ref.read(yieldViewModelProvider).refresh(),
          icon: state.loading
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.refresh),
        ),
      ],
    );
  }

  Widget _filters(YieldViewModel vm, YieldState state) {
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SegmentedButton<int>(
          key: const Key('yield-period'),
          segments: [
            for (final d in yieldPeriods)
              ButtonSegment(value: d, label: Text('$d días')),
          ],
          selected: {state.daysBack},
          showSelectedIcon: false,
          onSelectionChanged: (v) => vm.setDaysBack(v.first),
        ),
        if (state.warehouses.length > 1)
          SizedBox(
            width: 260,
            child: DropdownButtonFormField<String?>(
              key: ValueKey('yield-wh-${state.warehouseId}'),
              isExpanded: true,
              initialValue:
                  state.warehouses.any((w) => w.id == state.warehouseId)
                  ? state.warehouseId
                  : null,
              decoration: InputDecoration(
                labelText: 'Bodega',
                isDense: true,
                filled: true,
                fillColor: AppColors.card,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.card),
                ),
              ),
              items: [
                const DropdownMenuItem<String?>(
                  value: null,
                  child: Text('Todas las bodegas'),
                ),
                for (final w in state.warehouses)
                  DropdownMenuItem<String?>(value: w.id, child: Text(w.name)),
              ],
              onChanged: state.loading ? null : vm.setWarehouse,
            ),
          ),
      ],
    );
  }

  List<Widget> _body(
    YieldViewModel vm,
    YieldState state,
    BusinessCurrency money,
    bool wide,
  ) {
    if (state.missingFunction) {
      return [
        _Notice(
          icon: Icons.construction_rounded,
          color: AppColors.warning,
          title: 'Falta habilitarlo en el servidor',
          text:
              'Aplica la migración 20260930_0050_inventory_yield_analysis.sql '
              'y vuelve a abrir esta pantalla.',
        ),
      ];
    }
    final error = state.error;
    if (error != null && state.report.isEmpty) {
      return [
        _Notice(
          icon: Icons.error_outline,
          color: AppColors.destructive,
          title: 'No se pudo cargar',
          text: error,
          action: TextButton.icon(
            onPressed: vm.refresh,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('Reintentar'),
          ),
        ),
      ];
    }
    if (state.loading && state.report.isEmpty) {
      return const [
        Padding(
          padding: EdgeInsets.symmetric(vertical: 80),
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
    }
    final report = state.report;
    if (report.isEmpty) {
      return [
        _Notice(
          icon: Icons.inventory_2_outlined,
          color: AppColors.mutedForeground,
          title: 'Sin movimientos en este período',
          text:
              'No hubo compras, consumo ni mermas en los últimos '
              '${state.daysBack} días${state.warehouseId == null ? '' : ' en esta bodega'}.',
        ),
      ];
    }

    final charts = [
      _ReasonBarsCard(
        reasons: report.byReason,
        selected: state.reasonFilter,
        money: money,
        onSelect: vm.setReason,
      ),
      _DailyWasteCard(
        daily: report.daily,
        money: money,
        filtered: state.reasonFilter != null,
      ),
    ];

    return [
      _KpiRow(
        report: report,
        money: money,
        days: state.daysBack,
        reason: state.reasonFilter,
      ),
      const SizedBox(height: 20),
      if (wide)
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: charts[0]),
            const SizedBox(width: 16),
            Expanded(child: charts[1]),
          ],
        )
      else ...[
        charts[0],
        const SizedBox(height: 16),
        charts[1],
      ],
      const SizedBox(height: 16),
      _TopItemsCard(
        items: state.visibleItems
            .where((i) => i.wasteFor(state.reasonFilter).qty > 0)
            .take(8)
            .toList(growable: false),
        reason: state.reasonFilter,
        money: money,
        onOpen: (item) => _openItem(item, money),
      ),
      const SizedBox(height: 16),
      _itemsTable(vm, state, money, wide),
    ];
  }

  Widget _itemsTable(
    YieldViewModel vm,
    YieldState state,
    BusinessCurrency money,
    bool wide,
  ) {
    final items = state.visibleItems;
    final shown = items.take(_visible).toList(growable: false);
    final reason = state.reasonFilter;

    return _Card(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _CardTitle(
                  'Detalle por insumo',
                  subtitle: reason == null
                      ? 'Toca un insumo para ver de dónde sale su merma.'
                      : 'Solo la merma por «${outflowReasonByCode(reason).label}».',
                ),
                const SizedBox(height: 12),
                _ReasonChips(
                  reasons: state.report.byReason,
                  selected: reason,
                  onSelect: vm.setReason,
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    SizedBox(
                      width: 300,
                      child: TextField(
                        key: const Key('yield-search'),
                        controller: _searchCtrl,
                        onChanged: (v) {
                          setState(() => _visible = _pageSize);
                          vm.setSearch(v);
                        },
                        decoration: InputDecoration(
                          isDense: true,
                          hintText: 'Buscar insumo o SKU',
                          prefixIcon: const Icon(Icons.search),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(AppRadius.card),
                          ),
                        ),
                      ),
                    ),
                    DropdownButton<YieldSort>(
                      value: state.sort,
                      underline: const SizedBox.shrink(),
                      items: const [
                        DropdownMenuItem(
                          value: YieldSort.wasteValue,
                          child: Text('Más merma (RD\$)'),
                        ),
                        DropdownMenuItem(
                          value: YieldSort.wasteShare,
                          child: Text('Mayor % de merma'),
                        ),
                        DropdownMenuItem(
                          value: YieldSort.consumedValue,
                          child: Text('Más consumo'),
                        ),
                        DropdownMenuItem(
                          value: YieldSort.name,
                          child: Text('Nombre'),
                        ),
                      ],
                      onChanged: (v) {
                        if (v != null) vm.setSort(v);
                      },
                    ),
                    Text(
                      '${items.length} ${items.length == 1 ? 'insumo' : 'insumos'}',
                      style: TextStyle(
                        fontSize: 13,
                        color: AppColors.mutedForeground,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.all(28),
              child: Center(
                child: Text(
                  'Ningún insumo coincide.',
                  style: TextStyle(color: AppColors.mutedForeground),
                ),
              ),
            )
          else ...[
            if (wide) const _TableHeader(),
            for (final item in shown)
              _ItemRow(
                item: item,
                reason: reason,
                money: money,
                wide: wide,
                onTap: () => _openItem(item, money),
              ),
            if (items.length > shown.length)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Center(
                  child: TextButton.icon(
                    onPressed: () => setState(() => _visible += _pageSize),
                    icon: const Icon(Icons.expand_more),
                    label: Text(
                      'Ver más (${items.length - shown.length} restantes)',
                    ),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  void _openItem(YieldItem item, BusinessCurrency money) {
    showDialog<void>(
      context: context,
      builder: (_) => YieldItemDialog(
        item: item,
        money: money,
        days: ref.read(yieldViewModelProvider).state.daysBack,
      ),
    );
  }
}

// ── Piezas ─────────────────────────────────────────────────────────────────

class _Card extends StatelessWidget {
  const _Card({required this.child, this.padding});

  final Widget child;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding ?? const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.border),
        boxShadow: AppShadows.cardElevated,
      ),
      child: child,
    );
  }
}

class _CardTitle extends StatelessWidget {
  const _CardTitle(this.title, {this.subtitle});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w800,
            color: AppColors.foreground,
          ),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 3),
          Text(
            subtitle!,
            style: TextStyle(fontSize: 13, color: AppColors.mutedForeground),
          ),
        ],
      ],
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({
    required this.icon,
    required this.color,
    required this.title,
    required this.text,
    this.action,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return _Card(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 28),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: AppColors.foreground,
                  ),
                ),
                const SizedBox(height: 4),
                Text(text, style: TextStyle(color: AppColors.mutedForeground)),
                if (action != null) ...[const SizedBox(height: 8), action!],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Punto de color + texto: la leyenda de la pantalla.
class _Swatch extends StatelessWidget {
  const _Swatch(this.color, this.label);

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(fontSize: 12, color: AppColors.mutedForeground),
        ),
      ],
    );
  }
}

/// Barra 100% apilada: producción (azul) | merma (naranja), con 2 px de
/// separación entre los dos tramos.
class YieldSplitBar extends StatelessWidget {
  const YieldSplitBar({super.key, required this.wasteShare, this.height = 10});

  /// Fracción de merma (0–1). `null` = no salió nada: barra vacía.
  final double? wasteShare;
  final double height;

  @override
  Widget build(BuildContext context) {
    final share = wasteShare;
    // Flex en milésimas en vez de LayoutBuilder: así la barra también sirve
    // dentro de IntrinsicHeight (los indicadores se igualan en altura).
    final waste = share == null ? 0 : (share.clamp(0.0, 1.0) * 1000).round();
    final production = share == null ? 0 : 1000 - waste;
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        height: height,
        child: share == null
            ? Container(color: AppColors.muted)
            : Row(
                children: [
                  if (production > 0)
                    Expanded(
                      flex: production,
                      child: Container(color: kYieldProductionColor),
                    ),
                  if (production > 0 && waste > 0) const SizedBox(width: 2),
                  if (waste > 0)
                    Expanded(
                      flex: waste,
                      child: Container(color: kYieldWasteColor),
                    ),
                ],
              ),
      ),
    );
  }
}

// ── Indicadores ────────────────────────────────────────────────────────────

class _KpiRow extends StatelessWidget {
  const _KpiRow({
    required this.report,
    required this.money,
    required this.days,
    this.reason,
  });

  final YieldReport report;
  final BusinessCurrency money;
  final int days;

  /// Motivo filtrado: la tarjeta de Merma dice cuánto es de ese motivo.
  final String? reason;

  @override
  Widget build(BuildContext context) {
    final wasteShare = report.wasteShare;
    final yieldShare = wasteShare == null ? null : 1 - wasteShare;
    final perHundred = wasteShare == null ? null : wasteShare * 100;
    final adjust = report.countAdjustValue;
    final reasonCode = reason;
    YieldReasonTotal? reasonTotal;
    if (reasonCode != null) {
      for (final r in report.byReason) {
        if (r.reason == reasonCode) reasonTotal = r;
      }
    }

    final hero = _HeroTile(
      yieldShare: yieldShare,
      wasteShare: wasteShare,
      caption: perHundred == null
          ? 'Todavía no salió nada del almacén en este período.'
          : 'De cada ${money.formatAmount(100)} que salen del almacén, '
                '${money.formatAmount(perHundred)} se pierden en merma.',
    );
    final tiles = <Widget>[
      _KpiTile(
        label: 'Comprado',
        value: money.formatAmount(report.purchasedValue),
        caption: 'Neto de compras corregidas o anuladas · $days días',
        icon: Icons.shopping_cart_outlined,
      ),
      _KpiTile(
        label: 'Producción y ventas',
        value: money.formatAmount(report.consumedValue),
        caption: '${_fmtPct(yieldShare)} de lo que salió',
        swatch: kYieldProductionColor,
      ),
      _KpiTile(
        key: const Key('yield-kpi-waste'),
        label: 'Merma',
        value: money.formatAmount(report.wasteValue),
        caption: reasonCode == null
            ? '${_fmtPct(wasteShare)} de lo que salió'
            : '«${outflowReasonByCode(reasonCode).label}»: '
                  '${money.formatAmount(reasonTotal?.value ?? 0)}',
        swatch: kYieldWasteColor,
      ),
      if (adjust.abs() >= 0.01)
        _KpiTile(
          label: 'Diferencias de conteo',
          value: money.formatAmount(adjust),
          caption: adjust < 0
              ? 'Faltó en el conteo sin motivo declarado'
              : 'Sobró en el conteo',
          icon: Icons.fact_check_outlined,
        ),
    ];

    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth;
        const gap = 14.0;
        if (w >= 1100) {
          // Una fila, todas de la misma altura.
          return IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(flex: 3, child: hero),
                for (final t in tiles) ...[
                  const SizedBox(width: gap),
                  Expanded(flex: 2, child: t),
                ],
              ],
            ),
          );
        }
        final cols = w >= 700 ? 3 : 2;
        final tileWidth = (w - gap * (cols - 1)) / cols;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            SizedBox(width: w, child: hero),
            for (final t in tiles) SizedBox(width: tileWidth, child: t),
          ],
        );
      },
    );
  }
}

class _HeroTile extends StatelessWidget {
  const _HeroTile({
    required this.yieldShare,
    required this.wasteShare,
    required this.caption,
  });

  final double? yieldShare;
  final double? wasteShare;
  final String caption;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('yield-hero'),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.border),
        boxShadow: AppShadows.cardElevated,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Rendimiento',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: AppColors.mutedForeground,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            _fmtPct(yieldShare),
            style: TextStyle(
              fontSize: 48,
              height: 1,
              fontWeight: FontWeight.w800,
              color: AppColors.foreground,
            ),
          ),
          const SizedBox(height: 12),
          YieldSplitBar(wasteShare: wasteShare, height: 12),
          const SizedBox(height: 8),
          const Wrap(
            spacing: 14,
            children: [
              _Swatch(kYieldProductionColor, 'Producción y ventas'),
              _Swatch(kYieldWasteColor, 'Merma'),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            caption,
            style: TextStyle(fontSize: 12.5, color: AppColors.mutedForeground),
          ),
        ],
      ),
    );
  }
}

class _KpiTile extends StatelessWidget {
  const _KpiTile({
    super.key,
    required this.label,
    required this.value,
    required this.caption,
    this.icon,
    this.swatch,
  });

  final String label;
  final String value;
  final String caption;
  final IconData? icon;
  final Color? swatch;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 132),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.border),
        boxShadow: AppShadows.cardElevated,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (swatch != null)
                Container(
                  width: 10,
                  height: 10,
                  margin: const EdgeInsets.only(right: 8),
                  decoration: BoxDecoration(
                    color: swatch,
                    borderRadius: BorderRadius.circular(3),
                  ),
                )
              else if (icon != null) ...[
                Icon(icon, size: 16, color: AppColors.mutedForeground),
                const SizedBox(width: 6),
              ],
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: AppColors.mutedForeground,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w800,
                color: AppColors.foreground,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            caption,
            style: TextStyle(fontSize: 12, color: AppColors.mutedForeground),
          ),
        ],
      ),
    );
  }
}

// ── Merma por motivo ───────────────────────────────────────────────────────

class _ReasonBarsCard extends StatelessWidget {
  const _ReasonBarsCard({
    required this.reasons,
    required this.selected,
    required this.money,
    required this.onSelect,
  });

  final List<YieldReasonTotal> reasons;
  final String? selected;
  final BusinessCurrency money;
  final ValueChanged<String?> onSelect;

  @override
  Widget build(BuildContext context) {
    final total = reasons.fold<double>(0, (s, r) => s + r.value);
    final max = reasons.fold<double>(0, (m, r) => r.value > m ? r.value : m);

    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _CardTitle(
            'Merma por motivo',
            subtitle: 'Toca un motivo para filtrar todo por él.',
          ),
          const SizedBox(height: 16),
          if (reasons.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Text(
                  'Sin mermas en este período. 👏',
                  style: TextStyle(color: AppColors.mutedForeground),
                ),
              ),
            )
          else
            for (final r in reasons)
              _ReasonBar(
                total: r,
                share: total <= 0 ? 0 : r.value / total,
                fraction: max <= 0 ? 0 : r.value / max,
                dimmed: selected != null && selected != r.reason,
                selected: selected == r.reason,
                money: money,
                onTap: () => onSelect(r.reason),
              ),
        ],
      ),
    );
  }
}

class _ReasonBar extends StatelessWidget {
  const _ReasonBar({
    required this.total,
    required this.share,
    required this.fraction,
    required this.dimmed,
    required this.selected,
    required this.money,
    required this.onTap,
  });

  final YieldReasonTotal total;
  final double share;
  final double fraction;
  final bool dimmed;
  final bool selected;
  final BusinessCurrency money;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final info = total.info;
    return Tooltip(
      message:
          '${info.label}: ${money.formatAmount(total.value)} · '
          '${total.count} ${total.count == 1 ? 'salida' : 'salidas'}',
      child: InkWell(
        key: ValueKey('yield-reason-${total.reason}'),
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 180),
          opacity: dimmed ? 0.35 : 1,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 6),
            decoration: selected
                ? BoxDecoration(
                    color: kYieldWasteColor.withValues(alpha: 0.07),
                    borderRadius: BorderRadius.circular(8),
                  )
                : null,
            child: LayoutBuilder(
              builder: (context, c) {
                final icon = Icon(
                  info.icon,
                  size: 18,
                  color: AppColors.mutedForeground,
                );
                final label = Text(
                  info.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppColors.foreground,
                  ),
                );
                final bar = Align(
                  alignment: Alignment.centerLeft,
                  child: FractionallySizedBox(
                    widthFactor: fraction.clamp(0.02, 1.0),
                    child: Container(
                      height: 14,
                      decoration: const BoxDecoration(
                        color: kYieldWasteColor,
                        borderRadius: BorderRadius.horizontal(
                          right: Radius.circular(4),
                        ),
                      ),
                    ),
                  ),
                );
                final value = Text(
                  '${money.formatAmount(total.value)} · ${_fmtPct(share)}',
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: AppColors.foreground,
                  ),
                );
                // Angosto (teléfono): motivo y valor arriba, barra abajo.
                if (c.maxWidth < 420) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          icon,
                          const SizedBox(width: 8),
                          Expanded(child: label),
                          const SizedBox(width: 8),
                          value,
                        ],
                      ),
                      const SizedBox(height: 6),
                      bar,
                    ],
                  );
                }
                return Row(
                  children: [
                    icon,
                    const SizedBox(width: 8),
                    SizedBox(width: 150, child: label),
                    Expanded(child: bar),
                    const SizedBox(width: 10),
                    SizedBox(width: 118, child: value),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

// ── Merma por día ──────────────────────────────────────────────────────────

class _DailyWasteCard extends StatelessWidget {
  const _DailyWasteCard({
    required this.daily,
    required this.money,
    this.filtered = false,
  });

  final List<YieldDay> daily;
  final BusinessCurrency money;

  /// Hay un motivo elegido: esta tendencia sigue siendo de TODA la merma.
  final bool filtered;

  @override
  Widget build(BuildContext context) {
    final dayFmt = DateFormat('dd/MM');
    final maxY = daily.fold<double>(
      0,
      (m, d) => d.wasteValue > m ? d.wasteValue : m,
    );
    final top = maxY <= 0 ? 1.0 : maxY * 1.15;
    final every = daily.length <= 7 ? 1 : (daily.length / 6).ceil();

    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _CardTitle(
            'Merma por día',
            subtitle: filtered
                ? 'Toda la merma, de todos los motivos. Pasa el mouse o toca '
                      'un día para ver el detalle.'
                : 'Pasa el mouse o toca un día para ver el detalle.',
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 220,
            child: daily.isEmpty
                ? const SizedBox.shrink()
                : LineChart(
                    LineChartData(
                      minX: 0,
                      maxX: (daily.length - 1).toDouble(),
                      minY: 0,
                      maxY: top,
                      gridData: FlGridData(
                        show: true,
                        drawVerticalLine: false,
                        getDrawingHorizontalLine: (_) => FlLine(
                          color: AppColors.border.withValues(alpha: 0.6),
                          strokeWidth: 1,
                        ),
                      ),
                      borderData: FlBorderData(show: false),
                      titlesData: FlTitlesData(
                        topTitles: const AxisTitles(
                          sideTitles: SideTitles(showTitles: false),
                        ),
                        rightTitles: const AxisTitles(
                          sideTitles: SideTitles(showTitles: false),
                        ),
                        leftTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 44,
                            getTitlesWidget: (value, meta) {
                              if (value == meta.max) {
                                return const SizedBox.shrink();
                              }
                              return Text(
                                NumberFormat.compact().format(value),
                                style: TextStyle(
                                  fontSize: 10,
                                  color: AppColors.mutedForeground,
                                ),
                              );
                            },
                          ),
                        ),
                        bottomTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            interval: 1,
                            reservedSize: 24,
                            getTitlesWidget: (value, meta) {
                              final i = value.round();
                              if (i < 0 ||
                                  i >= daily.length ||
                                  value != i.toDouble()) {
                                return const SizedBox.shrink();
                              }
                              final isLast = i == daily.length - 1;
                              if (i % every != 0 && !isLast) {
                                return const SizedBox.shrink();
                              }
                              return Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: Text(
                                  dayFmt.format(daily[i].day),
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: AppColors.mutedForeground,
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                      lineTouchData: LineTouchData(
                        handleBuiltInTouches: true,
                        getTouchedSpotIndicator: (bar, indexes) => [
                          for (final _ in indexes)
                            TouchedSpotIndicatorData(
                              FlLine(
                                color: AppColors.mutedForeground.withValues(
                                  alpha: 0.4,
                                ),
                                strokeWidth: 1,
                              ),
                              FlDotData(
                                getDotPainter: (spot, _, _, _) =>
                                    FlDotCirclePainter(
                                      radius: 5,
                                      color: kYieldWasteColor,
                                      strokeWidth: 2,
                                      strokeColor: Colors.white,
                                    ),
                              ),
                            ),
                        ],
                        touchTooltipData: LineTouchTooltipData(
                          getTooltipColor: (_) => AppColors.foreground,
                          getTooltipItems: (spots) => [
                            for (final s in spots)
                              LineTooltipItem(
                                '${DateFormat('EEE d MMM', 'es_DO').format(daily[s.x.round()].day)}\n',
                                const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 11,
                                ),
                                children: [
                                  TextSpan(
                                    text:
                                        'Merma ${money.formatAmount(daily[s.x.round()].wasteValue)}\n',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w700,
                                      fontSize: 12,
                                    ),
                                  ),
                                  TextSpan(
                                    text:
                                        'Producción y ventas ${money.formatAmount(daily[s.x.round()].consumedValue)}',
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ),
                          ],
                        ),
                      ),
                      lineBarsData: [
                        LineChartBarData(
                          spots: [
                            for (var i = 0; i < daily.length; i++)
                              FlSpot(i.toDouble(), daily[i].wasteValue),
                          ],
                          isCurved: false,
                          color: kYieldWasteColor,
                          barWidth: 2,
                          dotData: FlDotData(show: daily.length <= 14),
                          belowBarData: BarAreaData(
                            show: true,
                            color: kYieldWasteColor.withValues(alpha: 0.12),
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

// ── Insumos con más merma ──────────────────────────────────────────────────

class _TopItemsCard extends StatelessWidget {
  const _TopItemsCard({
    required this.items,
    required this.reason,
    required this.money,
    required this.onOpen,
  });

  final List<YieldItem> items;
  final String? reason;
  final BusinessCurrency money;
  final ValueChanged<YieldItem> onOpen;

  @override
  Widget build(BuildContext context) {
    const legend = Wrap(
      spacing: 14,
      runSpacing: 6,
      children: [
        _Swatch(kYieldProductionColor, 'Producción y ventas'),
        _Swatch(kYieldWasteColor, 'Merma'),
      ],
    );
    final title = _CardTitle(
      'Insumos con más merma',
      subtitle: reason == null
          ? 'De lo que salió de cada uno, cuánto fue producción y cuánto merma.'
          : 'Merma por «${outflowReasonByCode(reason!).label}».',
    );

    return _Card(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final narrow = constraints.maxWidth < 560;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (narrow) ...[
                title,
                const SizedBox(height: 10),
                legend,
              ] else
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: title),
                    const SizedBox(width: 12),
                    legend,
                  ],
                ),
              const SizedBox(height: 14),
              if (items.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  child: Center(
                    child: Text(
                      'Ningún insumo tuvo merma en este período.',
                      style: TextStyle(color: AppColors.mutedForeground),
                    ),
                  ),
                )
              else
                for (final item in items) _row(item, narrow),
            ],
          );
        },
      ),
    );
  }

  Widget _row(YieldItem item, bool narrow) {
    final waste = item.wasteFor(reason);
    final share = item.wasteShare(reason: reason);
    final nameText = Text(
      item.name,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: AppColors.foreground,
      ),
    );
    final valueText = Text(
      '${_fmtPct(share)} merma · ${money.formatAmount(waste.value)}',
      textAlign: TextAlign.right,
      style: TextStyle(
        fontSize: 12.5,
        fontWeight: FontWeight.w700,
        color: AppColors.foreground,
      ),
    );
    final bar = Tooltip(
      message:
          'Producción y ventas ${_fmtQty(item.consumedQty)} ${item.unit} · '
          'Merma ${_fmtQty(waste.qty)} ${item.unit}',
      child: YieldSplitBar(wasteShare: share, height: 14),
    );

    return InkWell(
      key: ValueKey('yield-top-${item.itemId}'),
      borderRadius: BorderRadius.circular(8),
      onTap: () => onOpen(item),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: narrow
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(child: nameText),
                      const SizedBox(width: 8),
                      valueText,
                    ],
                  ),
                  const SizedBox(height: 6),
                  bar,
                ],
              )
            : Row(
                children: [
                  SizedBox(width: 190, child: nameText),
                  Expanded(child: bar),
                  const SizedBox(width: 12),
                  SizedBox(width: 160, child: valueText),
                ],
              ),
      ),
    );
  }
}

// ── Filtro por motivo ──────────────────────────────────────────────────────

class _ReasonChips extends StatelessWidget {
  const _ReasonChips({
    required this.reasons,
    required this.selected,
    required this.onSelect,
  });

  final List<YieldReasonTotal> reasons;
  final String? selected;
  final ValueChanged<String?> onSelect;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        ChoiceChip(
          key: const Key('yield-chip-all'),
          label: const Text('Todos los motivos'),
          selected: selected == null,
          onSelected: (_) => onSelect(null),
        ),
        for (final r in reasons)
          ChoiceChip(
            key: ValueKey('yield-chip-${r.reason}'),
            avatar: Icon(r.info.icon, size: 16),
            label: Text('${r.info.label} · ${r.count}'),
            selected: selected == r.reason,
            onSelected: (_) => onSelect(r.reason),
          ),
      ],
    );
  }
}

// ── Tabla ──────────────────────────────────────────────────────────────────

class _TableHeader extends StatelessWidget {
  const _TableHeader();

  @override
  Widget build(BuildContext context) {
    TextStyle style() => TextStyle(
      fontSize: 11.5,
      fontWeight: FontWeight.w800,
      letterSpacing: 0.3,
      color: AppColors.mutedForeground,
    );
    return Container(
      color: AppColors.background,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      child: Row(
        children: [
          Expanded(flex: 4, child: Text('INSUMO', style: style())),
          Expanded(
            flex: 2,
            child: Text('COMPRADO', textAlign: TextAlign.right, style: style()),
          ),
          Expanded(
            flex: 2,
            child: Text(
              'PRODUCCIÓN',
              textAlign: TextAlign.right,
              style: style(),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text('MERMA', textAlign: TextAlign.right, style: style()),
          ),
          const SizedBox(width: 20),
          Expanded(flex: 3, child: Text('RENDIMIENTO', style: style())),
          Expanded(
            flex: 2,
            child: Text(
              'COSTO MERMA',
              textAlign: TextAlign.right,
              style: style(),
            ),
          ),
        ],
      ),
    );
  }
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({
    required this.item,
    required this.reason,
    required this.money,
    required this.wide,
    required this.onTap,
  });

  final YieldItem item;
  final String? reason;
  final BusinessCurrency money;
  final bool wide;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final waste = item.wasteFor(reason);
    final share = item.wasteShare(reason: reason);
    final unit = item.unit.isEmpty ? '' : ' ${item.unit}';
    final bold = TextStyle(
      fontSize: 13.5,
      fontWeight: FontWeight.w700,
      color: AppColors.foreground,
    );
    final normal = TextStyle(fontSize: 13.5, color: AppColors.foreground);

    final name = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          item.name,
          style: bold,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        if (item.sku.isNotEmpty)
          Text(
            item.sku,
            style: TextStyle(fontSize: 12, color: AppColors.mutedForeground),
          ),
      ],
    );

    final child = wide
        ? Row(
            children: [
              Expanded(flex: 4, child: name),
              Expanded(
                flex: 2,
                child: Text(
                  '${_fmtQty(item.purchasedQty)}$unit',
                  textAlign: TextAlign.right,
                  style: normal,
                ),
              ),
              Expanded(
                flex: 2,
                child: Text(
                  '${_fmtQty(item.consumedQty)}$unit',
                  textAlign: TextAlign.right,
                  style: normal,
                ),
              ),
              Expanded(
                flex: 2,
                child: Text(
                  '${_fmtQty(waste.qty)}$unit',
                  textAlign: TextAlign.right,
                  style: waste.qty > 0 ? bold : normal,
                ),
              ),
              const SizedBox(width: 20),
              Expanded(
                flex: 3,
                child: Row(
                  children: [
                    Expanded(child: YieldSplitBar(wasteShare: share)),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 44,
                      child: Text(
                        share == null ? '—' : _fmtPct(1 - share),
                        style: bold,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                flex: 2,
                child: Text(
                  money.formatAmount(waste.value),
                  textAlign: TextAlign.right,
                  style: waste.value > 0 ? bold : normal,
                ),
              ),
            ],
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(child: name),
                  Text(money.formatAmount(waste.value), style: bold),
                ],
              ),
              const SizedBox(height: 8),
              YieldSplitBar(wasteShare: share),
              const SizedBox(height: 6),
              Text(
                'Comprado ${_fmtQty(item.purchasedQty)}$unit · '
                'Producción ${_fmtQty(item.consumedQty)}$unit · '
                'Merma ${_fmtQty(waste.qty)}$unit · '
                'Rinde ${share == null ? '—' : _fmtPct(1 - share)}',
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.mutedForeground,
                ),
              ),
            ],
          );

    return InkWell(
      key: ValueKey('yield-row-${item.itemId}'),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: AppColors.border)),
        ),
        child: child,
      ),
    );
  }
}

// ── Ficha del insumo ───────────────────────────────────────────────────────

class YieldItemDialog extends StatelessWidget {
  const YieldItemDialog({
    super.key,
    required this.item,
    required this.money,
    required this.days,
  });

  final YieldItem item;
  final BusinessCurrency money;
  final int days;

  @override
  Widget build(BuildContext context) {
    final unit = item.unit.isEmpty ? '' : ' ${item.unit}';
    final share = item.wasteShare();
    final reasons = item.wasteByReason.entries.toList()
      ..sort((a, b) => b.value.value.compareTo(a.value.value));
    final maxValue = reasons.isEmpty ? 0.0 : reasons.first.value.value;

    Widget metric(String label, String value, {Color? swatch, String? hint}) {
      return SizedBox(
        width: 160,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (swatch != null)
                  Container(
                    width: 9,
                    height: 9,
                    margin: const EdgeInsets.only(right: 6),
                    decoration: BoxDecoration(
                      color: swatch,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                Flexible(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.mutedForeground,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 3),
            Text(
              value,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
                color: AppColors.foreground,
              ),
            ),
            if (hint != null)
              Text(
                hint,
                style: TextStyle(
                  fontSize: 11.5,
                  color: AppColors.mutedForeground,
                ),
              ),
          ],
        ),
      );
    }

    return AlertDialog(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(item.name),
          const SizedBox(height: 4),
          Text(
            [
              if (item.sku.isNotEmpty) item.sku,
              'Últimos $days días',
              'Existencia ${_fmtQty(item.currentStock)}$unit',
            ].join(' · '),
            style: TextStyle(fontSize: 13, color: AppColors.mutedForeground),
          ),
        ],
      ),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    share == null ? '—' : _fmtPct(1 - share),
                    style: TextStyle(
                      fontSize: 36,
                      height: 1,
                      fontWeight: FontWeight.w800,
                      color: AppColors.foreground,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      'de rendimiento',
                      style: TextStyle(color: AppColors.mutedForeground),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              YieldSplitBar(wasteShare: share, height: 12),
              const SizedBox(height: 18),
              Wrap(
                spacing: 16,
                runSpacing: 16,
                children: [
                  metric(
                    'Comprado',
                    '${_fmtQty(item.purchasedQty)}$unit',
                    hint: money.formatAmount(item.purchasedValue),
                  ),
                  metric(
                    'Producción y ventas',
                    '${_fmtQty(item.consumedQty)}$unit',
                    swatch: kYieldProductionColor,
                    hint: money.formatAmount(item.consumedValue),
                  ),
                  metric(
                    'Merma',
                    '${_fmtQty(item.wasteQty)}$unit',
                    swatch: kYieldWasteColor,
                    hint: money.formatAmount(item.wasteValue),
                  ),
                  if (item.producedQty != 0)
                    metric('Producido', '${_fmtQty(item.producedQty)}$unit'),
                  if (item.countAdjustQty != 0)
                    metric(
                      'Diferencia de conteo',
                      '${_fmtQty(item.countAdjustQty)}$unit',
                      hint: money.formatAmount(item.countAdjustValue),
                    ),
                  if (item.purchasedQty > 0)
                    metric(
                      'Merma sobre lo comprado',
                      _fmtPct(
                        (item.wasteQty / item.purchasedQty)
                            .clamp(0, 1)
                            .toDouble(),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 20),
              Text(
                'Merma por motivo',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                  color: AppColors.foreground,
                ),
              ),
              const SizedBox(height: 8),
              if (reasons.isEmpty)
                Text(
                  'Sin mermas en este período.',
                  style: TextStyle(color: AppColors.mutedForeground),
                )
              else
                for (final e in reasons)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Row(
                      children: [
                        Icon(
                          outflowReasonByCode(e.key).icon,
                          size: 16,
                          color: AppColors.mutedForeground,
                        ),
                        const SizedBox(width: 6),
                        SizedBox(
                          width: 140,
                          child: Text(
                            outflowReasonByCode(e.key).label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                        Expanded(
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: FractionallySizedBox(
                              widthFactor: maxValue <= 0
                                  ? 0.02
                                  : (e.value.value / maxValue).clamp(0.02, 1.0),
                              child: Container(
                                height: 10,
                                decoration: const BoxDecoration(
                                  color: kYieldWasteColor,
                                  borderRadius: BorderRadius.horizontal(
                                    right: Radius.circular(4),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 150,
                          child: Text(
                            '${_fmtQty(e.value.qty)}$unit · '
                            '${money.formatAmount(e.value.value)}',
                            textAlign: TextAlign.right,
                            style: const TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              const SizedBox(height: 14),
              Text(
                'Rendimiento = producción y ventas ÷ (producción y ventas + '
                'merma). Las diferencias de conteo sin motivo no entran: si '
                'faltó mercancía y no se registró por qué, regístrala como '
                'salida con su motivo.',
                style: TextStyle(
                  fontSize: 11.5,
                  color: AppColors.mutedForeground,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cerrar'),
        ),
      ],
    );
  }
}
