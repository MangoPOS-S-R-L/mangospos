import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../viewmodel/inventory_viewmodel.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radius.dart';
import '../../../core/theme/app_shadows.dart';

class RequirementsView extends ConsumerStatefulWidget {
  const RequirementsView({super.key});

  @override
  ConsumerState<RequirementsView> createState() => _RequirementsViewState();
}

class _RequirementsViewState extends ConsumerState<RequirementsView> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(inventoryViewModelProvider).init();
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(inventoryViewModelProvider).state;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: const Text('Kardex de inventario')),
      body: state.loading && state.movements.isEmpty
          ? Center(child: CircularProgressIndicator(color: AppColors.primary))
          : ListView.separated(
              padding: const EdgeInsets.all(24),
              itemCount: state.movements.length,
              separatorBuilder: (context, index) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                final movement = state.movements[index];
                final isOutflow = movement.quantity < 0;
                return Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: AppColors.card,
                    borderRadius: BorderRadius.circular(AppRadius.card),
                    border: Border.all(color: AppColors.border),
                    boxShadow: AppShadows.soft,
                  ),
                  child: Row(
                    children: [
                      CircleAvatar(
                        backgroundColor: isOutflow
                            ? AppColors.destructive.withValues(alpha:0.1)
                            : AppColors.success.withValues(alpha:0.1),
                        child: Icon(
                          isOutflow ? Icons.south_west : Icons.north_east,
                          color: isOutflow
                              ? AppColors.destructive
                              : AppColors.success,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              movement.itemName,
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                color: AppColors.foreground,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '${movement.warehouseName} · ${movement.movementType}',
                              style: TextStyle(color: AppColors.mutedForeground),
                            ),
                            if (movement.notes.isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Text(
                                movement.notes,
                                style: TextStyle(
                                  color: AppColors.mutedForeground,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            movement.quantity.toStringAsFixed(2),
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                              color: isOutflow
                                  ? AppColors.destructive
                                  : AppColors.success,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            DateFormat(
                              'dd/MM/yyyy HH:mm',
                            ).format(movement.createdAt),
                            style: TextStyle(
                              fontSize: 12,
                              color: AppColors.mutedForeground,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}
