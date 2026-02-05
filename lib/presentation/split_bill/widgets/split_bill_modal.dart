import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/sales_models.dart';
import '../viewmodel/split_bill_viewmodel.dart';
import '../state/split_bill_state.dart';

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

class _SplitBillModalState extends ConsumerState<SplitBillModal>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(splitBillViewModelProvider.notifier).initialize(widget.order);
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(splitBillViewModelProvider);
    final viewModel = ref.read(splitBillViewModelProvider.notifier);
    final size = MediaQuery.of(context).size;
    final isMobile = size.width < 900;

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
      insetPadding: isMobile
          ? const EdgeInsets.symmetric(horizontal: 16, vertical: 24)
          : const EdgeInsets.symmetric(horizontal: 40, vertical: 40),
      child: Container(
        width: 1100,
        height: isMobile ? double.infinity : 750,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
        ),
        padding: const EdgeInsets.all(24),
        child: state.loading
            ? const Center(child: CircularProgressIndicator())
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header
                  _buildHeader(context, isMobile),
                  const SizedBox(height: 16),

                  // Error message
                  if (state.error != null) _buildErrorMessage(state.error!),

                  // Content
                  Expanded(
                    child: isMobile
                        ? Column(
                            children: [
                              TabBar(
                                controller: _tabController,
                                labelColor: Colors.orange,
                                unselectedLabelColor: Colors.grey,
                                indicatorColor: Colors.orange,
                                tabs: const [
                                  Tab(text: 'Productos'),
                                  Tab(text: 'Subcuentas'),
                                ],
                              ),
                              const SizedBox(height: 16),
                              Expanded(
                                child: TabBarView(
                                  controller: _tabController,
                                  children: [
                                    _buildItemsList(state, viewModel, isMobile),
                                    _buildChecksList(
                                      state,
                                      viewModel,
                                      isMobile,
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          )
                        : Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // Left side - Items list
                              Expanded(
                                flex: 4,
                                child: _buildItemsList(
                                  state,
                                  viewModel,
                                  isMobile,
                                ),
                              ),
                              const SizedBox(width: 24),
                              // Right side - Checks
                              Expanded(
                                flex: 5,
                                child: _buildChecksList(
                                  state,
                                  viewModel,
                                  isMobile,
                                ),
                              ),
                            ],
                          ),
                  ),

                  const SizedBox(height: 16),

                  // Footer buttons
                  _buildFooter(state, viewModel, isMobile),
                ],
              ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, bool isMobile) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Dividir Cuenta',
              style: TextStyle(
                fontSize: isMobile ? 20 : 24,
                fontWeight: FontWeight.bold,
              ),
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

  Widget _buildItemsList(
    SplitBillState state,
    SplitBillViewModel viewModel,
    bool isMobile,
  ) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.grey[50],
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey[200]!),
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
                  label: const Text('Todos'),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
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
                          'Todos los productos asignados',
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

  Widget _buildChecksList(
    SplitBillState state,
    SplitBillViewModel viewModel,
    bool isMobile,
  ) {
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
                  '${state.checks.length} subcuentas',
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                ),
              ],
            ),
            Row(
              children: [
                IconButton(
                  onPressed: () => viewModel.toggleEqualSplit(),
                  tooltip: 'Dividir en partes iguales',
                  icon: const Icon(Icons.pie_chart_outline),
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
                        textAlign: TextAlign.center,
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
                      onRemoveItem: (itemId) => viewModel.unassignItem(itemId),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildEqualSplitPanel(
    SplitBillState state,
    SplitBillViewModel viewModel,
  ) {
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
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 16,
            runSpacing: 12,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.people, size: 20, color: Colors.orange),
                  const SizedBox(width: 8),
                  const Text('Personas:'),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 80,
                    height: 36,
                    child: TextField(
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 0,
                        ),
                      ),
                      textAlign: TextAlign.center,
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
                ],
              ),
              ElevatedButton(
                onPressed: () => viewModel.applyEqualSplit(),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.orange,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(100, 36),
                ),
                child: const Text('Dividir Items'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildFooter(
    SplitBillState state,
    SplitBillViewModel viewModel,
    bool isMobile,
  ) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        if (state.canApplySplit)
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: const Text(
                'Todos los items asignados',
                style: TextStyle(
                  color: Colors.green,
                  fontWeight: FontWeight.w600,
                ),
                textAlign: TextAlign.right,
              ),
            ),
          ),
        const SizedBox(width: 12),
        OutlinedButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        const SizedBox(width: 12),
        ElevatedButton(
          onPressed: state.canApplySplit ? () => viewModel.applySplit() : null,
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.orange,
            foregroundColor: Colors.white,
            padding: EdgeInsets.symmetric(
              horizontal: isMobile ? 24 : 32,
              vertical: 16,
            ),
          ),
          child: const Text(
            'Confirmar División',
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
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            const SizedBox(width: 8),
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
                    const SizedBox(height: 2),
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
                Text(
                  'RD\$ ${item.total.toStringAsFixed(2)}',
                  style: const TextStyle(
                    fontSize: 13,
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
  final Function(String) onRemoveItem;

  const _CheckCard({
    required this.check,
    required this.items,
    this.onDelete,
    required this.onRemoveItem,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey[300]!),
        boxShadow: const [
          BoxShadow(
            color: Color(0x08000000),
            blurRadius: 4,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Container(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
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
                    color: Colors.black87,
                  ),
                ),
                if (onDelete != null)
                  IconButton(
                    icon: const Icon(Icons.delete_outline, size: 20),
                    onPressed: onDelete,
                    color: Colors.red,
                    tooltip: 'Eliminar subcuenta',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
              ],
            ),
          ),

          // Items
          if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Center(
                child: Text(
                  'Sin productos asignados',
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.grey[500],
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
            )
          else
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: items.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final item = items[index];
                return ListTile(
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 0,
                  ),
                  leading: Text(
                    'x${item.quantity.toInt()}',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: Colors.grey[700],
                    ),
                  ),
                  title: Text(
                    item.productName,
                    style: const TextStyle(fontSize: 13),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'RD\$ ${item.total.toStringAsFixed(2)}',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: 4),
                      IconButton(
                        icon: const Icon(Icons.remove_circle_outline, size: 18),
                        onPressed: () => onRemoveItem(item.id),
                        color: Colors.red[300],
                        tooltip: 'Remover',
                        splashRadius: 16,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 24,
                          minHeight: 24,
                        ),
                      ),
                    ],
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
              border: Border(top: BorderSide(color: Colors.grey[200]!)),
            ),
            child: Column(
              children: [
                _SummaryRow(label: 'Subtotal', value: check.subtotal),
                const SizedBox(height: 4),
                _SummaryRow(label: 'ITBIS (18%)', value: check.tax),
                const Divider(height: 12),
                _SummaryRow(
                  label: 'TOTAL',
                  value: check.total,
                  isBold: true,
                  fontSize: 15,
                ),
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
  final double? fontSize;

  const _SummaryRow({
    required this.label,
    required this.value,
    this.isBold = false,
    this.fontSize,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: fontSize ?? (isBold ? 14 : 12),
            fontWeight: isBold ? FontWeight.bold : FontWeight.normal,
            color: Colors.grey[800],
          ),
        ),
        Text(
          'RD\$ ${value.toStringAsFixed(2)}',
          style: TextStyle(
            fontSize: fontSize ?? (isBold ? 14 : 12),
            fontWeight: isBold ? FontWeight.bold : FontWeight.w600,
            color: Colors.black87,
          ),
        ),
      ],
    );
  }
}
