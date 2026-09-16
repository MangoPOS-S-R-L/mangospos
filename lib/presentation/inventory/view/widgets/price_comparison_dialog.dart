// «Precios de …» (Compras F4): qué cobró cada suplidor por un insumo, desde el
// costo REAL recibido, con tendencia, promedio, mín/máx y precio de lista.
//
// Se abre desde Insumos (solo mirar) y desde el pedido sugerido, donde además
// se puede elegir a quién pedirle (D3: el sistema sugiere, la persona decide).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/core/business/business_resolver.dart';
import 'package:mangopos/core/currency/business_currency.dart';
import 'package:mangopos/core/currency/business_currency_provider.dart';
import 'package:mangopos/core/inventory/price_comparison.dart';
import 'package:mangopos/core/theme/app_colors.dart';
import 'package:mangopos/core/utils/friendly_error.dart';
import 'package:mangopos/data/repositories/price_comparison_repository.dart';

/// Abre el comparador. Con [allowPick] devuelve el id del suplidor elegido.
Future<String?> showPriceComparisonDialog(
  BuildContext context, {
  required String itemId,
  required String itemName,
  required String unit,
  String? currentSupplierId,
  bool allowPick = false,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => PriceComparisonDialog(
      itemId: itemId,
      itemName: itemName,
      unit: unit,
      currentSupplierId: currentSupplierId,
      allowPick: allowPick,
    ),
  );
}

const _windowOptions = [30, 90, 180];

class PriceComparisonDialog extends ConsumerStatefulWidget {
  final String itemId;
  final String itemName;
  final String unit;
  final String? currentSupplierId;
  final bool allowPick;

  const PriceComparisonDialog({
    super.key,
    required this.itemId,
    required this.itemName,
    required this.unit,
    this.currentSupplierId,
    this.allowPick = false,
  });

  @override
  ConsumerState<PriceComparisonDialog> createState() => _PriceComparisonDialogState();
}

class _PriceComparisonDialogState extends ConsumerState<PriceComparisonDialog> {
  int _days = 90;
  late Future<List<SupplierPrice>?> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<SupplierPrice>?> _load() async {
    final businessId = await BusinessResolver.ensure('auto');
    return ref.read(priceComparisonRepositoryProvider).getComparison(
          businessId: businessId,
          itemIds: [widget.itemId],
          daysBack: _days,
        );
  }

  void _setDays(int days) {
    if (days == _days) return;
    setState(() {
      _days = days;
      _future = _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final currency = currentBusinessCurrencyOrFallback(ref);
    return AlertDialog(
      title: Text('Precios de ${widget.itemName}'),
      content: SizedBox(
        width: 640,
        height: 460,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text(
                  'Promedio y rango de los últimos',
                  style: TextStyle(fontSize: 12, color: MangoColors.muted),
                ),
                const SizedBox(width: 8),
                for (final days in _windowOptions)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: ChoiceChip(
                      label: Text('$days d'),
                      selected: days == _days,
                      onSelected: (_) => _setDays(days),
                      visualDensity: VisualDensity.compact,
                      selectedColor: MangoColors.primaryOrange.withValues(alpha: 0.16),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: FutureBuilder<List<SupplierPrice>?>(
                future: _future,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Center(
                      child: CircularProgressIndicator(
                        valueColor: AlwaysStoppedAnimation(MangoColors.primaryOrange),
                      ),
                    );
                  }
                  if (snapshot.hasError) {
                    return Center(
                      child: Text(
                        FriendlyError.humanize('No se pudieron cargar los precios: ${snapshot.error}'),
                        textAlign: TextAlign.center,
                      ),
                    );
                  }
                  final prices = snapshot.data;
                  if (prices == null) {
                    return const Center(
                      child: Text(
                        'El comparador necesita la migración 20260915_0008 aplicada en Supabase.',
                        textAlign: TextAlign.center,
                      ),
                    );
                  }
                  if (prices.isEmpty) {
                    return const Center(
                      child: Text(
                        'Todavía no hay compras recibidas con suplidor ni precios de lista para este insumo.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: MangoColors.muted),
                      ),
                    );
                  }
                  return ListView.separated(
                    itemCount: prices.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (_, i) => _PriceCard(
                      price: prices[i],
                      unit: widget.unit,
                      days: _days,
                      currency: currency,
                      isCurrent: prices[i].supplierId == widget.currentSupplierId,
                      onPick: widget.allowPick &&
                              prices[i].supplierActive &&
                              prices[i].supplierId != widget.currentSupplierId
                          ? () => Navigator.of(context).pop(prices[i].supplierId)
                          : null,
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Costo real de lo RECIBIDO (órdenes, recepciones directas y conduces), sin '
              'borradores ni documentos anulados. Tendencia: último precio contra el anterior distinto.',
              style: TextStyle(fontSize: 11, color: MangoColors.muted),
            ),
          ],
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

class _PriceCard extends StatelessWidget {
  final SupplierPrice price;
  final String unit;
  final int days;
  final BusinessCurrency currency;
  final bool isCurrent;
  final VoidCallback? onPick;

  const _PriceCard({
    required this.price,
    required this.unit,
    required this.days,
    required this.currency,
    required this.isCurrent,
    required this.onPick,
  });

  static final _dateFmt = DateFormat('dd/MM/yy');

  @override
  Widget build(BuildContext context) {
    final p = price;
    final packLabel = p.purchaseUnit.isEmpty ? 'empaque' : p.purchaseUnit;
    String money(double v) => currency.formatAmount(v);
    String perUnit(double v) => '${money(v)} / $unit';

    final badges = <Widget>[
      if (p.rankByLast == 1) const _Badge('El más barato', AppColors.success),
      if (p.isResolved) const _Badge('Del pedido sugerido', MangoColors.primaryOrange),
      if (isCurrent && !p.isResolved) const _Badge('Elegido', MangoColors.primaryOrange),
      if (p.isLinked && !p.linkActive) const _Badge('Vínculo desactivado', MangoColors.muted),
      if (!p.supplierActive) const _Badge('Suplidor inactivo', AppColors.destructive),
    ];

    final last = p.lastCostBase;
    final trend = trendLabel(p.trendPct);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: MangoColors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: p.rankByLast == 1 ? AppColors.success.withValues(alpha: 0.5) : MangoColors.cardBorder,
        ),
      ),
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
                      p.supplierName,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        color: MangoColors.darkGray,
                      ),
                    ),
                    if (badges.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Wrap(spacing: 4, runSpacing: 4, children: badges),
                    ],
                  ],
                ),
              ),
              if (last != null)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      p.hasPack ? '${money(p.perPack(last)!)} / $packLabel' : perUnit(last),
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                        color: MangoColors.darkGray,
                      ),
                    ),
                    Text(
                      [
                        if (p.hasPack) perUnit(last),
                        if (p.lastAt != null) _dateFmt.format(p.lastAt!.toLocal()),
                      ].join(' · '),
                      style: const TextStyle(fontSize: 11, color: MangoColors.muted),
                    ),
                  ],
                )
              else
                const Text(
                  'Sin compras recibidas',
                  style: TextStyle(fontSize: 12, color: MangoColors.muted),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              if (trend.isNotEmpty)
                _Pill(
                  'Tendencia $trend',
                  (p.trendPct ?? 0) > 0.05
                      ? AppColors.destructive
                      : (p.trendPct ?? 0) < -0.05
                          ? AppColors.success
                          : MangoColors.muted,
                ),
              if ((p.vsCheapestPct ?? 0) > 0.05)
                _Pill('${p.vsCheapestPct!.toStringAsFixed(1)}% sobre el más barato', AppColors.warning),
              if (p.avgCostBase != null)
                _Pill('Promedio $days d: ${perUnit(p.avgCostBase!)}', MangoColors.muted),
              if (p.minCostBase != null && p.maxCostBase != null && p.minCostBase != p.maxCostBase)
                _Pill('Rango ${money(p.minCostBase!)} – ${money(p.maxCostBase!)}', MangoColors.muted),
              if (p.purchasesCount > 0)
                _Pill(
                  '${p.purchasesCount} ${p.purchasesCount == 1 ? 'compra' : 'compras'} en $days d',
                  MangoColors.muted,
                ),
              if (p.listPricePack != null)
                _Pill(
                  'Lista ${money(p.listPricePack!)}${p.hasPack ? ' / $packLabel' : ''}'
                  '${p.listPriceSource == 'recepcion' ? ' (de recepción' : p.listPriceSource == 'manual' ? ' (manual' : ''}'
                  '${p.listPriceSource != null && p.listPriceAt != null ? ', ${_dateFmt.format(p.listPriceAt!.toLocal())})' : p.listPriceSource != null ? ')' : ''}',
                  MangoColors.muted,
                ),
            ],
          ),
          if (onPick != null)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: onPick,
                icon: const Icon(Icons.swap_horiz, size: 18),
                label: const Text('Pedirle a este'),
              ),
            ),
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  final String label;
  final Color color;
  const _Badge(this.label, this.color);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: color),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final String label;
  final Color color;
  const _Pill(this.label, this.color);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color),
      ),
    );
  }
}
