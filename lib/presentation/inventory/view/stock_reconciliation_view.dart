import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/inventory_state.dart';
import '../viewmodel/inventory_viewmodel.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radius.dart';
import '../../../core/theme/app_shadows.dart';

class StockReconciliationView extends ConsumerStatefulWidget {
  const StockReconciliationView({super.key});

  @override
  ConsumerState<StockReconciliationView> createState() =>
      _StockReconciliationViewState();
}

class _StockReconciliationViewState
    extends ConsumerState<StockReconciliationView> {
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
      appBar: AppBar(title: const Text('Conciliacion de stock')),
      body: state.loading && state.items.isEmpty
          ? Center(child: CircularProgressIndicator(color: AppColors.primary))
          : ListView.separated(
              padding: const EdgeInsets.all(24),
              itemCount: state.items.length,
              separatorBuilder: (context, index) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                final item = state.items[index];
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
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item.name,
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                color: AppColors.foreground,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'Actual: ${item.stock.toStringAsFixed(2)} ${item.unit} · Minimo: ${item.minStock.toStringAsFixed(2)}',
                              style: TextStyle(color: AppColors.mutedForeground),
                            ),
                          ],
                        ),
                      ),
                      FilledButton.tonal(
                        onPressed: state.saving
                            ? null
                            : () => _showReconcileDialog(context, item),
                        child: const Text('Ajustar'),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }

  Future<void> _showReconcileDialog(
    BuildContext context,
    InventoryItemSummary item,
  ) async {
    final controller = TextEditingController(
      text: item.stock.toStringAsFixed(2),
    );
    final notesController = TextEditingController();

    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.card)),
        title: Text('Ajustar ${item.name}'),
        content: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: 'Stock contado',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppRadius.card),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: notesController,
                maxLines: 3,
                decoration: InputDecoration(
                  labelText: 'Notas',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppRadius.card),
                  ),
                ),
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
            onPressed: () async {
              final navigator = Navigator.of(context);
              final counted =
                  double.tryParse(controller.text.trim()) ?? item.stock;
              await ref
                  .read(inventoryViewModelProvider)
                  .reconcileStock(
                    itemId: item.id,
                    countedStock: counted,
                    notes: notesController.text.trim().isEmpty
                        ? null
                        : notesController.text.trim(),
                  );
              navigator.pop();
            },
            child: const Text('Guardar ajuste'),
          ),
        ],
      ),
    );
  }
}
