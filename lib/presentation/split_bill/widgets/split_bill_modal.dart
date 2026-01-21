import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/sales_models.dart';
import '../viewmodel/split_bill_viewmodel.dart';

/// 📄 Modal de división de cuenta
class SplitBillModal extends ConsumerStatefulWidget {
  final Order order;
  final VoidCallback onSplitApplied;

  const SplitBillModal({
    super.key,
    required this.order,
    required this.onSplitApplied,
  });

  @override
  ConsumerState<SplitBillModal> createState() => _SplitBillModalState();
}

class _SplitBillModalState extends ConsumerState<SplitBillModal> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(splitBillViewModelProvider.notifier).initialize(widget.order);
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(splitBillViewModelProvider);
    final viewModel = ref.read(splitBillViewModelProvider.notifier);

    // Si la división fue aplicada exitosamente
    if (state.splitApplied) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        Navigator.of(context).pop();
        widget.onSplitApplied();

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('División de cuenta aplicada exitosamente'),
            backgroundColor: Colors.green,
          ),
        );
      });
    }

    return Dialog(
      child: Container(
        width: 1000,
        height: 700,
        padding: const EdgeInsets.all(24),
        child: state.loading
            ? const Center(child: CircularProgressIndicator())
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header
                  _buildHeader(context),
                  const SizedBox(height: 24),

                  // Error message
                  if (state.error != null) _buildErrorMessage(state.error!),

                  // Content
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Left side - Items list
                        Expanded(
                          flex: 3,
                          child: _buildItemsList(state, viewModel),
                        ),
                        const SizedBox(width: 24),
                        // Right side - Checks
                        Expanded(
                          flex: 4,
                          child: _buildChecksList(state, viewModel),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 16),

                  // Footer buttons
                  _buildFooter(state, viewModel),
                ],
              ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Dividir Cuenta',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              'Orden #${widget.order.id.substring(0, 8)}',
              style: TextStyle(fontSize: 14, color: Colors.grey[600]),
            ),
          ],
        ),
        IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }

  Widget _buildErrorMessage(String error) {
    return Container(
      padding: const EdgeInsets.all(12),
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: Colors.red[50],
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.red[300]!),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: Colors.red[700]),
          const SizedBox(width: 12),
          Expanded(
            child: Text(error, style: TextStyle(color: Colors.red[700])),
          ),
        ],
      ),
    );
  }

  Widget _buildItemsList(state, viewModel) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.grey[50],
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Productos del Pedido',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${state.unassignedItems.length} productos sin asignar',
                    style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                  ),
                ],
              ),
              if (state.unassignedItems.isNotEmpty)
                TextButton.icon(
                  onPressed: () => viewModel.selectAllUnassigned(),
                  icon: const Icon(Icons.select_all, size: 16),
                  label: const Text('Seleccionar todos'),
                ),
            ],
          ),
          const SizedBox(height: 16),

          // Items list
          Expanded(
            child: state.unassignedItems.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.check_circle,
                          size: 48,
                          color: Colors.green[300],
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Todos los productos están asignados',
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.grey[600],
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    itemCount: state.unassignedItems.length,
                    itemBuilder: (context, index) {
                      final item = state.unassignedItems[index];
                      final isSelected = state.selectedItemIds.contains(
                        item.id,
                      );

                      return _ItemCard(
                        item: item,
                        isSelected: isSelected,
                        onTap: () => viewModel.toggleItemSelection(item.id),
                      );
                    },
                  ),
          ),

          // Assign buttons (shown when items are selected)
          if (state.hasSelectedItems && state.checks.isNotEmpty) ...[
            const Divider(height: 24),
            Text(
              'Asignar ${state.selectedItemIds.length} productos a:',
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: state.checks.map<Widget>((check) {
                return OutlinedButton.icon(
                  onPressed: () =>
                      viewModel.assignSelectedItemsToCheck(check.id),
                  icon: const Icon(Icons.arrow_forward, size: 16),
                  label: Text(check.label),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.orange,
                  ),
                );
              }).toList(),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildChecksList(state, viewModel) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Subcuentas',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                Text(
                  '${state.checks.length} subcuentas creadas',
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                ),
              ],
            ),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: () => viewModel.toggleEqualSplit(),
                  icon: const Icon(Icons.pie_chart, size: 16),
                  label: const Text('Partes iguales'),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  onPressed: () => viewModel.createNewCheck(),
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('Nueva'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.orange,
                    foregroundColor: Colors.white,
                  ),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 16),

        // Equal split panel
        if (state.showEqualSplit) _buildEqualSplitPanel(state, viewModel),

        // Checks list
        Expanded(
          child: state.checks.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.receipt_long,
                        size: 48,
                        color: Colors.grey[300],
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Aún no has agregado subcuentas',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: Colors.grey[600],
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Crea una subcuenta para asignar productos',
                        style: TextStyle(fontSize: 14, color: Colors.grey[500]),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  itemCount: state.checks.length,
                  itemBuilder: (context, index) {
                    final check = state.checks[index];
                    final items = state.itemsForCheck(check.id);

                    return _CheckCard(
                      check: check,
                      items: items,
                      onDelete: items.isEmpty
                          ? () => viewModel.deleteCheck(check.id)
                          : null,
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildEqualSplitPanel(state, viewModel) {
    return Container(
      padding: const EdgeInsets.all(16),
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: Colors.orange[50],
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.orange[200]!),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'División en Partes Iguales',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 20),
                onPressed: () => viewModel.toggleEqualSplit(),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              const Icon(Icons.people, size: 20),
              const SizedBox(width: 8),
              const Text('Número de personas:'),
              const SizedBox(width: 16),
              SizedBox(
                width: 100,
                child: TextField(
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                  ),
                  controller: TextEditingController(
                    text: state.equalSplitPeople.toString(),
                  ),
                  onChanged: (value) {
                    final people = int.tryParse(value);
                    if (people != null) {
                      viewModel.setEqualSplitPeople(people);
                    }
                  },
                ),
              ),
              const SizedBox(width: 16),
              ElevatedButton(
                onPressed: () => viewModel.applyEqualSplit(),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.orange,
                  foregroundColor: Colors.white,
                ),
                child: const Text('Dividir'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildFooter(state, viewModel) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar División'),
        ),
        ElevatedButton(
          onPressed: state.canApplySplit ? () => viewModel.applySplit() : null,
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.orange,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
          ),
          child: const Text(
            'Aplicar División',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
        ),
      ],
    );
  }
}

// ============================================================
// WIDGETS AUXILIARES
// ============================================================

class _ItemCard extends StatelessWidget {
  final OrderItem item;
  final bool isSelected;
  final VoidCallback onTap;

  const _ItemCard({
    required this.item,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.all(12),
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: isSelected ? Colors.orange[50] : Colors.white,
          border: Border.all(
            color: isSelected ? Colors.orange : Colors.grey[300]!,
            width: isSelected ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Checkbox(
              value: isSelected,
              onChanged: (_) => onTap(),
              activeColor: Colors.orange,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.productName,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (item.notes != null && item.notes!.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      item.notes!,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey[600],
                        fontStyle: FontStyle.italic,
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
                  'x${item.quantity.toInt()}',
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                ),
                const SizedBox(height: 4),
                Text(
                  'RD\$ ${item.total.toStringAsFixed(2)}',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CheckCard extends StatelessWidget {
  final OrderCheck check;
  final List<OrderItem> items;
  final VoidCallback? onDelete;

  const _CheckCard({required this.check, required this.items, this.onDelete});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey[300]!),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.grey[100],
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(12),
                topRight: Radius.circular(12),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  check.label,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (onDelete != null)
                  IconButton(
                    icon: const Icon(Icons.delete_outline, size: 20),
                    onPressed: onDelete,
                    color: Colors.red,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
              ],
            ),
          ),

          // Items
          if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Center(
                child: Text(
                  'Sin productos asignados',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey[500],
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
            )
          else
            ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: items.length,
              itemBuilder: (context, index) {
                final item = items[index];
                return ListTile(
                  dense: true,
                  leading: Text(
                    'x${item.quantity.toInt()}',
                    style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                  ),
                  title: Text(
                    item.productName,
                    style: const TextStyle(fontSize: 13),
                  ),
                  trailing: Text(
                    'RD\$ ${item.total.toStringAsFixed(2)}',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                );
              },
            ),

          // Summary
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.grey[50],
              borderRadius: const BorderRadius.only(
                bottomLeft: Radius.circular(12),
                bottomRight: Radius.circular(12),
              ),
            ),
            child: Column(
              children: [
                _SummaryRow(label: 'Subtotal', value: check.subtotal),
                const SizedBox(height: 4),
                _SummaryRow(label: 'ITBIS', value: check.tax),
                const Divider(height: 16),
                _SummaryRow(label: 'Total', value: check.total, isBold: true),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  final String label;
  final double value;
  final bool isBold;

  const _SummaryRow({
    required this.label,
    required this.value,
    this.isBold = false,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: isBold ? 14 : 12,
            fontWeight: isBold ? FontWeight.bold : FontWeight.normal,
            color: Colors.grey[700],
          ),
        ),
        Text(
          'RD\$ ${value.toStringAsFixed(2)}',
          style: TextStyle(
            fontSize: isBold ? 14 : 12,
            fontWeight: isBold ? FontWeight.bold : FontWeight.w600,
          ),
        ),
      ],
    );
  }
}
