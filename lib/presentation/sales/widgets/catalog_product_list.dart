import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mangopos/core/currency/business_currency_provider.dart';
import 'package:mangopos/presentation/sales/viewmodel/menu_browser_viewmodel.dart';

/// Catálogo en lista. Alternativa al mosaico para cartas largas.
///
/// Cabe el triple de productos por pantalla, el nombre no se trunca a dos
/// líneas y el stock tiene columna propia en vez de una pastilla de 20 dp
/// encima de la card.
///
/// Reusa la MISMA regla de bloqueo por stock que el mosaico: producto con
/// inventario, sin venta en negativo y con 0 disponible no se puede agregar.
class CatalogProductList extends ConsumerWidget {
  const CatalogProductList({
    super.key,
    required this.products,
    required this.stockByProductId,
    required this.onProductTap,
  });

  final List<MenuProduct> products;
  final Map<String, num> stockByProductId;
  final void Function(MenuProduct product) onProductTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currency = currentBusinessCurrencyOrFallback(ref);

    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: products.length,
      separatorBuilder: (_, _) =>
          const Divider(height: 1, indent: 68, color: Color(0xFFF1F5F9)),
      itemBuilder: (context, index) {
        final product = products[index];
        final stockUnits = stockByProductId[product.id];
        final blockedByStock =
            product.isInventoryTracked &&
            !product.allowNegativeSale &&
            stockUnits != null &&
            stockUnits <= 0;

        return _ProductRow(
          product: product,
          priceLabel: currency.formatAmount(product.price),
          stockUnits: stockUnits,
          blocked: blockedByStock,
          onTap: () {
            if (blockedByStock) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    '${product.name} está agotado. Recibe stock o activa '
                    '"Vender aunque esté agotado" en el producto.',
                  ),
                  backgroundColor: const Color(0xFFB91C1C),
                  duration: const Duration(seconds: 3),
                ),
              );
              return;
            }
            onProductTap(product);
          },
        );
      },
    );
  }
}

class _ProductRow extends StatelessWidget {
  const _ProductRow({
    required this.product,
    required this.priceLabel,
    required this.stockUnits,
    required this.blocked,
    required this.onTap,
  });

  final MenuProduct product;
  final String priceLabel;
  final num? stockUnits;
  final bool blocked;
  final VoidCallback onTap;

  /// Color estable derivado del id: el mismo producto conserva su color entre
  /// sesiones y equipos, así el cajero lo ubica por color sin que dependa del
  /// orden de la lista.
  Color get _chipColor {
    const palette = <Color>[
      Color(0xFF475569),
      Color(0xFFB91C1C),
      Color(0xFF0F766E),
      Color(0xFF7C3AED),
      Color(0xFFB45309),
      Color(0xFF1D4ED8),
      Color(0xFFBE185D),
      Color(0xFF15803D),
    ];
    var hash = 0;
    for (final unit in product.id.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    return palette[hash % palette.length];
  }

  String get _initials {
    final clean = product.name.trim();
    if (clean.isEmpty) return '?';
    return clean.length <= 3 ? clean.toUpperCase() : clean.substring(0, 3).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Opacity(
        opacity: blocked ? 0.45 : 1,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: _chipColor,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _initials,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      product.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF0F172A),
                        height: 1.2,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      priceLabel,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF15803D),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _StockLabel(units: stockUnits, tracked: product.isInventoryTracked),
            ],
          ),
        ),
      ),
    );
  }
}

/// Columna de stock. Un producto sin inventario no muestra nada — poner
/// "En stock" en algo que no se controla es información falsa.
class _StockLabel extends StatelessWidget {
  const _StockLabel({required this.units, required this.tracked});

  final num? units;
  final bool tracked;

  @override
  Widget build(BuildContext context) {
    if (!tracked || units == null) return const SizedBox.shrink();

    final value = units!;
    final agotado = value <= 0;
    final bajo = !agotado && value <= 5;
    final color = agotado
        ? const Color(0xFFB91C1C)
        : bajo
            ? const Color(0xFFB45309)
            : const Color(0xFF64748B);

    final texto = agotado
        ? 'Agotado'
        : '${value == value.roundToDouble() ? value.toInt() : value} disp.';

    return Text(
      texto,
      style: TextStyle(
        fontSize: 13,
        fontWeight: agotado || bajo ? FontWeight.w700 : FontWeight.w500,
        color: color,
      ),
    );
  }
}
