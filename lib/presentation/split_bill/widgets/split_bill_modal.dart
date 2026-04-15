import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangopos/core/tax/tax_engine.dart';
import 'package:mangopos/presentation/customers/viewmodel/customers_viewmodel.dart';
import 'package:mangopos/presentation/sales/viewmodel/sales_viewmodel.dart';
import 'package:mangopos/presentation/settings/more%20settings/printing/printers/viewmodel/printers_viewmodel.dart';
import 'package:mangopos/services/printing/print_ticket_service.dart';
import 'package:mangopos/services/session/session_controller.dart';
import 'package:mangopos/data/repositories/pos_settings_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../data/models/sales_models.dart';
import '../../../data/utils/order_pricing_utils.dart';
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
  static const Color _primary = Color(0xFFF97316);
  static const Color _textPrimary = Color(0xFF2C2C2C);
  static const Color _textSecondary = Color(0xFF7A7A7A);
  static const Color _border = Color(0xFFE5E7EB);
  static const Color _bgSurface = Colors.white;
  bool _showMergeTools = false;
  bool _showDeleteTools = false;
  String? _mergeSourceCheckId;
  String? _mergeTargetCheckId;
  String? _deleteCheckId;

  String _formatQty(double quantity) {
    final normalized = double.parse(quantity.toStringAsFixed(2));
    if ((normalized - normalized.roundToDouble()).abs() < 0.001) {
      return normalized.toStringAsFixed(0);
    }
    return normalized.toStringAsFixed(2);
  }

  double _linePrice(Order? order, OrderItem item) {
    return itemDisplayTotal(order, item);
  }

  Future<void> _printCheckPrecheck(
    BuildContext context,
    WidgetRef ref,
    Order? order,
    OrderCheck check,
    List<OrderItem> items,
  ) async {
    if (order == null || items.isEmpty) return;

    final scaffold = ScaffoldMessenger.of(context);
    try {
      final session = ref.read(sessionProvider);
      final businessId = session.activeBusinessId;
      if (businessId == null || businessId.isEmpty) {
        throw Exception('No se pudo resolver el negocio activo.');
      }

      final printRepo = ref.read(printingPrintersRepositoryProvider);
      final assignedPrinter = await printRepo.getAssignedPrinterForType(
        businessId: businessId,
        preferredAreaCodes: const ['cashier', 'fiscal'],
        printsPrebills: true,
      );
      if (assignedPrinter == null) {
        throw Exception('No hay impresora configurada para precuentas.');
      }

      // Build check-level order for pricing
      final checkOrder = check.toOrder(createdAt: order.createdAt);

      // Tax breakdown
      final printSummary = summarizeOrderPricing(checkOrder, items);
      final taxBreakdown = <({String label, double amount})>[];
      try {
        final taxRows = await Supabase.instance.client
            .from('taxes')
            .select('name,rate,is_active,is_service_fee,apply_on_zone,apply_on_manual,apply_on_quick,apply_on_delivery')
            .eq('business_id', businessId)
            .eq('is_active', true);
        final taxes = (taxRows as List)
            .map((r) => TaxDef.fromMap(r as Map<String, dynamic>))
            .toList();
        final origin = parseSaleOrigin(
            ref.read(currentOrderProvider).origin);
        for (final tx in taxes) {
          if (!tx.isActive || tx.rate <= 0 || !tx.appliesTo(origin)) continue;
          final pctLabel = tx.rate.truncateToDouble() == tx.rate
              ? '${tx.rate.toInt()}%'
              : '${tx.rate}%';
          final amount = double.parse(
              (printSummary.subtotal * tx.rateDecimal).toStringAsFixed(2));
          taxBreakdown
              .add((label: '${tx.name} ($pctLabel)', amount: amount));
        }
      } catch (_) {}

      // Business info
      final profileRaw = await Supabase.instance.client
          .from('businesses')
          .select('name,legal_name,address,phone,rnc')
          .eq('id', businessId)
          .maybeSingle();

      final receiptMode = await ref
          .read(posSettingsRepositoryProvider)
          .getReceiptItemDisplayMode(businessId);

      final ticket = PrintTicketService.generatePrecheck(
        order: checkOrder,
        items: items,
        tableName: check.label,
        businessName: profileRaw?['name'] ?? profileRaw?['legal_name'],
        legalName: profileRaw?['legal_name'],
        businessAddress: profileRaw?['address'],
        businessPhone: profileRaw?['phone'],
        businessRnc: profileRaw?['rnc'],
        title: 'PRECUENTA - ${check.label}',
        receiptItemDisplayMode: receiptMode,
        taxBreakdown: taxBreakdown,
      );

      await printRepo.printEscPos(
        printer: assignedPrinter,
        data: ticket.escPosCommands,
      );

      if (context.mounted) {
        scaffold.showSnackBar(
          SnackBar(
              content: Text(
                  'Precuenta ${check.label} enviada a impresora.')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        scaffold.showSnackBar(
          SnackBar(
            content: Text('Error imprimiendo precuenta: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

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
            backgroundColor: Color(0xFF22C55E),
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
                if (state.error != null && state.error!.trim().isNotEmpty)
                  Container(
                    width: double.infinity,
                    margin: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFEF2F2),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFFFECACA)),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(
                          Icons.error_outline_rounded,
                          color: Color(0xFFDC2626),
                          size: 18,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            state.error!,
                            style: const TextStyle(
                              color: Color(0xFF991B1B),
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

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
    final unassignedItems = state.unassignedItems;
    final itemsCountByCheckId = <String, int>{};
    for (final item in state.allItems) {
      final checkId = item.checkId;
      if (checkId == null) continue;
      itemsCountByCheckId[checkId] = (itemsCountByCheckId[checkId] ?? 0) + 1;
    }

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
                  count: unassignedItems.length,
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
                      count: itemsCountByCheckId[check.id] ?? 0,
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
          child: unassignedItems.isEmpty
              ? _buildEmptyItemsState()
              : ListView.separated(
                  padding: EdgeInsets.zero,
                  itemCount: unassignedItems.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final item = unassignedItems[index];
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
                                _formatQty(item.quantity),
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
                                      color: const Color(0xFFF97316),
                                      border: Border.all(
                                        color: const Color(0xFFF97316),
                                      ),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: const Text(
                                      'S', // Kitchen status icon
                                      style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                        color: Color(0xFFF97316),
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
                              'RD\$${_linePrice(state.order, item).toStringAsFixed(2)}',
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
          Icon(Icons.check_circle_outline, size: 64, color: Color(0xFF22C55E)),
          SizedBox(height: 16),
          Text(
            'Todos los items asignados',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w500,
              color: Color(0xFF22C55E),
            ),
          ),
        ],
      ),
    );
  }

  // --- RIGHT PANEL: SUBCUENTAS ---
  Widget _buildRightPanel(SplitBillState state, SplitBillViewModel viewModel) {
    final itemsByCheckId = <String, List<OrderItem>>{};
    for (final item in state.allItems) {
      final checkId = item.checkId;
      if (checkId == null) continue;
      itemsByCheckId.putIfAbsent(checkId, () => <OrderItem>[]).add(item);
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final availableHeight = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : MediaQuery.sizeOf(context).height * 0.65;
        final maxToolsHeight = availableHeight * 0.42;
        return Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: maxToolsHeight),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Top Actions
                      Text(
                        'Crea varias subcuentas, une cuentas o divide en partes iguales.',
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: _textSecondary,
                          fontSize: 14,
                          height: 1.4,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
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
                                vertical: 14,
                              ),
                            ),
                          ),
                          OutlinedButton.icon(
                            onPressed: viewModel.toggleEqualSplit,
                            icon: const Icon(Icons.safety_divider, size: 18),
                            label: const Text('Dividir en partes iguales'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: _primary,
                              side: const BorderSide(color: _primary),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 20,
                                vertical: 14,
                              ),
                            ),
                          ),
                          OutlinedButton.icon(
                            onPressed: state.checks.length < 2
                                ? null
                                : () {
                                    setState(() {
                                      _showMergeTools = !_showMergeTools;
                                    });
                                  },
                            icon: const Icon(Icons.merge_type, size: 18),
                            label: const Text('Unir cuentas'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: _primary,
                              side: const BorderSide(color: _primary),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 20,
                                vertical: 14,
                              ),
                            ),
                          ),
                          OutlinedButton.icon(
                            onPressed: state.checks.isEmpty
                                ? null
                                : () {
                                    setState(() {
                                      _showDeleteTools = !_showDeleteTools;
                                    });
                                  },
                            icon: const Icon(Icons.delete_outline, size: 18),
                            label: const Text('Eliminar subcuenta'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.red,
                              side: const BorderSide(color: Colors.red),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 20,
                                vertical: 14,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      if (state.showEqualSplit)
                        _buildEqualSplitTools(state, viewModel),
                      if (_showMergeTools && state.checks.length > 1)
                        _buildMergeChecksTools(state, viewModel),
                      if (_showDeleteTools && state.checks.isNotEmpty)
                        _buildDeleteCheckTools(state, viewModel),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: state.checks.isEmpty
                    ? _buildEmptyChecksState()
                    : ListView.separated(
                        itemCount: state.checks.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 16),
                        itemBuilder: (context, index) {
                          final check = state.checks[index];
                          final items =
                              itemsByCheckId[check.id] ?? const <OrderItem>[];
                          return _CheckCard(
                            order: state.order,
                            check: check,
                            items: items,
                            selectedItemIds:
                                state.selectedItemIds, // Pass selection
                            onToggleSelection: viewModel
                                .toggleItemSelection, // Pass toggle callback
                            onAssignCustomer: () async {
                              final selected =
                                  await showDialog<Map<String, dynamic>>(
                                    context: context,
                                    builder: (_) =>
                                        const _AssignCheckCustomerDialog(),
                                  );
                              if (selected == null) return;
                              final customerId = selected['id']?.toString();
                              final customerName = selected['name']
                                  ?.toString()
                                  .trim();
                              if (customerId == null || customerId.isEmpty) {
                                return;
                              }
                              if (customerName == null ||
                                  customerName.isEmpty) {
                                return;
                              }
                              await viewModel.assignCustomerToCheck(
                                checkId: check.id,
                                customerId: customerId,
                                customerName: customerName,
                              );
                            },
                            onClearCustomer:
                                check.customerId == null &&
                                    (check.customerName == null ||
                                        check.customerName!.trim().isEmpty)
                                ? null
                                : () => viewModel.clearCustomerFromCheck(
                                    check.id,
                                  ),
                            onDelete: () => viewModel.deleteCheck(check.id),
                            onRemoveItem: viewModel.unassignItem,
                            onPrintPrecheck: () => _printCheckPrecheck(
                              context,
                              ref,
                              state.order,
                              check,
                              items,
                            ),
                            primaryColor: _primary,
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
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
          Wrap(
            spacing: 12,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('Personas:'),
              ),
              Container(
                decoration: BoxDecoration(
                  border: Border.all(color: _border),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
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

  Widget _buildMergeChecksTools(
    SplitBillState state,
    SplitBillViewModel viewModel,
  ) {
    if (state.checks.length < 2) return const SizedBox.shrink();

    final sourceId = state.checks.any((c) => c.id == _mergeSourceCheckId)
        ? _mergeSourceCheckId!
        : state.checks.first.id;
    final targetChecks = state.checks.where((c) => c.id != sourceId).toList();
    if (targetChecks.isEmpty) return const SizedBox.shrink();
    final targetId = targetChecks.any((c) => c.id == _mergeTargetCheckId)
        ? _mergeTargetCheckId!
        : targetChecks.first.id;

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
            'Unir cuentas',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          Column(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  border: Border.all(color: _border),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: sourceId,
                    isExpanded: true,
                    hint: const Text('Cuenta origen'),
                    items: state.checks.map((check) {
                      return DropdownMenuItem<String>(
                        value: check.id,
                        child: Text(_formatCheckLabel(check.label)),
                      );
                    }).toList(),
                    onChanged: (value) {
                      if (value == null) return;
                      setState(() {
                        _mergeSourceCheckId = value;
                        if (_mergeTargetCheckId == value) {
                          final fallback = state.checks.firstWhere(
                            (c) => c.id != value,
                            orElse: () => state.checks.first,
                          );
                          _mergeTargetCheckId = fallback.id == value
                              ? null
                              : fallback.id;
                        }
                      });
                    },
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  border: Border.all(color: _border),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: targetId,
                    isExpanded: true,
                    hint: const Text('Cuenta destino'),
                    items: targetChecks.map((check) {
                      return DropdownMenuItem<String>(
                        value: check.id,
                        child: Text(_formatCheckLabel(check.label)),
                      );
                    }).toList(),
                    onChanged: (value) {
                      if (value == null) return;
                      setState(() {
                        _mergeTargetCheckId = value;
                      });
                    },
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerRight,
                child: ElevatedButton(
                  onPressed: sourceId == targetId
                      ? null
                      : () async {
                          await viewModel.mergeChecks(
                            sourceCheckId: sourceId,
                            targetCheckId: targetId,
                          );
                          if (!mounted) return;
                          setState(() {
                            _showMergeTools = false;
                            _mergeSourceCheckId = null;
                            _mergeTargetCheckId = null;
                          });
                        },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _primary,
                    foregroundColor: Colors.white,
                  ),
                  child: const Text('Unir'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDeleteCheckTools(
    SplitBillState state,
    SplitBillViewModel viewModel,
  ) {
    if (state.checks.isEmpty) return const SizedBox.shrink();

    final selectedDeleteId = state.checks.any((c) => c.id == _deleteCheckId)
        ? _deleteCheckId!
        : state.checks.first.id;

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
            'Eliminar subcuenta (mover a principal)',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          Column(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  border: Border.all(color: _border),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: selectedDeleteId,
                    isExpanded: true,
                    hint: const Text('Selecciona subcuenta'),
                    items: state.checks.map((check) {
                      return DropdownMenuItem<String>(
                        value: check.id,
                        child: Text(_formatCheckLabel(check.label)),
                      );
                    }).toList(),
                    onChanged: (value) {
                      if (value == null) return;
                      setState(() {
                        _deleteCheckId = value;
                      });
                    },
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerRight,
                child: ElevatedButton.icon(
                  onPressed: () async {
                    await viewModel.deleteCheck(selectedDeleteId);
                    if (!mounted) return;
                    setState(() {
                      _showDeleteTools = false;
                      _deleteCheckId = null;
                    });
                  },
                  icon: const Icon(Icons.delete_outline, size: 16),
                  label: const Text('Enviar a principal y eliminar'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red,
                    foregroundColor: Colors.white,
                  ),
                ),
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
    return LayoutBuilder(
      builder: (context, constraints) {
        final isCompact = constraints.maxWidth < 680;
        final cancelButton = TextButton.icon(
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.close, size: 18),
          label: const Text('Cancelar división'),
          style: TextButton.styleFrom(foregroundColor: _textSecondary),
        );
        final applyButton = ElevatedButton.icon(
          onPressed: state.canApplySplit ? () => viewModel.applySplit() : null,
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
        );

        return Padding(
          padding: const EdgeInsets.all(16),
          child: isCompact
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Align(alignment: Alignment.centerLeft, child: cancelButton),
                    const SizedBox(height: 10),
                    Align(alignment: Alignment.centerRight, child: applyButton),
                  ],
                )
              : Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [cancelButton, applyButton],
                ),
        );
      },
    );
  }
}

// --- CHECK CARD WIDGET ---
class _AssignCheckCustomerDialog extends ConsumerStatefulWidget {
  const _AssignCheckCustomerDialog();

  @override
  ConsumerState<_AssignCheckCustomerDialog> createState() =>
      _AssignCheckCustomerDialogState();
}

class _AssignCheckCustomerDialogState
    extends ConsumerState<_AssignCheckCustomerDialog> {
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(customersViewModelProvider).init();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vm = ref.watch(customersViewModelProvider);

    return Dialog(
      insetPadding: const EdgeInsets.all(20),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: SizedBox(
        width: 760,
        height: 560,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF97316).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Icon(
                      Icons.person_search_rounded,
                      color: Color(0xFFF97316),
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Cliente de esta subcuenta',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF2C2C2C),
                          ),
                        ),
                        SizedBox(height: 4),
                        Text(
                          'Busca y selecciona el cliente que corresponde a esta cuenta.',
                          style: TextStyle(
                            fontSize: 12,
                            color: Color(0xFF7A7A7A),
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _searchController,
                onChanged: (value) =>
                    ref.read(customersViewModelProvider).search(value),
                decoration: InputDecoration(
                  hintText: 'Buscar por nombre, teléfono o correo',
                  prefixIcon: const Icon(Icons.search_rounded),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(color: Color(0xFFE5E7EB)),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(color: Color(0xFFE5E7EB)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(color: Color(0xFFF97316)),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: const Color(0xFFE5E7EB)),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: vm.isLoading
                      ? const Center(child: CircularProgressIndicator())
                      : vm.customers.isEmpty
                      ? const Center(
                          child: Text(
                            'No se encontraron clientes',
                            style: TextStyle(color: Color(0xFF7A7A7A)),
                          ),
                        )
                      : ListView.separated(
                          itemCount: vm.customers.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final customer = vm.customers[index];
                            final name = customer['name']?.toString().trim();
                            final phone = customer['phone']?.toString().trim();
                            final email = customer['email']?.toString().trim();
                            final taxId = customer['tax_id']?.toString().trim();
                            return ListTile(
                              leading: CircleAvatar(
                                backgroundColor: const Color(
                                  0xFFF97316,
                                ).withValues(alpha: 0.12),
                                child: const Icon(
                                  Icons.person_outline_rounded,
                                  color: Color(0xFFF97316),
                                ),
                              ),
                              title: Text(
                                name?.isNotEmpty == true ? name! : 'Sin nombre',
                              ),
                              subtitle: Text(
                                [phone, email, taxId]
                                    .where((v) => v != null && v.isNotEmpty)
                                    .join(' • '),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              onTap: () => Navigator.of(context).pop(customer),
                            );
                          },
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CheckCard extends StatelessWidget {
  final Order? order;
  final OrderCheck check;
  final List<OrderItem> items;
  final Set<String> selectedItemIds;
  final Function(String) onToggleSelection;
  final VoidCallback onAssignCustomer;
  final VoidCallback? onClearCustomer;
  final VoidCallback onDelete;
  final Function(String) onRemoveItem;
  final VoidCallback onPrintPrecheck;
  final Color primaryColor;

  const _CheckCard({
    required this.order,
    required this.check,
    required this.items,
    required this.selectedItemIds,
    required this.onToggleSelection,
    required this.onAssignCustomer,
    required this.onClearCustomer,
    required this.onDelete,
    required this.onRemoveItem,
    required this.onPrintPrecheck,
    required this.primaryColor,
  });

  String _formatQty(double quantity) {
    final normalized = double.parse(quantity.toStringAsFixed(2));
    if ((normalized - normalized.roundToDouble()).abs() < 0.001) {
      return normalized.toStringAsFixed(0);
    }
    return normalized.toStringAsFixed(2);
  }

  double _linePrice(OrderItem item) {
    return itemDisplayTotal(order, item);
  }

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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
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
                        Icon(Icons.launch, size: 16, color: primaryColor),
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
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF9FAFB),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0xFFE5E7EB)),
                  ),
                  child: Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.person_outline_rounded,
                            size: 16,
                            color: Color(0xFF6B7280),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            check.customerName?.trim().isNotEmpty == true
                                ? check.customerName!
                                : 'Sin cliente asignado',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight:
                                  check.customerName?.trim().isNotEmpty == true
                                  ? FontWeight.w600
                                  : FontWeight.w500,
                              color:
                                  check.customerName?.trim().isNotEmpty == true
                                  ? const Color(0xFF111827)
                                  : const Color(0xFF6B7280),
                            ),
                          ),
                        ],
                      ),
                      OutlinedButton.icon(
                        onPressed: onAssignCustomer,
                        icon: const Icon(Icons.person_search_rounded, size: 16),
                        label: Text(
                          check.customerName?.trim().isNotEmpty == true
                              ? 'Cambiar cliente'
                              : 'Asignar cliente',
                        ),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: primaryColor,
                          side: BorderSide(
                            color: primaryColor.withOpacity(0.28),
                          ),
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                      if (onClearCustomer != null)
                        TextButton.icon(
                          onPressed: onClearCustomer,
                          icon: const Icon(Icons.close_rounded, size: 16),
                          label: const Text('Quitar'),
                          style: TextButton.styleFrom(
                            foregroundColor: const Color(0xFF6B7280),
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                    ],
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
                          child: Text(_formatQty(item.quantity)),
                        ),
                        Expanded(child: Text(item.productName)),
                        SizedBox(
                          width: 80,
                          child: Text(
                            'RD\$${_linePrice(item).toStringAsFixed(2)}',
                          ),
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
                    onPressed: onPrintPrecheck,
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
