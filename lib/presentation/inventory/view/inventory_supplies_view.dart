// Gastables y menaje: lo que el negocio compra y NO vende.
//
// Pedido del dueño (2026-09-30): «materiales gastables y activos fijos, como
// papel higiénico, cristalería, artículos de cocina». Dos pestañas porque son
// dos preguntas distintas:
//   · Gastables: cuánto se USA, en qué área y para cuántos días alcanza.
//   · Menaje: cuántas piezas HAY contra el par, y cuántas se rompen o se
//     pierden.
// Los equipos (horno, nevera) no van aquí: son activos fijos, uno por uno.
//
// Datos de `fn_inventory_supplies_overview` (20260930_0051). Colores con el
// mismo significado que en Rendimiento: azul = se usó, naranja = se perdió.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/routes.dart';
import '../../../core/currency/business_currency.dart';
import '../../../core/currency/business_currency_provider.dart';
import '../../../core/inventory/item_classification.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radius.dart';
import '../../../core/theme/app_shadows.dart';
import '../../../core/utils/app_toast.dart';
import '../../../services/session/session_controller.dart';
import '../state/supplies_state.dart';
import '../viewmodel/supplies_viewmodel.dart';
import 'inventory_yield_view.dart' show kYieldProductionColor, kYieldWasteColor;
import 'widgets/inventory_back_button.dart';
import 'widgets/supplies_classify_dialog.dart';

String _fmtQty(double v) {
  final s = v.toStringAsFixed(2);
  return s.replaceFirst(RegExp(r'\.?0+$'), '');
}

String _qtyUnit(double v, String unit) =>
    unit.trim().isEmpty ? _fmtQty(v) : '${_fmtQty(v)} ${unit.trim()}';

String _fmtDays(double? days) {
  if (days == null) return '—';
  if (days < 1) return 'menos de 1 día';
  final d = days.floor();
  return d == 1 ? '1 día' : '$d días';
}

class InventorySuppliesView extends ConsumerStatefulWidget {
  const InventorySuppliesView({super.key});

  @override
  ConsumerState<InventorySuppliesView> createState() =>
      _InventorySuppliesViewState();
}

class _InventorySuppliesViewState extends ConsumerState<InventorySuppliesView> {
  final _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => ref.read(suppliesViewModelProvider).init(),
    );
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vm = ref.watch(suppliesViewModelProvider);
    final state = vm.state;
    final money = currentBusinessCurrencyOrFallback(ref);
    final session = ref.watch(sessionProvider.notifier);
    ref.watch(sessionProvider);
    // Clasificar es editar el insumo; registrar una salida es un ajuste. Los
    // mismos permisos que Insumos y Salidas / Mermas.
    final canClassify = session.hasPermission(
      'inventario.productos.crear_editar',
    );
    final canOutflow = session.hasPermission('inventario.ajustes.crear');

    return Scaffold(
      backgroundColor: AppColors.background,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth;
          final pad = w >= 700 ? 24.0 : 14.0;
          return RefreshIndicator(
            onRefresh: vm.refresh,
            child: SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.all(pad),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _header(state),
                  const SizedBox(height: 12),
                  _actions(
                    state,
                    canClassify: canClassify,
                    canOutflow: canOutflow,
                  ),
                  const SizedBox(height: 18),
                  _tabs(vm, state),
                  const SizedBox(height: 14),
                  _filters(vm, state),
                  const SizedBox(height: 20),
                  ..._body(vm, state, money, w, canClassify: canClassify),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _header(SuppliesState state) {
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
                'Gastables y menaje',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  color: AppColors.foreground,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Lo que el negocio compra y no vende: cuánto se usa, dónde, '
                'y qué hay que reponer',
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
              : () => ref.read(suppliesViewModelProvider).refresh(),
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

  Widget _actions(
    SuppliesState state, {
    required bool canClassify,
    required bool canOutflow,
  }) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        FilledButton.icon(
          key: const Key('supplies-classify'),
          onPressed: !canClassify || state.businessId == null
              ? null
              : () => _openClassify(state.tab),
          icon: const Icon(Icons.playlist_add_check_rounded, size: 18),
          label: const Text('Clasificar artículos'),
        ),
        OutlinedButton.icon(
          key: const Key('supplies-register-outflow'),
          onPressed: canOutflow
              ? () => context.push(AppRoutes.inventoryOutflow)
              : null,
          icon: const Icon(Icons.outbox_outlined, size: 18),
          label: Text(
            state.tab == SuppliesTab.smallware
                ? 'Registrar rotura o pérdida'
                : 'Registrar consumo',
          ),
        ),
      ],
    );
  }

  Widget _tabs(SuppliesViewModel vm, SuppliesState state) {
    final report = state.report;
    return SegmentedButton<SuppliesTab>(
      key: const Key('supplies-tabs'),
      segments: [
        ButtonSegment(
          value: SuppliesTab.supplies,
          icon: const Icon(Icons.soap_outlined, size: 18),
          label: Text('Gastables · ${report.supplies.length}'),
        ),
        ButtonSegment(
          value: SuppliesTab.smallware,
          icon: const Icon(Icons.wine_bar_outlined, size: 18),
          label: Text('Menaje · ${report.smallware.length}'),
        ),
      ],
      selected: {state.tab},
      showSelectedIcon: false,
      onSelectionChanged: (v) => vm.setTab(v.first),
    );
  }

  Widget _filters(SuppliesViewModel vm, SuppliesState state) {
    final attention = state.attentionCount;
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SegmentedButton<int>(
          key: const Key('supplies-period'),
          segments: [
            for (final d in suppliesPeriods)
              ButtonSegment(value: d, label: Text('$d días')),
          ],
          selected: {state.daysBack},
          showSelectedIcon: false,
          onSelectionChanged: (v) => vm.setDaysBack(v.first),
        ),
        if (state.warehouses.length > 1)
          SizedBox(
            width: 240,
            child: DropdownButtonFormField<String?>(
              key: ValueKey('supplies-wh-${state.warehouseId}'),
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
        SizedBox(
          width: 240,
          child: TextField(
            key: const Key('supplies-search'),
            controller: _searchCtrl,
            onChanged: vm.setSearch,
            decoration: InputDecoration(
              isDense: true,
              filled: true,
              fillColor: AppColors.card,
              prefixIcon: const Icon(Icons.search_rounded, size: 20),
              hintText: 'Buscar artículo',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.card),
              ),
            ),
          ),
        ),
        FilterChip(
          key: const Key('supplies-only-attention'),
          label: Text(
            attention == 0 ? 'Por reponer' : 'Por reponer · $attention',
          ),
          selected: state.onlyAttention,
          onSelected: (_) => vm.toggleAttention(),
        ),
      ],
    );
  }

  List<Widget> _body(
    SuppliesViewModel vm,
    SuppliesState state,
    BusinessCurrency money,
    double width, {
    required bool canClassify,
  }) {
    if (state.missingFunction) {
      return const [
        _Notice(
          icon: Icons.construction_rounded,
          color: AppColors.warning,
          title: 'Falta habilitarlo en el servidor',
          text:
              'Aplica la migración 20260930_0051_supplies_and_smallware.sql y '
              'vuelve a abrir esta pantalla.',
        ),
      ];
    }
    final error = state.error;
    if (error != null && state.report.items.isEmpty) {
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
    if (state.loading && state.report.items.isEmpty) {
      return const [
        Padding(
          padding: EdgeInsets.symmetric(vertical: 80),
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
    }

    final smallware = state.tab == SuppliesTab.smallware;
    if (state.tabItems.isEmpty) {
      return [
        _Notice(
          key: const Key('supplies-empty'),
          icon: smallware ? Icons.wine_bar_outlined : Icons.soap_outlined,
          color: AppColors.mutedForeground,
          title: smallware
              ? 'Todavía no hay menaje'
              : 'Todavía no hay gastables',
          text: smallware
              ? 'Marca como Menaje las copas, los platos, los cubiertos, las '
                    'ollas y los cuchillos. Aquí verás cuántas piezas hay '
                    'contra el par y cuántas se rompen. El par es el mínimo '
                    'del artículo.'
              : 'Marca como Gastable el papel higiénico, las servilletas, el '
                    'cloro, las fundas y los guantes. Aquí verás cuánto se '
                    'usa, en qué área y para cuántos días alcanza.',
          action: canClassify
              ? TextButton.icon(
                  onPressed: () => _openClassify(state.tab),
                  icon: const Icon(Icons.playlist_add_check_rounded, size: 18),
                  label: const Text('Clasificar artículos'),
                )
              : null,
        ),
      ];
    }

    final items = state.visibleItems;
    return [
      if (smallware)
        _SmallwareKpis(state: state, money: money)
      else
        _SuppliesKpis(state: state, money: money),
      const SizedBox(height: 16),
      if (!smallware && state.report.byDestination.isNotEmpty) ...[
        _DestinationsCard(
          destinations: state.report.byDestination,
          money: money,
          days: state.report.days,
        ),
        const SizedBox(height: 16),
      ],
      _Card(
        padding: const EdgeInsets.fromLTRB(0, 18, 0, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: _CardTitle(
                smallware ? 'Piezas por artículo' : 'Consumo por artículo',
                subtitle: smallware
                    ? 'Primero lo que está bajo el par; después lo que más se '
                          'pierde'
                    : 'Primero lo que hay que reponer; después lo que más se '
                          'usa · ${state.report.days} días',
              ),
            ),
            const SizedBox(height: 10),
            if (items.isEmpty)
              Padding(
                padding: const EdgeInsets.all(20),
                child: Text(
                  'Nada coincide con el filtro.',
                  style: TextStyle(color: AppColors.mutedForeground),
                ),
              )
            else if (width >= 900) ...[
              _TableHeader(smallware: smallware),
              for (final item in items)
                _TableRow(
                  item: item,
                  days: state.report.days,
                  money: money,
                  onTap: () => _openItem(item, state, money),
                ),
            ] else
              for (final item in items)
                _ItemTile(
                  item: item,
                  days: state.report.days,
                  money: money,
                  onTap: () => _openItem(item, state, money),
                ),
          ],
        ),
      ),
    ];
  }

  Future<void> _openClassify(SuppliesTab tab) async {
    final vm = ref.read(suppliesViewModelProvider);
    final changed = await showDialog<int>(
      context: context,
      builder: (_) => SuppliesClassifyDialog(
        initialTarget: tab == SuppliesTab.smallware
            ? ItemClassification.smallware
            : ItemClassification.supply,
        loadItems: vm.loadClassifiableItems,
        onApply: vm.classify,
      ),
    );
    if (!mounted || changed == null || changed == 0) return;
    AppToast.success(
      context,
      changed == 1
          ? '1 artículo clasificado.'
          : '$changed artículos clasificados.',
    );
  }

  Future<void> _openItem(
    SupplyItem item,
    SuppliesState state,
    BusinessCurrency money,
  ) {
    return showDialog<void>(
      context: context,
      builder: (_) =>
          SupplyItemDialog(item: item, days: state.report.days, money: money),
    );
  }
}

// ── Indicadores ────────────────────────────────────────────────────────────

class _SuppliesKpis extends StatelessWidget {
  const _SuppliesKpis({required this.state, required this.money});

  final SuppliesState state;
  final BusinessCurrency money;

  @override
  Widget build(BuildContext context) {
    final items = state.report.supplies;
    final days = state.report.days;
    var consumed = 0.0;
    var stockValue = 0.0;
    var loss = 0.0;
    for (final i in items) {
      consumed += i.consumedValue;
      stockValue += i.stockValue;
      loss += i.lossValue;
    }
    final perDay = days <= 0 ? 0.0 : consumed / days;
    return _KpiGrid(
      tiles: [
        _KpiTile(
          key: const Key('supplies-kpi-consumed'),
          label: 'Consumido',
          value: money.formatAmount(consumed),
          caption: '${money.formatAmount(perDay)} por día · $days días',
          swatch: kYieldProductionColor,
        ),
        _KpiTile(
          label: 'En existencia',
          value: money.formatAmount(stockValue),
          caption: items.length == 1
              ? '1 artículo'
              : '${items.length} artículos',
          icon: Icons.inventory_2_outlined,
        ),
        _KpiTile(
          key: const Key('supplies-kpi-attention'),
          label: 'Por reponer',
          value: '${state.attentionCount}',
          caption: 'Bajo el mínimo o alcanzan para 7 días o menos',
          icon: Icons.shopping_cart_outlined,
        ),
        if (loss >= 0.01)
          _KpiTile(
            label: 'Pérdidas',
            value: money.formatAmount(loss),
            caption: 'Roto, vencido o faltante · $days días',
            swatch: kYieldWasteColor,
          ),
      ],
    );
  }
}

class _SmallwareKpis extends StatelessWidget {
  const _SmallwareKpis({required this.state, required this.money});

  final SuppliesState state;
  final BusinessCurrency money;

  @override
  Widget build(BuildContext context) {
    final items = state.report.smallware;
    final days = state.report.days;
    var pieces = 0.0;
    var stockValue = 0.0;
    var brokenQty = 0.0;
    var brokenValue = 0.0;
    var missingQty = 0.0;
    var missingValue = 0.0;
    for (final i in items) {
      if (i.stock > 0) pieces += i.stock;
      stockValue += i.stockValue;
      brokenQty += i.brokenQty;
      brokenValue += i.brokenValue;
      missingQty += i.missingQty;
      missingValue += i.missingValue;
    }
    return _KpiGrid(
      tiles: [
        _KpiTile(
          label: 'Piezas en existencia',
          value: _fmtQty(pieces),
          caption: 'Valen ${money.formatAmount(stockValue)}',
          icon: Icons.wine_bar_outlined,
        ),
        _KpiTile(
          key: const Key('smallware-kpi-broken'),
          label: 'Roturas',
          value: money.formatAmount(brokenValue),
          caption: '${_fmtQty(brokenQty)} piezas · $days días',
          swatch: kYieldWasteColor,
        ),
        _KpiTile(
          label: 'Faltantes',
          value: money.formatAmount(missingValue),
          caption:
              '${_fmtQty(missingQty)} piezas · robo o no aparecieron '
              'al contar',
          icon: Icons.help_outline_rounded,
        ),
        _KpiTile(
          key: const Key('smallware-kpi-below-par'),
          label: 'Bajo el par',
          value: '${state.attentionCount}',
          caption: 'Artículos por reponer',
          icon: Icons.shopping_cart_outlined,
        ),
      ],
    );
  }
}

class _KpiGrid extends StatelessWidget {
  const _KpiGrid({required this.tiles});

  final List<Widget> tiles;

  @override
  Widget build(BuildContext context) {
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
                for (var i = 0; i < tiles.length; i++) ...[
                  if (i > 0) const SizedBox(width: gap),
                  Expanded(child: tiles[i]),
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
            for (final t in tiles) SizedBox(width: tileWidth, child: t),
          ],
        );
      },
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
      constraints: const BoxConstraints(minHeight: 124),
      padding: const EdgeInsets.all(16),
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

// ── Consumo por área ───────────────────────────────────────────────────────

class _DestinationsCard extends StatelessWidget {
  const _DestinationsCard({
    required this.destinations,
    required this.money,
    required this.days,
  });

  final List<SupplyDestination> destinations;
  final BusinessCurrency money;
  final int days;

  @override
  Widget build(BuildContext context) {
    var max = 0.0;
    var withoutArea = false;
    for (final d in destinations) {
      if (d.value > max) max = d.value;
      if (d.destination == null) withoutArea = true;
    }
    return _Card(
      key: const Key('supplies-destinations'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _CardTitle(
            'Consumo interno por área',
            subtitle: 'Lo que salió del almacén para usarse · $days días',
          ),
          const SizedBox(height: 14),
          for (final d in destinations)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _BarRow(
                label: d.label,
                muted: d.destination == null,
                fraction: max <= 0 ? 0 : d.value / max,
                trailing: money.formatAmount(d.value),
                caption: d.count == 1 ? '1 salida' : '${d.count} salidas',
              ),
            ),
          if (withoutArea)
            Text(
              'Anota el área al registrar el consumo para saber quién gasta '
              'más.',
              style: TextStyle(fontSize: 12, color: AppColors.mutedForeground),
            ),
        ],
      ),
    );
  }
}

class _BarRow extends StatelessWidget {
  const _BarRow({
    required this.label,
    required this.fraction,
    required this.trailing,
    required this.caption,
    this.muted = false,
  });

  final String label;
  final double fraction;
  final String trailing;
  final String caption;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final f = fraction.clamp(0.0, 1.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                  fontStyle: muted ? FontStyle.italic : FontStyle.normal,
                  color: muted
                      ? AppColors.mutedForeground
                      : AppColors.foreground,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              caption,
              style: TextStyle(fontSize: 12, color: AppColors.mutedForeground),
            ),
            const SizedBox(width: 10),
            Text(
              trailing,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w800,
                color: AppColors.foreground,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: Row(
            children: [
              Expanded(
                flex: (f * 1000).round(),
                child: Container(
                  height: 8,
                  color: kYieldProductionColor.withValues(
                    alpha: muted ? 0.4 : 1,
                  ),
                ),
              ),
              Expanded(
                flex: 1000 - (f * 1000).round(),
                child: Container(height: 8, color: AppColors.muted),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ── Tabla ──────────────────────────────────────────────────────────────────

/// Columnas: artículo, y cinco de números. Mismos flex en encabezado y fila.
const _flexes = [4, 2, 2, 2, 2, 2];

class _TableHeader extends StatelessWidget {
  const _TableHeader({required this.smallware});

  final bool smallware;

  @override
  Widget build(BuildContext context) {
    final labels = smallware
        ? const [
            'Artículo',
            'Existencia',
            'Par',
            'Rotas',
            'Faltantes',
            'Estado',
          ]
        : const [
            'Artículo',
            'Existencia',
            'Consumido',
            'Por día',
            'Alcanza para',
            'Estado',
          ];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.muted.withValues(alpha: 0.5),
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          for (var i = 0; i < labels.length; i++)
            Expanded(
              flex: _flexes[i],
              child: Text(
                labels[i],
                textAlign: i == 0 ? TextAlign.start : TextAlign.end,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: AppColors.mutedForeground,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _TableRow extends StatelessWidget {
  const _TableRow({
    required this.item,
    required this.days,
    required this.money,
    required this.onTap,
  });

  final SupplyItem item;
  final int days;
  final BusinessCurrency money;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cells = item.isSmallware
        ? [
            _qtyUnit(item.stock, item.unit),
            item.minStock > 0 ? _fmtQty(item.minStock) : '—',
            item.brokenQty > 0 ? _fmtQty(item.brokenQty) : '—',
            item.missingQty > 0 ? _fmtQty(item.missingQty) : '—',
          ]
        : [
            _qtyUnit(item.stock, item.unit),
            money.formatAmount(item.consumedValue),
            item.consumedQty > 0
                ? _qtyUnit(item.dailyUse(days), item.unit)
                : '—',
            _fmtDays(item.daysLeft(days)),
          ];
    return InkWell(
      key: ValueKey('supplies-row-${item.itemId}'),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: AppColors.border)),
        ),
        child: Row(
          children: [
            Expanded(
              flex: _flexes[0],
              child: _NameCell(item: item),
            ),
            for (var i = 0; i < cells.length; i++)
              Expanded(
                flex: _flexes[i + 1],
                child: Text(
                  cells[i],
                  textAlign: TextAlign.end,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: i == 0 ? FontWeight.w700 : FontWeight.w500,
                    color: AppColors.foreground,
                  ),
                ),
              ),
            Expanded(
              flex: _flexes.last,
              child: Align(
                alignment: Alignment.centerRight,
                child: _StatusPill(item: item, days: days),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NameCell extends StatelessWidget {
  const _NameCell({required this.item});

  final SupplyItem item;

  @override
  Widget build(BuildContext context) {
    final sub = [
      if (item.sku.isNotEmpty) item.sku,
      if (item.isSmallware && item.minStock > 0)
        'par ${_fmtQty(item.minStock)}',
      if (!item.isSmallware && item.minStock > 0)
        'mín ${_fmtQty(item.minStock)}',
    ].join(' · ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          item.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: AppColors.foreground,
          ),
        ),
        if (sub.isNotEmpty)
          Text(
            sub,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: AppColors.mutedForeground),
          ),
      ],
    );
  }
}

/// Fila de teléfono / tablet angosta: la misma información en dos renglones.
class _ItemTile extends StatelessWidget {
  const _ItemTile({
    required this.item,
    required this.days,
    required this.money,
    required this.onTap,
  });

  final SupplyItem item;
  final int days;
  final BusinessCurrency money;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final detail = item.isSmallware
        ? [
            'Hay ${_qtyUnit(item.stock, item.unit)}',
            if (item.minStock > 0) 'par ${_fmtQty(item.minStock)}',
            if (item.brokenQty > 0) '${_fmtQty(item.brokenQty)} rotas',
            if (item.missingQty > 0) '${_fmtQty(item.missingQty)} faltantes',
          ]
        : [
            'Hay ${_qtyUnit(item.stock, item.unit)}',
            'usó ${money.formatAmount(item.consumedValue)}',
            if (item.daysLeft(days) != null)
              'alcanza ${_fmtDays(item.daysLeft(days))}',
          ];
    return InkWell(
      key: ValueKey('supplies-row-${item.itemId}'),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: AppColors.border)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: AppColors.foreground,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    detail.join(' · '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: AppColors.mutedForeground,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            _StatusPill(item: item, days: days),
          ],
        ),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.item, required this.days});

  final SupplyItem item;
  final int days;

  @override
  Widget build(BuildContext context) {
    final (String text, Color color) = item.belowMin
        ? (
            item.isSmallware
                ? 'Faltan ${_fmtQty(item.missingToMin)}'
                : 'Reponer',
            AppColors.destructive,
          )
        : item.attention(days)
        ? ('Se acaba pronto', AppColors.warning)
        : ('Bien', AppColors.success);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.badge),
      ),
      child: Text(
        text,
        maxLines: 1,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w800,
          color: color,
        ),
      ),
    );
  }
}

// ── Ficha del artículo ─────────────────────────────────────────────────────

class SupplyItemDialog extends StatelessWidget {
  const SupplyItemDialog({
    super.key,
    required this.item,
    required this.days,
    required this.money,
  });

  final SupplyItem item;
  final int days;
  final BusinessCurrency money;

  @override
  Widget build(BuildContext context) {
    String qv(double qty, double value) =>
        '${_qtyUnit(qty, item.unit)} · ${money.formatAmount(value)}';
    final rows = <(String, String)>[
      ('Compras', qv(item.purchasedQty, item.purchasedValue)),
      if (item.usedQty != 0)
        ('Consumo interno', qv(item.usedQty, item.usedValue)),
      if (item.soldQty != 0)
        ('Salió con ventas', qv(item.soldQty, item.soldValue)),
      if (item.brokenQty != 0) ('Rotura', qv(item.brokenQty, item.brokenValue)),
      if (item.lostQty != 0)
        ('Faltante / robo', qv(item.lostQty, item.lostValue)),
      if (item.otherOutQty != 0)
        ('Otras salidas', qv(item.otherOutQty, item.otherOutValue)),
      if (item.countAdjustQty != 0)
        (
          'Diferencia de conteo',
          qv(item.countAdjustQty, item.countAdjustValue),
        ),
    ];
    return AlertDialog(
      title: Text(item.name),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                [
                  itemClassificationLabel(item.classification),
                  if (item.sku.isNotEmpty) item.sku,
                  if (item.unitCost > 0)
                    '${money.formatAmount(item.unitCost)} c/u',
                ].join(' · '),
                style: TextStyle(color: AppColors.mutedForeground),
              ),
              const SizedBox(height: 14),
              _section('Dónde está'),
              if (item.byWarehouse.isEmpty)
                Text(
                  'No hay existencia en ninguna bodega.',
                  style: TextStyle(color: AppColors.mutedForeground),
                )
              else
                for (final w in item.byWarehouse)
                  _line(
                    w.warehouseName,
                    [
                      _qtyUnit(w.qty, item.unit),
                      if (w.minStock != null && w.minStock! > 0)
                        '${item.isSmallware ? 'par' : 'mín'} '
                            '${_fmtQty(w.minStock!)}',
                    ].join(' · '),
                  ),
              const Divider(height: 22),
              _line(
                item.isSmallware ? 'Par' : 'Mínimo',
                item.minStock > 0
                    ? '${_fmtQty(item.minStock)}'
                          '${item.minFromWarehouse ? ' (de la bodega)' : ''}'
                    : 'Sin configurar',
              ),
              if (!item.isSmallware)
                _line('Alcanza para', _fmtDays(item.daysLeft(days))),
              const SizedBox(height: 14),
              _section('Últimos $days días'),
              for (final (label, value) in rows) _line(label, value),
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

  Widget _section(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w800,
        color: AppColors.foreground,
      ),
    ),
  );

  Widget _line(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(
            label,
            style: TextStyle(color: AppColors.mutedForeground),
          ),
        ),
        const SizedBox(width: 12),
        // Ancho propio (no la mitad de la fila): el valor queda pegado a la
        // derecha, como en una ficha.
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 280),
          child: Text(
            value,
            textAlign: TextAlign.end,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: AppColors.foreground,
            ),
          ),
        ),
      ],
    ),
  );
}

// ── Piezas ─────────────────────────────────────────────────────────────────

class _Card extends StatelessWidget {
  const _Card({super.key, required this.child, this.padding});

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
    super.key,
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
