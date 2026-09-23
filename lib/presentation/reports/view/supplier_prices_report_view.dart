// Reporte «Precios por proveedor» — qué proveedor te vende más barato cada
// insumo, con lo que compraste como única fuente.
//
// Los precios NO salen de lo que el proveedor dice que cuesta: salen del costo
// REAL de la mercancía recibida (órdenes recibidas, recepciones directas y
// conduces), sin borradores ni documentos anulados. Esa es la lectura de
// `fn_purchase_price_comparison` (Compras F4, mig 20260915_0008), la misma que
// ya usan Insumos y el pedido sugerido.
//
// El sistema SUGIERE (D3 del PRD): acá no se cambia ningún proveedor. Tocar una
// fila abre el comparador de ese insumo, que es donde se ve el detalle.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/core/currency/business_currency.dart';
import 'package:mangopos/core/currency/business_currency_provider.dart';
import 'package:mangopos/core/inventory/supplier_price_report.dart';
import 'package:mangopos/core/theme/app_breakpoints.dart';
import 'package:mangopos/core/theme/app_colors.dart';
import 'package:mangopos/core/utils/friendly_error.dart';
import 'package:mangopos/data/repositories/supplier_price_report_repository.dart';
import 'package:mangopos/presentation/inventory/view/widgets/price_comparison_dialog.dart';
import 'package:mangopos/presentation/reports/widgets/report_widgets.dart';
import 'package:mangopos/services/session/session_controller.dart';

const _windowOptions = [30, 90, 180];

class SupplierPricesReportView extends ConsumerStatefulWidget {
  const SupplierPricesReportView({super.key});

  @override
  ConsumerState<SupplierPricesReportView> createState() =>
      _SupplierPricesReportViewState();
}

class _SupplierPricesReportViewState
    extends ConsumerState<SupplierPricesReportView> {
  int _days = 90;
  String _search = '';
  bool _onlyWithAlternatives = false;
  final TextEditingController _searchController = TextEditingController();
  Future<SupplierPriceReportData>? _future;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _reload() {
    final businessId = ref.read(sessionProvider).activeBusinessId;
    if (businessId == null || businessId.isEmpty) {
      setState(() {
        _future = Future.value(
          const SupplierPriceReportData(rows: [], supported: true),
        );
      });
      return;
    }
    final repo = ref.read(supplierPriceReportRepositoryProvider);
    setState(() {
      _future = repo.load(businessId: businessId, daysBack: _days);
    });
  }

  void _setDays(int days) {
    if (days == _days) return;
    _days = days;
    _reload();
  }

  Future<void> _openComparison(SupplierPriceReportRow row) async {
    await showPriceComparisonDialog(
      context,
      itemId: row.itemId,
      itemName: row.itemName,
      unit: row.unit,
      currentSupplierId: row.current?.supplierId,
    );
  }

  @override
  Widget build(BuildContext context) {
    final currency = currentBusinessCurrencyOrFallback(ref);
    final isMobile = ResponsiveHelper.isMobile(context);

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            isMobile ? 12 : 20,
            isMobile ? 12 : 20,
            isMobile ? 12 : 20,
            16,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextButton.icon(
                style: TextButton.styleFrom(
                  foregroundColor: MangoColors.darkGray,
                  padding: EdgeInsets.zero,
                ),
                onPressed: () => context.go(AppRoutes.reports),
                icon: const Icon(Icons.arrow_back),
                label: const Text('Regresar'),
              ),
              const SizedBox(height: 12),
              Text(
                'Precios por proveedor',
                style: TextStyle(
                  fontSize: isMobile ? 19 : 22,
                  fontWeight: FontWeight.w800,
                  color: MangoColors.darkGray,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Quién te vende más barato cada producto, según el costo real '
                'de lo que recibiste. No cuenta borradores ni documentos '
                'anulados.',
                style: TextStyle(fontSize: 13, color: MangoColors.muted),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text(
                    'Últimos',
                    style: TextStyle(fontSize: 12, color: MangoColors.muted),
                  ),
                  for (final days in _windowOptions)
                    ChoiceChip(
                      label: Text('$days d'),
                      selected: days == _days,
                      onSelected: (_) => _setDays(days),
                      visualDensity: VisualDensity.compact,
                      selectedColor: MangoColors.primaryOrange.withValues(
                        alpha: 0.16,
                      ),
                    ),
                  SizedBox(
                    width: isMobile ? 200 : 260,
                    child: TextField(
                      controller: _searchController,
                      onChanged: (value) => setState(() => _search = value),
                      textInputAction: TextInputAction.search,
                      decoration: InputDecoration(
                        hintText: 'Buscar producto o proveedor…',
                        hintStyle: const TextStyle(
                          fontSize: 13,
                          color: MangoColors.muted,
                        ),
                        prefixIcon: const Icon(Icons.search, size: 18),
                        suffixIcon: _search.isEmpty
                            ? null
                            : IconButton(
                                tooltip: 'Limpiar',
                                icon: const Icon(Icons.close, size: 16),
                                onPressed: () {
                                  _searchController.clear();
                                  setState(() => _search = '');
                                },
                              ),
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        filled: true,
                        fillColor: Colors.white,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(color: Color(0xFFE5E7EB)),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(color: Color(0xFFE5E7EB)),
                        ),
                      ),
                    ),
                  ),
                  FilterChip(
                    label: const Text('Solo con 2+ proveedores'),
                    selected: _onlyWithAlternatives,
                    onSelected: (value) =>
                        setState(() => _onlyWithAlternatives = value),
                    visualDensity: VisualDensity.compact,
                    selectedColor: MangoColors.primaryOrange.withValues(
                      alpha: 0.16,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Refrescar',
                    icon: const Icon(Icons.refresh),
                    onPressed: _reload,
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Expanded(
                child: FutureBuilder<SupplierPriceReportData>(
                  future: _future,
                  builder: (ctx, snap) {
                    if (snap.connectionState == ConnectionState.waiting ||
                        _future == null) {
                      return const Center(
                        child: CircularProgressIndicator(
                          valueColor: AlwaysStoppedAnimation(
                            MangoColors.primaryOrange,
                          ),
                        ),
                      );
                    }
                    if (snap.hasError) {
                      return Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            FriendlyError.humanize(
                              'No se pudo cargar el reporte: ${snap.error}',
                            ),
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: AppColors.destructive),
                          ),
                        ),
                      );
                    }
                    final data =
                        snap.data ??
                        const SupplierPriceReportData(
                          rows: [],
                          supported: true,
                        );
                    if (!data.supported) {
                      return const _EmptyState(
                        icon: Icons.cloud_off_outlined,
                        title: 'El comparador no está disponible',
                        detail:
                            'Falta aplicar la migración 20260915_0008 en '
                            'Supabase. Sin ella la base no puede calcular los '
                            'precios por proveedor.',
                      );
                    }

                    final all = data.rows;
                    final rows = filterSupplierPriceRows(
                      all,
                      query: _search,
                      onlyWithAlternatives: _onlyWithAlternatives,
                    );
                    final summary = summarizeSupplierPriceReport(all);

                    if (all.isEmpty) {
                      return const _EmptyState(
                        icon: Icons.local_shipping_outlined,
                        title: 'Todavía no hay con qué comparar',
                        detail:
                            'Este reporte se arma con las compras RECIBIDAS '
                            'que tienen proveedor. Registra recepciones con '
                            'proveedor y la comparación aparece sola.',
                      );
                    }

                    return ListView(
                      padding: EdgeInsets.zero,
                      children: [
                        _SummaryCards(
                          summary: summary,
                          days: _days,
                          currency: currency,
                        ),
                        const SizedBox(height: 14),
                        if (rows.isEmpty)
                          const _EmptyState(
                            icon: Icons.search_off,
                            title: 'Nada con ese filtro',
                            detail:
                                'Prueba con otro nombre o quita el filtro de '
                                'proveedores.',
                          )
                        else
                          ...rows.map(
                            (row) => _ItemPriceCard(
                              row: row,
                              currency: currency,
                              days: _days,
                              onTap: () => _openComparison(row),
                            ),
                          ),
                        const SizedBox(height: 10),
                        Text(
                          'El ahorro estimado es lo que habrías pagado de '
                          'menos si TODO lo comprado en los últimos $_days '
                          'días se lo hubieras comprado al proveedor más '
                          'barato. Es para priorizar a quién llamar, no una '
                          'cuenta por cobrar. Solo entran proveedores con '
                          'compras dentro de la ventana.',
                          style: const TextStyle(
                            fontSize: 11,
                            color: MangoColors.muted,
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Cabecera con los números de la ventana
// ---------------------------------------------------------------------------

class _SummaryCards extends StatelessWidget {
  const _SummaryCards({
    required this.summary,
    required this.days,
    required this.currency,
  });

  final SupplierPriceReportSummary summary;
  final int days;
  final BusinessCurrency currency;

  @override
  Widget build(BuildContext context) {
    final numberFormat = NumberFormat('#,##0', 'en_US');
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= AppBreakpoints.desktop
            ? 4
            : constraints.maxWidth >= AppBreakpoints.tablet
            ? 2
            : 1;
        final width = columns == 1
            ? constraints.maxWidth
            : (constraints.maxWidth - (columns - 1) * 10) / columns;
        final tiles = <Widget>[
          CommercialStatTile(
            label: 'Productos comparados',
            value: numberFormat.format(summary.itemsCompared),
            hint: 'Con compras en los últimos $days días',
          ),
          CommercialStatTile(
            label: 'Con 2+ proveedores',
            value: numberFormat.format(summary.itemsWithAlternatives),
            hint: 'Ahí es donde se puede negociar',
          ),
          CommercialStatTile(
            label: 'Con opción más barata',
            value: numberFormat.format(summary.itemsWithCheaperOption),
            hint: 'Le compras a alguien más caro que el mejor precio',
          ),
          CommercialStatTile(
            label: 'Ahorro estimado',
            value: currency.formatAmount(summary.totalSaving),
            hint: '${numberFormat.format(summary.suppliers)} proveedores '
                'con compras en la ventana',
          ),
        ];
        return Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final tile in tiles) SizedBox(width: width, child: tile),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Una fila = un producto
// ---------------------------------------------------------------------------

class _ItemPriceCard extends StatelessWidget {
  const _ItemPriceCard({
    required this.row,
    required this.currency,
    required this.days,
    required this.onTap,
  });

  final SupplierPriceReportRow row;
  final BusinessCurrency currency;
  final int days;
  final VoidCallback onTap;

  static final _qtyFormat = NumberFormat('#,##0.##', 'en_US');

  @override
  Widget build(BuildContext context) {
    final unit = row.unit.isEmpty ? 'unidad' : row.unit;
    final cheapest = row.cheapest;
    final current = row.current;
    final gap = row.gapPct;

    String money(double v) => currency.formatAmount(v);

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: row.hasCheaperOption
                    ? AppColors.warning.withValues(alpha: 0.45)
                    : AppColors.border,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        row.itemName,
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 15,
                          color: AppColors.foreground,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // El orden importa: «ya compras al mejor precio» solo
                    // aplica si además NO se pagó de más por parte del
                    // volumen (se le puede comprar al barato y al caro a la
                    // vez).
                    if (row.hasCheaperOption)
                      ReportStatusTag(
                        label: 'Ahorras ${money(row.potentialSaving)}',
                        tone: AppColors.warning,
                      )
                    else if (row.potentialSaving > 0)
                      ReportStatusTag(
                        label: 'Pagaste de más ${money(row.potentialSaving)}',
                        tone: AppColors.warning,
                      )
                    else if (row.hasAlternatives)
                      const ReportStatusTag(
                        label: 'Ya compras al mejor precio',
                        tone: AppColors.success,
                      )
                    else
                      const ReportStatusTag(
                        label: 'Un solo proveedor',
                        tone: MangoColors.muted,
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 18,
                  runSpacing: 10,
                  children: [
                    _Metric(
                      label: 'Más barato',
                      value: cheapest == null
                          ? '—'
                          : '${cheapest.supplierName}\n'
                                '${money(cheapest.lastCostBase!)} / $unit',
                      valueColor: AppColors.success,
                    ),
                    _Metric(
                      label: 'Le compras a',
                      value: current == null
                          ? '—'
                          : '${current.supplierName}\n'
                                '${money(current.lastCostBase!)} / $unit',
                    ),
                    _Metric(
                      label: 'Diferencia',
                      value: gap == null || gap <= 0
                          ? '—'
                          : '${gap.toStringAsFixed(gap >= 10 ? 0 : 1)}% más caro',
                      valueColor: gap != null && gap > 0
                          ? AppColors.destructive
                          : null,
                    ),
                    _Metric(
                      label: 'Comprado ($days d)',
                      value:
                          '${_qtyFormat.format(row.totalQty)} $unit\n'
                          '${money(row.totalSpent)}',
                    ),
                    _Metric(
                      label: 'Proveedores',
                      value: '${row.suppliersWithCost}',
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value, this.valueColor});

  final String label;
  final String value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 130, maxWidth: 240),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: AppColors.mutedForeground,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              height: 1.3,
              color: valueColor ?? AppColors.foreground,
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.detail,
  });

  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: MangoColors.muted),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                color: MangoColors.darkGray,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: MangoColors.muted),
            ),
          ],
        ),
      ),
    );
  }
}
