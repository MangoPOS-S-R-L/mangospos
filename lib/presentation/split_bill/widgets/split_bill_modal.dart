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
  // Colores Mango POS
  static const Color _primary = Color(0xFFFB7116);
  static final Color _primaryLight = _primary.withOpacity(0.1);
  static const Color _textPrimary = Color(0xFF2C2C2C);
  static const Color _textSecondary = Color(0xFF7A7A7A);
  static const Color _border = Color(0xFFE5E7EB);
  static const Color _bgSurface = Colors.white;

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
    final size = MediaQuery.of(context).size;
    final isMobile = size.width < 900;

    // Listener para cierre exitoso
    ref.listen(splitBillViewModelProvider.select((s) => s.splitApplied), (
      previous,
      next,
    ) {
      if (next) {
        Navigator.of(context).pop();
        widget.onSplitApplied();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('División aplicada exitosamente'),
            backgroundColor: Colors.green,
          ),
        );
      }
    });

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: EdgeInsets.symmetric(
        horizontal: isMobile ? 12 : 36,
        vertical: isMobile ? 16 : 36,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 1200,
          maxHeight: isMobile ? double.infinity : 850,
        ),
        child: Container(
          decoration: BoxDecoration(
            color: _bgSurface,
            borderRadius: BorderRadius.circular(16),
            boxShadow: const [
              BoxShadow(
                color: Color(0x25000000),
                blurRadius: 30,
                offset: Offset(0, 15),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Column(
              children: [
                // Header
                _buildModalHeader(context),
                const Divider(height: 1, color: _border),

                // Contenido Principal
                Expanded(
                  child: state.loading
                      ? const Center(child: CircularProgressIndicator())
                      : isMobile
                      ? _buildMobileLayout(state, viewModel)
                      : Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // Columna Izquierda: Productos (Source)
                            Expanded(
                              flex: 5,
                              child: Container(
                                color: Colors.white,
                                child: _buildLeftPanel(state, viewModel),
                              ),
                            ),
                            const VerticalDivider(width: 1, color: _border),
                            // Columna Derecha: Subcuentas (Destinations)
                            Expanded(
                              flex: 7,
                              child: Container(
                                color: const Color(0xFFF9FAFB),
                                child: _buildRightPanel(state, viewModel),
                              ),
                            ),
                          ],
                        ),
                ),

                const Divider(height: 1, color: _border),
                // Footer (Actions)
                _buildFooter(context, state, viewModel),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // --- HEADER ---
  Widget _buildModalHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: _primary.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.call_split, color: _primary, size: 24),
              ),
              const SizedBox(width: 16),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'División de cuentas',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: _textPrimary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Organiza los items en diferentes subcuentas',
                    style: TextStyle(
                      fontSize: 13,
                      color: _textSecondary,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ],
          ),
          IconButton(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close, color: _textSecondary),
            style: IconButton.styleFrom(
              backgroundColor: Colors.grey[100],
              highlightColor: Colors.grey[200],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMobileLayout(
    SplitBillState state,
    SplitBillViewModel viewModel,
  ) {
    return Column(
      children: [
        Expanded(
          flex: 4,
          child: Container(
            color: Colors.white,
            child: _buildLeftPanel(state, viewModel),
          ),
        ),
        const Divider(height: 1, color: _border),
        Expanded(
          flex: 6,
          child: Container(
            color: const Color(0xFFF9FAFB),
            child: _buildRightPanel(state, viewModel),
          ),
        ),
      ],
    );
  }

  // --- LEFT PANEL: PRODUCTOS ---
  Widget _buildLeftPanel(SplitBillState state, SplitBillViewModel viewModel) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 1. Blue Info Banner
        Container(
          padding: const EdgeInsets.all(12),
          color: const Color(0xFFEBF8FF), // Light blue
          child: Row(
            children: [
              const Icon(
                Icons.info_outline,
                color: Color(0xFF3182CE),
                size: 20,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: const [
                    Text(
                      'Selecciona las subcuentas que deseas pagar.',
                      style: TextStyle(
                        color: Color(0xFF2C5282),
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                    Text(
                      'Los descuentos ahora son independientes.',
                      style: TextStyle(color: Color(0xFF2C5282), fontSize: 12),
                    ),
                  ],
                ),
              ),
              // Radio button visual stub "Por posición"
              Row(
                children: [
                  Container(
                    width: 16,
                    height: 16,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: _primary),
                    ),
                  ),
                  const SizedBox(width: 6),
                  const Text(
                    'Por posición',
                    style: TextStyle(color: _textSecondary, fontSize: 13),
                  ),
                ],
              ),
            ],
          ),
        ),

        // 2. Account Tabs / Filters
        Container(
          padding: const EdgeInsets.all(16),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                // "TODAS" Tab (Active by default for Unassigned/All view)
                _buildFilterTab(
                  label: 'TODAS',
                  count: state.unassignedItems.length,
                  isActive: true,
                  onTap: () {},
                ),
                const SizedBox(width: 12),
                // Subaccount Tabs (Visual representations)
                ...state.checks.map(
                  (check) => Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: _buildFilterTab(
                      label: _formatCheckLabel(check.label),
                      count: state.itemsForCheck(check.id).length,
                      isActive: false,
                      onTap: () {}, // Future: Filter view by check
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),

        const Divider(height: 1, color: _border),

        // 3. "Selecciona un cliente" Row
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: const [
              Icon(Icons.people_outline, color: _primary, size: 20),
              SizedBox(width: 8),
              Text(
                'Selecciona un cliente',
                style: TextStyle(
                  color: _primary,
                  fontWeight: FontWeight.w600,
                  decoration: TextDecoration.underline,
                ),
              ),
            ],
          ),
        ),

        // 4. Column Headers
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          color: const Color(0xFFF9FAFB),
          child: Row(
            children: const [
              SizedBox(width: 40, child: Text('Cant.', style: _headerStyle)),
              Expanded(child: Text('Producto', style: _headerStyle)),
              Text('Precio', style: _headerStyle),
            ],
          ),
        ),

        // 5. Items List
        Expanded(
          child: state.unassignedItems.isEmpty
              ? _buildEmptyItemsState()
              : ListView.separated(
                  padding: EdgeInsets.zero,
                  itemCount: state.unassignedItems.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final item = state.unassignedItems[index];
                    final isSelected = state.selectedItemIds.contains(item.id);
                    return InkWell(
                      onTap: () => viewModel.toggleItemSelection(item.id),
                      child: Container(
                        color: isSelected
                            ? _primary.withOpacity(0.05)
                            : Colors.white,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 40,
                              child: Text(
                                '${item.quantity.toInt()}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15,
                                ),
                              ),
                            ),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 6,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.orange[50],
                                      border: Border.all(
                                        color: Colors.orange[200]!,
                                      ),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: const Text(
                                      'S', // Kitchen status icon
                                      style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.orange,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    item.productName,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w500,
                                      fontSize: 15,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Text(
                              'RD\$${item.total.toStringAsFixed(2)}',
                              style: const TextStyle(
                                color: _primary,
                                fontWeight: FontWeight.bold,
                                fontSize: 15,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),

        // 6. Footer Assigment Control
        Container(
          padding: const EdgeInsets.all(16),
          decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: _border)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Enviar ${state.selectedItemIds.length} producto(s) a:',
                style: const TextStyle(color: _textSecondary, fontSize: 13),
              ),
              const SizedBox(height: 12),
              if (state.checks.isEmpty)
                const Text(
                  'Crea una subcuenta primero ->',
                  style: TextStyle(
                    color: _textSecondary,
                    fontStyle: FontStyle.italic,
                  ),
                )
              else
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: state.checks.map((check) {
                    return SizedBox(
                      height: 40,
                      child: ElevatedButton(
                        onPressed: state.hasSelectedItems
                            ? () =>
                                  viewModel.assignSelectedItemsToCheck(check.id)
                            : null,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _primary,
                          foregroundColor: Colors.white,
                          disabledBackgroundColor: Colors.grey[200],
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          elevation: 0,
                        ),
                        child: Text(
                          _formatCheckLabel(check.label),
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                    );
                  }).toList(),
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// Formatea la etiqueta para mostrar C1, C2, etc. o iniciales
  String _formatCheckLabel(String label) {
    // Si es "Cuenta X", extraer numero y mostrar CX
    if (label.toLowerCase().startsWith('cuenta ')) {
      final number = label.split(' ').last;
      return 'C$number';
    }
    // Si es corto, mostrar todo
    if (label.length <= 2) return label.toUpperCase();
    // Sino, primeras 2 letras
    return label.substring(0, 2).toUpperCase();
  }

  Widget _buildFilterTab({
    required String label,
    required int count,
    required bool isActive,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Container(
        width: 80,
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: isActive ? _primary : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isActive ? _primary : const Color(0xFFE5E7EB),
          ),
          boxShadow: isActive
              ? [
                  BoxShadow(
                    color: _primary.withOpacity(0.3),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ]
              : null,
        ),
        child: Column(
          children: [
            // Icon
            Icon(
              Icons.attach_money,
              size: 16,
              color: isActive ? Colors.white : _textSecondary,
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                color: isActive ? Colors.white : _textPrimary,
                fontWeight: FontWeight.bold,
                fontSize: 14,
              ),
            ),
            Text(
              '$count 🛒',
              style: TextStyle(
                color: isActive
                    ? Colors.white.withOpacity(0.8)
                    : _textSecondary,
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }

  static const TextStyle _headerStyle = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.bold,
    color: _textSecondary,
  );

  Widget _buildEmptyItemsState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: const [
          Icon(Icons.check_circle_outline, size: 64, color: Colors.green),
          SizedBox(height: 16),
          Text(
            'Todos los items asignados',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w500,
              color: Colors.green,
            ),
          ),
        ],
      ),
    );
  }

  // --- RIGHT PANEL: SUBCUENTAS ---
  Widget _buildRightPanel(SplitBillState state, SplitBillViewModel viewModel) {
    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Top Actions Row
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 8.0),
                  child: Text(
                    'Crea varias subcuentas o\ndivide tu cuenta en\npartes iguales.',
                    style: TextStyle(
                      color: _textSecondary,
                      fontSize: 14,
                      height: 1.4,
                    ),
                  ),
                ),
              ),
              Row(
                children: [
                  ElevatedButton.icon(
                    onPressed: viewModel.createNewCheck,
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Nueva subcuenta'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _primary,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 16,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton.icon(
                    onPressed: viewModel.toggleEqualSplit,
                    icon: const Icon(
                      Icons.safety_divider,
                      size: 18,
                    ), // Divide icon
                    label: const Text('Dividir en partes iguales'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _primary,
                      side: const BorderSide(color: _primary),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 16,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),

          const SizedBox(height: 24),

          // Equal Split Panel (Conditional)
          if (state.showEqualSplit) _buildEqualSplitTools(state, viewModel),

          // Content
          Expanded(
            child: state.checks.isEmpty
                ? _buildEmptyChecksState()
                : ListView.separated(
                    itemCount: state.checks.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 16),
                    itemBuilder: (context, index) {
                      final check = state.checks[index];
                      final items = state.itemsForCheck(check.id);
                      return _CheckCard(
                        check: check,
                        items: items,
                        selectedItemIds:
                            state.selectedItemIds, // Pass selection
                        onToggleSelection: viewModel
                            .toggleItemSelection, // Pass toggle callback
                        onDelete: () => viewModel.deleteCheck(check.id),
                        onRemoveItem: viewModel.unassignItem,
                        primaryColor: _primary,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyChecksState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: const [
          // Placeholder for empty visual if needed,
          // but the user's image shows the right panel populated with cards.
        ],
      ),
    );
  }

  Widget _buildEqualSplitTools(
    SplitBillState state,
    SplitBillViewModel viewModel,
  ) {
    return Container(
      margin: const EdgeInsets.only(bottom: 24),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Dividir en partes iguales',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              const Text('Personas:'),
              const SizedBox(width: 12),
              Container(
                decoration: BoxDecoration(
                  border: Border.all(color: _border),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.remove),
                      onPressed: () => viewModel.setEqualSplitPeople(
                        state.equalSplitPeople - 1,
                      ),
                    ),
                    Text(
                      '${state.equalSplitPeople}',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    IconButton(
                      icon: const Icon(Icons.add),
                      onPressed: () => viewModel.setEqualSplitPeople(
                        state.equalSplitPeople + 1,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              ElevatedButton(
                onPressed: viewModel.applyEqualSplit,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _primary,
                  foregroundColor: Colors.white,
                ),
                child: const Text('Aplicar'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // --- FOOTER ---
  Widget _buildFooter(
    BuildContext context,
    SplitBillState state,
    SplitBillViewModel viewModel,
  ) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          TextButton.icon(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close, size: 18),
            label: const Text('Cancelar división'),
            style: TextButton.styleFrom(foregroundColor: _textSecondary),
          ),

          ElevatedButton.icon(
            onPressed: state.canApplySplit
                ? () => viewModel.applySplit()
                : null,
            icon: const Icon(Icons.check),
            label: const Text('Aplicar división'),
            style: ElevatedButton.styleFrom(
              backgroundColor: _primary,
              disabledBackgroundColor: Colors.grey[300],
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              elevation: 0,
            ),
          ),
        ],
      ),
    );
  }
}

// --- CHECK CARD WIDGET ---
class _CheckCard extends StatelessWidget {
  final OrderCheck check;
  final List<OrderItem> items;
  final Set<String> selectedItemIds; // New prop
  final Function(String) onToggleSelection; // New prop
  final VoidCallback onDelete;
  final Function(String) onRemoveItem;
  final Color primaryColor;

  const _CheckCard({
    required this.check,
    required this.items,
    required this.selectedItemIds,
    required this.onToggleSelection,
    required this.onDelete,
    required this.onRemoveItem,
    required this.primaryColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0D000000),
            offset: Offset(0, 1),
            blurRadius: 2,
          ),
        ],
      ),
      child: Column(
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Text(
                      check.label,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: primaryColor,
                        fontSize: 18,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(
                      Icons.launch,
                      size: 16,
                      color: primaryColor,
                    ), // External link icon style
                  ],
                ),
                Text(
                  'TOTAL: RD\$${check.total.toStringAsFixed(2)}',
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 18,
                    color: Color(0xFF111827),
                  ),
                ),
              ],
            ),
          ),

          const Divider(height: 1),

          // Table Headers
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                const SizedBox(
                  width: 40,
                  child: Text('Cant.', style: _headerStyle),
                ),
                const Expanded(child: Text('Plato', style: _headerStyle)),
                const SizedBox(
                  width: 80,
                  child: Text('Precio', style: _headerStyle),
                ),
                const Text('Más', style: _headerStyle),
              ],
            ),
          ),

          const Divider(height: 1),

          // Items
          if (items.isEmpty)
            Container(
              padding: const EdgeInsets.all(32),
              alignment: Alignment.center,
              child: const Text(
                'Sin productos asignados',
                style: TextStyle(color: Color(0xFF9CA3AF), fontSize: 14),
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
                final isSelected = selectedItemIds.contains(item.id);

                return InkWell(
                  onTap: () => onToggleSelection(item.id),
                  child: Container(
                    color: isSelected
                        ? primaryColor.withOpacity(0.05)
                        : Colors.transparent,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 40,
                          child: Text('${item.quantity.toInt()}'),
                        ),
                        Expanded(child: Text(item.productName)),
                        SizedBox(
                          width: 80,
                          child: Text('RD\$${item.total.toStringAsFixed(0)}'),
                        ),
                        // 'Más' action (Remove)
                        InkWell(
                          onTap: () => onRemoveItem(item.id),
                          child: const Icon(
                            Icons.close,
                            color: Colors.red,
                            size: 18,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),

          const Divider(height: 1),

          // Footer Actions
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Row(
              children: [
                Expanded(
                  child: TextButton.icon(
                    onPressed: onDelete,
                    icon: const Icon(
                      Icons.delete_outline,
                      color: Colors.red,
                      size: 18,
                    ),
                    label: const Text(
                      'Eliminar subcuenta',
                      style: TextStyle(color: Colors.red),
                    ),
                  ),
                ),
                Expanded(
                  child: TextButton.icon(
                    onPressed: () {},
                    icon: const Icon(
                      Icons.receipt_long,
                      color: Color(0xFF6B7280),
                      size: 18,
                    ),
                    label: const Text(
                      'Precuenta',
                      style: TextStyle(color: Color(0xFF6B7280)),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static const TextStyle _headerStyle = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.bold,
    color: Color(0xFF6B7280),
  );
}
