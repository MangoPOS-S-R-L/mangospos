import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangopos/presentation/customers/viewmodel/customers_viewmodel.dart';
import 'package:mangopos/presentation/settings/more%20settings/printing/printers/viewmodel/printers_viewmodel.dart';
import 'package:mangopos/presentation/sales/widgets/pin_verification_modal.dart';
import 'package:mangopos/services/printing/print_ticket_service.dart';
import 'package:mangopos/core/multimesero/operator_permissions.dart';
import 'package:mangopos/services/session/session_controller.dart';
import 'package:mangopos/core/currency/business_currency_provider.dart';
import 'package:mangopos/core/printing/printerless_mode.dart';
import 'package:mangopos/core/theme/app_breakpoints.dart';
import 'package:mangopos/data/models/printing.dart' show PrinterConfig;
import 'package:mangopos/data/repositories/pos_settings_repository.dart';
import 'package:mangopos/presentation/printing/widgets/ticket_preview_dialog.dart';
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

  Future<bool> _ensureCanDeleteItem() async {
    if (operatorHasPermission(ref, 'ventas.orden.eliminar_item')) {
      return true;
    }
    return showPinVerificationModal(
      context,
      ref,
      level: PinAccessLevel.supervisor,
      title: 'Autorización para eliminar',
      subtitle:
          'Se requiere PIN de Supervisor o Administrador para eliminar productos de la cuenta.',
    );
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

      // Modo sin impresora: se arma la misma precuenta y se muestra en
      // pantalla (con compartir PDF) en vez de mandarla al papel.
      final printerless = await PrinterlessMode.isEnabled(businessId);

      final printRepo = ref.read(printingPrintersRepositoryProvider);
      PrinterConfig? assignedPrinter;
      if (!printerless) {
        assignedPrinter = await printRepo.getAssignedPrinterForType(
          businessId: businessId,
          preferredAreaCodes: const ['cashier', 'fiscal'],
          printsPrebills: true,
        );
        if (assignedPrinter == null) {
          throw Exception('No hay impresora configurada para precuentas.');
        }
      }

      // Build check-level order for pricing
      final checkOrder = check.toOrder(createdAt: order.createdAt);

      // Tax breakdown.
      // PRD 2: lee `order_item_tax_lines` (snapshot real del motor backend)
      // si los items vienen poblados; sino fallback al path heurístico.
      // Esto reemplaza el cálculo predictivo viejo que iteraba `taxes` y
      // multiplicaba por subtotal — frágil con renombres y origins parciales.
      final taxBreakdown = buildOrderTaxBreakdown(checkOrder, items);

      // Business info
      final profileRaw = await Supabase.instance.client
          .from('businesses')
          .select('name,legal_name,address,phone,rnc')
          .eq('id', businessId)
          .maybeSingle();

      final receiptMode = await ref
          .read(posSettingsRepositoryProvider)
          .getReceiptItemDisplayMode(businessId);
      final discountDisplayMode = await ref
          .read(posSettingsRepositoryProvider)
          .getDiscountDisplayMode(businessId);
      String invoiceTpl = PosSettingsRepository.invoiceTemplateStandard;
      try {
        invoiceTpl = await ref
            .read(posSettingsRepositoryProvider)
            .getInvoiceTemplate(businessId);
      } catch (_) {}

      final ticket = PrintTicketService.generatePrecheck(
        order: checkOrder,
        items: items,
        tableName: check.label,
        customerName: check.customerName,
        businessName: profileRaw?['name'] ?? profileRaw?['legal_name'],
        legalName: profileRaw?['legal_name'],
        businessAddress: profileRaw?['address'],
        businessPhone: profileRaw?['phone'],
        businessRnc: profileRaw?['rnc'],
        title: 'PRECUENTA - ${check.label}',
        receiptItemDisplayMode: receiptMode,
        taxBreakdown: taxBreakdown,
        discountDisplayMode: discountDisplayMode,
        template: invoiceTpl,
        currency: currentBusinessCurrencyOrFallback(ref),
        // Layout segun el papel de la impresora destino (58 u 80mm). En modo
        // sin impresora se arma a 80mm para pantalla/PDF.
        paperWidth: assignedPrinter?.paperWidth ?? 80,
      );

      if (printerless) {
        if (context.mounted) {
          await showPrintTicketOnScreen(
            context,
            ticket: ticket,
            title: 'Pre-cuenta ${check.label}',
            fileNamePrefix: 'precuenta',
          );
        }
        return;
      }

      await printRepo.printEscPos(
        printer: assignedPrinter!,
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
    // Clasificación por device físico (shortestSide). No depende de la
    // orientación actual — un iPad Mini sigue siendo smallTablet
    // portrait o landscape.
    final deviceClass = ResponsiveHelper.getDeviceClass(context);
    final isPortrait =
        MediaQuery.orientationOf(context) == Orientation.portrait;
    // Layout stacked (productos arriba / subcuentas abajo) cuando:
    //   - es un teléfono (cualquier orientación), o
    //   - es una tablet 7-8" en portrait (poco ancho útil).
    // Tablets 8" en landscape y todas las tablet 10"+ usan layout 2-col.
    final isMobile = deviceClass == DeviceClass.phone ||
        (deviceClass == DeviceClass.smallTablet && isPortrait);
    // Header/banner compactos también para tablets 8" en landscape
    // (siguen siendo dispositivos chicos en términos de UX táctil).
    final compactChrome = deviceClass != DeviceClass.largeTablet;

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
                // Header — compact para phones y todas las tablets de
                // 7-8" (cualquier orientación). Solo tablets 10"+ ven
                // el header completo con subtítulo.
                _buildModalHeader(context, compact: compactChrome),
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
  /// Header del modal. En `compact = true` (phones / 8" portrait) se vuelve
  /// 1 línea: ícono pequeño + título + cerrar — sin subtítulo, padding
  /// reducido. Esto le devuelve ~40px de alto vertical al área del cart.
  Widget _buildModalHeader(BuildContext context, {required bool compact}) {
    final iconSize = compact ? 18.0 : 24.0;
    final titleSize = compact ? 16.0 : 20.0;
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 14 : 24,
        vertical: compact ? 10 : 20,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Row(
              children: [
                Container(
                  padding: EdgeInsets.all(compact ? 6 : 10),
                  decoration: BoxDecoration(
                    color: _primary.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(compact ? 8 : 12),
                  ),
                  child: Icon(
                    Icons.call_split,
                    color: _primary,
                    size: iconSize,
                  ),
                ),
                SizedBox(width: compact ? 10 : 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'División de cuentas',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: titleSize,
                          fontWeight: FontWeight.bold,
                          color: _textPrimary,
                        ),
                      ),
                      if (!compact) ...[
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
                    ],
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: () => Navigator.of(context).pop(),
            icon: Icon(
              Icons.close,
              color: _textSecondary,
              size: compact ? 18 : 24,
            ),
            visualDensity: compact ? VisualDensity.compact : null,
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

    return LayoutBuilder(builder: (context, panelConstraints) {
      // Compactación basada en el ANCHO REAL del panel, no en el ancho
      // total de la pantalla — así un 8" landscape con 2-cols también
      // se compacta correctamente si cada panel queda muy angosto.
      final panelCompact = panelConstraints.maxWidth < 520;
      return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 1. Blue Info Banner — compactado a 1 línea con tooltip en
        // anchos pequeños. Antes ocupaba 2 líneas + 'Por posición' que
        // no entraba en tablets de 8".
        if (panelCompact)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            color: const Color(0xFFEBF8FF),
            child: Row(
              children: [
                const Icon(
                  Icons.info_outline,
                  color: Color(0xFF3182CE),
                  size: 16,
                ),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Selecciona subcuentas a pagar',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Color(0xFF2C5282),
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                    ),
                  ),
                ),
                Tooltip(
                  message: 'Los descuentos ahora son independientes.\n'
                      'Por posición disponible.',
                  child: const Icon(
                    Icons.help_outline,
                    color: Color(0xFF3182CE),
                    size: 16,
                  ),
                ),
              ],
            ),
          )
        else
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
    });
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
        // Tier de compactación basado en el ancho real del panel.
        //   < 420px → ultra compact: botones icon-only con tooltip.
        //   < 640px → compact: padding reducido, textos cortos.
        //   else    → normal.
        final panelWidth = constraints.maxWidth;
        final ultraCompact = panelWidth < 420;
        final compact = panelWidth < 640;
        final btnPad = EdgeInsets.symmetric(
          horizontal: ultraCompact ? 10 : (compact ? 14 : 20),
          vertical: ultraCompact ? 10 : (compact ? 12 : 14),
        );
        Widget buildActionBtn({
          required IconData icon,
          required String label,
          required String shortLabel,
          required String tooltip,
          required VoidCallback? onPressed,
          required bool primary,
          Color? color,
        }) {
          final effectiveColor = color ?? _primary;
          final iconWidget = Icon(icon, size: ultraCompact ? 20 : 18);
          if (ultraCompact) {
            return Tooltip(
              message: tooltip.isEmpty ? label : tooltip,
              child: primary
                  ? ElevatedButton(
                      onPressed: onPressed,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: effectiveColor,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        padding: btnPad,
                        minimumSize: const Size(44, 44),
                      ),
                      child: iconWidget,
                    )
                  : OutlinedButton(
                      onPressed: onPressed,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: effectiveColor,
                        side: BorderSide(color: effectiveColor),
                        padding: btnPad,
                        minimumSize: const Size(44, 44),
                      ),
                      child: iconWidget,
                    ),
            );
          }
          final btnLabel = Text(
            compact ? shortLabel : label,
            style: const TextStyle(fontWeight: FontWeight.w600),
          );
          final btn = primary
              ? ElevatedButton.icon(
                  onPressed: onPressed,
                  icon: iconWidget,
                  label: btnLabel,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: effectiveColor,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    padding: btnPad,
                  ),
                )
              : OutlinedButton.icon(
                  onPressed: onPressed,
                  icon: iconWidget,
                  label: btnLabel,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: effectiveColor,
                    side: BorderSide(color: effectiveColor),
                    padding: btnPad,
                  ),
                );
          return tooltip.isEmpty ? btn : Tooltip(message: tooltip, child: btn);
        }
        return Padding(
          padding: EdgeInsets.all(compact ? 14.0 : 24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: maxToolsHeight),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Top descriptive line — solo en anchos cómodos.
                      // En compact ocupa una línea entera por nada.
                      if (!compact) ...[
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
                      ],
                      Wrap(
                        spacing: compact ? 8 : 12,
                        runSpacing: compact ? 8 : 12,
                        children: [
                          buildActionBtn(
                            icon: Icons.add,
                            label: 'Nueva subcuenta',
                            shortLabel: 'Nueva',
                            tooltip: 'Crear nueva subcuenta',
                            onPressed: viewModel.createNewCheck,
                            primary: true,
                          ),
                          buildActionBtn(
                            icon: Icons.safety_divider,
                            label: 'Dividir en partes iguales',
                            shortLabel: 'Dividir',
                            tooltip: state.hasActiveDivision
                                ? 'Ya hay una división activa. Deshaz '
                                    'primero con "Unir todo" para volver '
                                    'a dividir desde cero.'
                                : 'Reparte automáticamente los productos '
                                    'entre N sub-cuentas.',
                            onPressed: state.hasActiveDivision
                                ? null
                                : viewModel.toggleEqualSplit,
                            primary: false,
                          ),
                          buildActionBtn(
                            icon: Icons.merge_type,
                            label: 'Unir cuentas',
                            shortLabel: 'Unir',
                            tooltip: 'Unir 2+ subcuentas en una sola',
                            onPressed: state.checks.length < 2
                                ? null
                                : () {
                                    setState(() {
                                      _showMergeTools = !_showMergeTools;
                                    });
                                  },
                            primary: false,
                          ),
                          buildActionBtn(
                            icon: Icons.delete_outline,
                            label: 'Eliminar subcuenta',
                            shortLabel: 'Eliminar',
                            tooltip: 'Eliminar una subcuenta',
                            onPressed: state.checks.isEmpty
                                ? null
                                : () {
                                    setState(() {
                                      _showDeleteTools = !_showDeleteTools;
                                    });
                                  },
                            primary: false,
                            color: Colors.red,
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
                            onSelectNcfType: (ncfType) async {
                              await viewModel.setNcfTypeForCheck(
                                check.id,
                                ncfType,
                              );
                            },
                            onDelete: () async {
                              if (!await _ensureCanDeleteItem()) return;
                              await viewModel.deleteCheck(check.id);
                            },
                            onRemoveItem: (itemId) async {
                              if (!await _ensureCanDeleteItem()) return;
                              await viewModel.unassignItem(itemId);
                            },
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
        // Tres tiers:
        //   < 420px → ultra: cancelar = icon-only, apply = "Aplicar" corto.
        //   < 680px → compact: stack vertical con labels cortos.
        //   else    → labels completos en fila.
        final ultra = constraints.maxWidth < 420;
        final isCompact = constraints.maxWidth < 680;
        final cancelLabel = ultra ? 'X' : (isCompact ? 'Cancelar' : 'Cancelar división');
        final applyLabel = ultra ? 'Aplicar' : (isCompact ? 'Aplicar' : 'Aplicar división');
        final cancelButton = ultra
            ? IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close, size: 20),
                tooltip: 'Cancelar división',
                color: _textSecondary,
              )
            : TextButton.icon(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close, size: 18),
                label: Text(cancelLabel),
                style: TextButton.styleFrom(foregroundColor: _textSecondary),
              );
        final applyButton = ElevatedButton.icon(
          onPressed: state.canApplySplit ? () => viewModel.applySplit() : null,
          icon: const Icon(Icons.check, size: 18),
          label: Text(applyLabel),
          style: ElevatedButton.styleFrom(
            backgroundColor: _primary,
            disabledBackgroundColor: Colors.grey[300],
            foregroundColor: Colors.white,
            padding: EdgeInsets.symmetric(
              horizontal: ultra ? 16 : (isCompact ? 22 : 32),
              vertical: ultra ? 12 : 16,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            elevation: 0,
          ),
        );

        return Padding(
          padding: EdgeInsets.all(ultra ? 10 : 16),
          child: isCompact
              ? Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [cancelButton, applyButton],
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
  final Future<void> Function(String? ncfType)? onSelectNcfType;
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
    this.onSelectNcfType,
    required this.onDelete,
    required this.onRemoveItem,
    required this.onPrintPrecheck,
    required this.primaryColor,
  });

  /// Tipos de comprobante comunes en RD para selector inline.
  /// Si el negocio usa tipos adicionales, el cajero puede dejar en "default"
  /// y configurarlo en el modal de pago final.
  static const Map<String, String> _ncfTypeOptions = {
    'B01': 'Crédito Fiscal (B01)',
    'B02': 'Consumidor (B02)',
    'B14': 'Régimen Especial (B14)',
    'B15': 'Gubernamental (B15)',
    'E31': 'e-CF Crédito Fiscal (E31)',
    'E32': 'e-CF Consumidor (E32)',
  };

  String _ncfLabel(String? type) {
    if (type == null || type.trim().isEmpty) return 'Default del negocio';
    return _ncfTypeOptions[type] ?? type;
  }

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
                if (onSelectNcfType != null) ...[
                  const SizedBox(height: 8),
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
                              Icons.receipt_long_rounded,
                              size: 16,
                              color: Color(0xFF6B7280),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              _ncfLabel(check.requestedNcfType),
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight:
                                    check.requestedNcfType?.isNotEmpty == true
                                        ? FontWeight.w600
                                        : FontWeight.w500,
                                color:
                                    check.requestedNcfType?.isNotEmpty == true
                                        ? const Color(0xFF111827)
                                        : const Color(0xFF6B7280),
                              ),
                            ),
                          ],
                        ),
                        PopupMenuButton<String>(
                          tooltip: 'Cambiar tipo de comprobante',
                          onSelected: (value) async {
                            // Sentinel "__clear__" => limpia (usa default).
                            final next = value == '__clear__' ? null : value;
                            await onSelectNcfType!(next);
                          },
                          itemBuilder: (_) => [
                            for (final entry in _ncfTypeOptions.entries)
                              PopupMenuItem<String>(
                                value: entry.key,
                                child: Text(entry.value),
                              ),
                            const PopupMenuDivider(),
                            const PopupMenuItem<String>(
                              value: '__clear__',
                              child: Text('Default del negocio'),
                            ),
                          ],
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              border: Border.all(
                                color: primaryColor.withOpacity(0.28),
                              ),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.edit_note_rounded,
                                  size: 16,
                                  color: primaryColor,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  check.requestedNcfType?.isNotEmpty == true
                                      ? 'Cambiar comprobante'
                                      : 'Elegir comprobante',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: primaryColor,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
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
