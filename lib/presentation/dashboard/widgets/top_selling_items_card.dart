// Widget "Top Selling Items" del dashboard. Muestra los N productos más
// vendidos hoy con imagen + nombre + count de unidades.
//
// Datos vienen del provider `dashboardTopProductsProvider(limit)`. Si no
// hay datos (negocio cerrado, sin ventas hoy) renderiza un empty state
// honesto en vez de quedarse vacío.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/theme/app_colors.dart';
import '../../../data/models/dashboard_models.dart';
import '../providers/dashboard_providers.dart';
import 'dashboard_card_frame.dart';

class TopSellingItemsCard extends ConsumerWidget {
  /// Cantidad de productos a mostrar. Default 3 — el mockup pide 3 tiles.
  final int limit;

  const TopSellingItemsCard({super.key, this.limit = 3});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncProducts = ref.watch(dashboardTopProductsProvider(limit));
    return DashboardCardFrame(
      title: 'Productos más vendidos',
      subtitle: 'Hoy',
      child: asyncProducts.when(
        loading: () => const _LoadingSkeleton(),
        error: (e, _) => DashboardErrorBox(
          message: 'No se pudo cargar el top de productos.',
          onRetry: () => ref.invalidate(dashboardTopProductsProvider(limit)),
        ),
        data: (items) {
          if (items.isEmpty) {
            return const DashboardEmptyState(
              icon: Icons.fastfood_outlined,
              message: 'Aún no hay ventas hoy.',
            );
          }
          return Column(
            children: [
              for (var i = 0; i < items.length; i++) ...[
                if (i > 0) const SizedBox(height: 12),
                _ProductTile(product: items[i]),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _ProductTile extends StatelessWidget {
  final DashboardTopProduct product;
  const _ProductTile({required this.product});

  @override
  Widget build(BuildContext context) {
    final qtyFormat = NumberFormat('#,##0', 'en_US');
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            width: 64,
            height: 64,
            child: product.imageUrl != null
                ? Image.network(
                    product.imageUrl!,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => _ImagePlaceholder(),
                  )
                : _ImagePlaceholder(),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                product.productName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: AppColors.foreground,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                qtyFormat.format(product.totalQuantity),
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: AppColors.foreground,
                ),
              ),
              const Text(
                'unidades',
                style: TextStyle(
                  fontSize: 11,
                  color: AppColors.mutedForeground,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ImagePlaceholder extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.secondary,
      alignment: Alignment.center,
      child: Icon(
        Icons.image_outlined,
        color: AppColors.mutedForeground,
        size: 28,
      ),
    );
  }
}

class _LoadingSkeleton extends StatelessWidget {
  const _LoadingSkeleton();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var i = 0; i < 3; i++) ...[
          if (i > 0) const SizedBox(height: 12),
          Row(
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: AppColors.secondary,
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 120,
                      height: 12,
                      color: AppColors.secondary,
                    ),
                    const SizedBox(height: 8),
                    Container(
                      width: 60,
                      height: 20,
                      color: AppColors.secondary,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
