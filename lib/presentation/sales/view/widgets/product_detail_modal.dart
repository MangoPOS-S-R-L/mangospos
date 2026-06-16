import 'package:flutter/material.dart';
import 'package:mangopos/core/theme/app_breakpoints.dart';
import '../../viewmodel/menu_browser_viewmodel.dart';
import '../../viewmodel/sales_viewmodel.dart';
import '../../../../data/models/sales_models.dart';

class ProductDetailModal extends StatefulWidget {
  final OrderItem item;
  final List<OrderItem>? groupedItems;
  final Future<List<Map<String, dynamic>>> Function(String menuItemId)?
  loadModifierGroups;
  final Future<void> Function(
    String itemId,
    List<SelectedModifierInput> selectedModifiers,
  )?
  onReplaceModifiers;
  final Future<void> Function(OrderItem updatedItem) onSave;
  final Future<void> Function(
    List<OrderItem> items,
    OrderItem updatedItem,
    String? reductionReason,
  )?
  onSaveBatch;
  final Future<void> Function(String reason) onDelete;
  final Future<bool> Function()? onBeforeDelete;
  final Future<void> Function()? onMarkSoldOut;
  final VoidCallback? onReprint;

  const ProductDetailModal({
    super.key,
    required this.item,
    this.groupedItems,
    this.loadModifierGroups,
    this.onReplaceModifiers,
    required this.onSave,
    this.onSaveBatch,
    required this.onDelete,
    this.onBeforeDelete,
    this.onMarkSoldOut,
    this.onReprint,
  });

  @override
  State<ProductDetailModal> createState() => _ProductDetailModalState();
}

class _ProductDetailModalState extends State<ProductDetailModal> {
  static const _courtesyPrefix = '[CORTESIA:';

  List<OrderItem> get _scopedItems => widget.groupedItems ?? [widget.item];
  bool get _isGroupedMode => _scopedItems.length > 1;

  late TextEditingController _notesController;
  late TextEditingController _courtesyReasonController;
  late TextEditingController _discountController;

  // Marcador técnico de oferta ([DEAL:uuid]): se oculta del campo de notas
  // editable (se muestra "Oferta aplicada") y se re-añade al guardar, para no
  // romper la detección de oferta del motor de precios.
  String? _dealMarker;

  late double _quantity;
  late bool _isTakeout;
  late bool _isCourtesy;
  bool _isMarkingSoldOut = false;
  bool _isSaving = false;
  bool _isEditingModifiers = false;

  @override
  void initState() {
    super.initState();
    final parsedNotes = _splitStoredNotes(widget.item.notes);
    _dealMarker = parsedNotes.dealMarker;
    _notesController = TextEditingController(text: parsedNotes.notes);
    _courtesyReasonController = TextEditingController(
      text: parsedNotes.courtesyReason ?? '',
    );
    _discountController = TextEditingController(
      text: _initialManualDiscount().toStringAsFixed(2),
    );

    _quantity = _normalizeQty(
      _scopedItems.fold<double>(0, (sum, item) => sum + item.quantity),
    );
    _isTakeout = _scopedItems.every((item) => item.isTakeout);
    final fullAmount = _fullAmountForQuantity(widget.item.quantity);
    _isCourtesy =
        parsedNotes.courtesyReason != null ||
        widget.item.total.abs() < 0.01 ||
        widget.item.discounts >= (fullAmount - 0.01);
  }

  @override
  void dispose() {
    _notesController.dispose();
    _courtesyReasonController.dispose();
    _discountController.dispose();
    super.dispose();
  }

  double _normalizeQty(double value) {
    final rounded = value.roundToDouble();
    if ((value - rounded).abs() < 0.001) {
      return rounded;
    }
    return double.parse(value.toStringAsFixed(2));
  }

  void _incrementQty() {
    setState(() {
      _quantity = _normalizeQty(_quantity + 1);
    });
  }

  void _decrementQty() {
    if (_quantity > 1) {
      setState(() {
        _quantity = _normalizeQty(_quantity - 1);
      });
    }
  }

  Future<void> _handleDelete() async {
    if (widget.onBeforeDelete != null) {
      final allowed = await widget.onBeforeDelete!();
      if (!allowed) return;
      if (!mounted) return;
    }

    final reasonController = TextEditingController();

    final reason = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.red.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.delete_outline,
                color: Colors.red,
                size: 24,
              ),
            ),
            const SizedBox(width: 12),
            const Text(
              'Motivo de eliminación',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 20),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Por favor, indica la razón por la que estás eliminando este producto de la cuenta:',
              style: TextStyle(fontSize: 14, color: Color(0xFF64748B)),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: reasonController,
              maxLines: 3,
              autofocus: false,
              decoration: InputDecoration(
                filled: true,
                fillColor: const Color(0xFFF8FAFC),
                hintText:
                    'Ej: Error de digitación, Cliente cambió de opinión...',
                hintStyle: const TextStyle(color: Color(0xFF94A3B8)),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                ),
              ),
            ),
          ],
        ),
        actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text(
              'CANCELAR',
              style: TextStyle(
                color: Color(0xFF64748B),
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(width: 8),
          ElevatedButton(
            onPressed: () {
              if (reasonController.text.trim().isEmpty) return;
              Navigator.of(context).pop(reasonController.text.trim());
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFEF4444),
              foregroundColor: Colors.white,
              elevation: 0,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: const Text(
              'ELIMINAR PRODUCTO',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );

    if (reason != null && reason.isNotEmpty) {
      await widget.onDelete(reason);
      if (mounted) Navigator.of(context).pop();
    }
  }

  Future<String?> _promptReductionReason() async {
    final controller = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Motivo de reducción'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 3,
          decoration: const InputDecoration(
            hintText: 'Explica por qué se está reduciendo la cantidad...',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () {
              final value = controller.text.trim();
              if (value.isEmpty) return;
              Navigator.of(context).pop(value);
            },
            child: const Text('Confirmar'),
          ),
        ],
      ),
    );
    controller.dispose();
    return reason;
  }

  Future<void> _handleSave() async {
    if (_isSaving) return;

    final originalQuantity = _scopedItems.fold<double>(
      0,
      (sum, item) => sum + item.quantity,
    );
    String? reductionReason;
    if (_quantity < originalQuantity - 0.0001) {
      reductionReason = await _promptReductionReason();
      if (reductionReason == null || reductionReason.trim().isEmpty) {
        return;
      }
    }

    final discount = _effectiveDiscount();
    final baseNotes = _notesController.text.trim();
    final courtesyReason = _isCourtesy
        ? _courtesyReasonController.text.trim()
        : '';
    final noteParts = <String>[];
    // Preservar el marcador de oferta (se ocultó del campo editable).
    if (_dealMarker != null && _dealMarker!.isNotEmpty) {
      noteParts.add(_dealMarker!);
    }
    if (baseNotes.isNotEmpty) {
      noteParts.add(baseNotes);
    }
    if (_isCourtesy && _courtesyReasonController.text.isNotEmpty) {
      noteParts.add('$_courtesyPrefix$courtesyReason]');
    }
    final finalNotes = noteParts.join('\n');

    // El nombre del producto no se edita desde aquí — viene fijo del menú.
    final updated = widget.item.copyWith(
      quantity: _quantity,
      isTakeout: _isTakeout,
      discounts: discount,
      notes: finalNotes.isNotEmpty ? finalNotes : null,
    );

    setState(() {
      _isSaving = true;
    });
    try {
      if (_isGroupedMode && widget.onSaveBatch != null) {
        await widget.onSaveBatch!(_scopedItems, updated, reductionReason);
      } else {
        await widget.onSave(updated);
      }
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No se pudo guardar el producto: $e')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  Future<void> _handleEditModifiers() async {
    if (_isEditingModifiers ||
        widget.item.productId == null ||
        widget.loadModifierGroups == null ||
        widget.onReplaceModifiers == null ||
        _isGroupedMode) {
      return;
    }

    setState(() {
      _isEditingModifiers = true;
    });

    try {
      final groups = await widget.loadModifierGroups!(widget.item.productId!);
      if (!mounted) return;
      if (groups.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Este producto no tiene modificadores asignados.'),
          ),
        );
        return;
      }

      final result = await showDialog<List<SelectedModifierInput>>(
        context: context,
        builder: (_) => _ItemModifiersEditorDialog(
          product: MenuProduct(
            id: widget.item.productId!,
            name: widget.item.productName,
            price: widget.item.unitPrice,
            taxMode: widget.item.taxMode,
            taxRate: widget.item.taxRate,
            categoryId: '',
          ),
          groups: groups,
          existingModifiers: widget.item.modifiers,
        ),
      );
      if (!mounted || result == null) return;
      await widget.onReplaceModifiers!(widget.item.id, result);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Modificadores actualizados.')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isEditingModifiers = false;
        });
      }
    }
  }

  Future<void> _handleMarkSoldOut() async {
    if (widget.onMarkSoldOut == null || _isMarkingSoldOut) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Agotar producto'),
        content: const Text(
          'El producto dejará de estar disponible para nuevas ventas. La línea actual se conservará en la orden. ¿Deseas continuar?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Agotar'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() {
      _isMarkingSoldOut = true;
    });

    try {
      await widget.onMarkSoldOut!.call();
      if (!mounted) return;
      Navigator.of(context).pop();
    } finally {
      if (mounted) {
        setState(() {
          _isMarkingSoldOut = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Colors
    const kPrimary = Color(0xFFF97316);
    const kDangerRed = Color(0xFFEF4444);
    const kTextPrimary = Color(0xFF2C2C2C);
    const kTextSecondary = Color(0xFF6B7280);
    const kBorder = Color(0xFFE5E7EB);
    final isCompact = ResponsiveHelper.useCompactShell(context);
    final mq = MediaQuery.of(context);
    final previewSubtotal = _estimatedSubtotal();
    final previewTax = _estimatedTax();
    final previewDiscount = _effectiveDiscount();
    final previewTotal = (previewSubtotal + previewTax - previewDiscount)
        .clamp(0, double.infinity)
        .toDouble();

    return Dialog(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      insetPadding: isCompact
          ? const EdgeInsets.symmetric(horizontal: 8, vertical: 16)
          : const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 950,
          maxHeight: mq.size.height * 0.92,
        ),
        child: SingleChildScrollView(
          padding: EdgeInsets.symmetric(
            horizontal: isCompact ? 14 : 20,
            vertical: 16,
          ),
          child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              // Header
              Row(
                children: [
                  const Icon(Icons.restaurant_menu, color: kPrimary, size: 28),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      widget.item.productName,
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: kTextPrimary,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(
                      Icons.close,
                      color: kTextSecondary,
                      size: 24,
                    ),
                  ),
                ],
              ),
              const Divider(height: 20, color: kBorder),

              // Content Scrollable if needed, but Dialog fits.
              // Detalle del pedido
              const Text(
                'Detalle del pedido',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: kTextPrimary,
                ),
              ),
              const SizedBox(height: 8),

              Builder(
                builder: (_) {
                  final cantidadBlock = Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Cantidad',
                        style: TextStyle(
                          fontSize: 14,
                          color: kTextSecondary,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        height: 48,
                        decoration: BoxDecoration(
                          color: const Color(0xFFF3F4F6),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              onPressed: _decrementQty,
                              icon: const Icon(Icons.remove, size: 20),
                              color: kTextSecondary,
                            ),
                            Container(
                              color: Colors.white,
                              width: 45,
                              height: 40,
                              margin: const EdgeInsets.symmetric(vertical: 4),
                              alignment: Alignment.center,
                              child: Text(
                                _quantity == _quantity.roundToDouble()
                                    ? _quantity.toStringAsFixed(0)
                                    : _quantity.toStringAsFixed(2),
                                style: const TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            IconButton(
                              onPressed: _incrementQty,
                              icon: const Icon(Icons.add, size: 20),
                              color: kPrimary,
                            ),
                          ],
                        ),
                      ),
                      if (_isGroupedMode)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            'Cantidad total agrupada',
                            style: TextStyle(
                              fontSize: 11,
                              color: kTextSecondary.withValues(alpha: 0.9),
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                    ],
                  );
                  final precioBlock = Column(
                    crossAxisAlignment: isCompact
                        ? CrossAxisAlignment.start
                        : CrossAxisAlignment.end,
                    children: [
                      const Text(
                        'Precio und.',
                        style: TextStyle(
                          fontSize: 14,
                          color: kTextSecondary,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Text(
                            'RD\$',
                            style: TextStyle(
                              fontSize: isCompact ? 14 : 18,
                              fontWeight: FontWeight.bold,
                              color: kTextPrimary.withValues(alpha: 0.8),
                            ),
                          ),
                          Text(
                            widget.item.unitPrice.toStringAsFixed(2),
                            style: TextStyle(
                              fontSize: isCompact ? 26 : 36,
                              fontWeight: FontWeight.w900,
                              color: kTextPrimary,
                              letterSpacing: -1,
                            ),
                          ),
                        ],
                      ),
                      Container(height: 1, width: isCompact ? 100 : 140, color: kBorder),
                    ],
                  );
                  if (isCompact) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        cantidadBlock,
                        const SizedBox(height: 12),
                        precioBlock,
                      ],
                    );
                  }
                  return Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [cantidadBlock, precioBlock],
                  );
                },
              ),
              const SizedBox(height: 12),

              // Notas y switch takeout
              Builder(
                builder: (_) {
                  final notasBlock = Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Notas del pedido',
                        style: TextStyle(
                          fontSize: 14,
                          color: kTextSecondary,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      if (_dealMarker != null) ...[
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFFF1E6),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: const Color(0xFFFCD9BD)),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: const [
                              Icon(Icons.local_offer,
                                  size: 16, color: kPrimary),
                              SizedBox(width: 6),
                              Text(
                                'Oferta aplicada',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: kPrimary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: 8),
                      TextField(
                        controller: _notesController,
                        maxLines: 2,
                        decoration: InputDecoration(
                          hintText: 'Por ej: Caliente, con ají, sin sal...',
                          hintStyle: const TextStyle(
                            color: Color(0xFF9CA3AF),
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: const BorderSide(color: kBorder),
                          ),
                        ),
                      ),
                    ],
                  );
                  final takeoutBlock = Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        '¿Tu pedido es para llevar?',
                        style: TextStyle(
                          fontSize: 14,
                          color: kTextPrimary,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Switch(
                        value: _isTakeout,
                        onChanged: (val) {
                          setState(() => _isTakeout = val);
                        },
                        activeThumbColor: Colors.white,
                        activeTrackColor: kPrimary,
                        inactiveTrackColor: const Color(0xFFD1D5DB),
                        inactiveThumbColor: const Color(0xFF6B7280),
                      ),
                    ],
                  );
                  if (isCompact) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        notasBlock,
                        const SizedBox(height: 12),
                        takeoutBlock,
                      ],
                    );
                  }
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: notasBlock),
                      const SizedBox(width: 24),
                      Padding(
                        padding: const EdgeInsets.only(top: 28),
                        child: takeoutBlock,
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 12),

              if (!_isGroupedMode && widget.item.productId != null) ...[
                Row(
                  children: [
                    const Text(
                      'Modificadores',
                      style: TextStyle(
                        fontSize: 14,
                        color: kTextPrimary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const Spacer(),
                    OutlinedButton.icon(
                      onPressed: _isEditingModifiers
                          ? null
                          : _handleEditModifiers,
                      icon: _isEditingModifiers
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.tune, size: 16),
                      label: const Text('Editar modificadores'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (widget.item.modifiers.isEmpty)
                  const Text(
                    'Este item no tiene modificadores seleccionados.',
                    style: TextStyle(fontSize: 13, color: kTextSecondary),
                  )
                else
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: widget.item.modifiers
                        .map((modifier) {
                          final hasCost = modifier.price > 0.009;
                          final isComboChoice = modifier.name.contains(': ');
                          // qty efectiva del modifier en este item:
                          // item.quantity * modifier.qty. Refleja el "7×" en
                          // el chip cuando el item tiene cantidad multiple.
                          final itemQty = _quantity <= 0 ? 1.0 : _quantity;
                          final effectiveQty = itemQty * modifier.qty;
                          final totalCost = modifier.price * effectiveQty;
                          final qtyPrefix = effectiveQty > 1.0001
                              ? '${effectiveQty.toStringAsFixed(effectiveQty % 1 == 0 ? 0 : 1)}× '
                              : '';
                          final priceLabel = hasCost
                              ? ' (+RD\$ ${totalCost.toStringAsFixed(2)})'
                              : '';
                          return Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: isComboChoice
                                  ? const Color(0xFFFFF7ED)
                                  : const Color(0xFFF8FAFC),
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(
                                color: isComboChoice
                                    ? const Color(0xFFFED7AA)
                                    : kBorder,
                              ),
                            ),
                            child: Text(
                              '$qtyPrefix${modifier.name}$priceLabel',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: isComboChoice
                                    ? const Color(0xFF9A3412)
                                    : const Color(0xFF475569),
                              ),
                            ),
                          );
                        })
                        .toList(growable: false),
                  ),
                const SizedBox(height: 12),
              ],

              // Cortesía
              Row(
                children: [
                  const Text(
                    '¿Deseas aplicar una cortesía?',
                    style: TextStyle(
                      fontSize: 14,
                      color: kTextPrimary,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Switch(
                    value: _isCourtesy,
                    onChanged: (val) {
                      setState(() => _isCourtesy = val);
                    },
                    activeThumbColor: Colors.white,
                    activeTrackColor: kPrimary,
                    inactiveTrackColor: const Color(0xFFD1D5DB),
                    inactiveThumbColor: const Color(0xFF6B7280),
                  ),
                ],
              ),
              if (_isCourtesy) ...[
                const SizedBox(height: 8),
                TextField(
                  controller: _courtesyReasonController,
                  decoration: InputDecoration(
                    hintText: 'Ingrese el motivo de la cortesía',
                    hintStyle: const TextStyle(color: Color(0xFF9CA3AF)),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: kBorder),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 12), // Reduced from 20 to 12

              const SizedBox(height: 8), // Reduced from 16 to 8
              const Text(
                'Descuento aplicado al pedido',
                style: TextStyle(
                  fontSize: 14,
                  color: kTextPrimary,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  SizedBox(
                    width: 220,
                    child: TextField(
                      controller: _discountController,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: InputDecoration(
                        prefixText: 'RD\$ ',
                        labelText: 'Descuento manual',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: const BorderSide(color: kBorder),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: const BorderSide(color: kBorder),
                        ),
                        isDense: true,
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: kBorder),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _PreviewRow(
                      label: 'Subtotal estimado',
                      value: previewSubtotal,
                    ),
                    const SizedBox(height: 6),
                    _PreviewRow(
                      label: 'Impuestos estimados',
                      value: previewTax,
                    ),
                    const SizedBox(height: 6),
                    _PreviewRow(
                      label: _isCourtesy ? 'Cortesía total' : 'Descuento',
                      value: -previewDiscount,
                      valueColor: const Color(0xFF16A34A),
                    ),
                    const Divider(height: 20),
                    _PreviewRow(
                      label: 'Total estimado del item',
                      value: previewTotal,
                      isBold: true,
                      valueColor: kTextPrimary,
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 12),
              const Divider(color: kBorder, height: 1),

              // Footer Actions — en móvil: CTA Guardar full-width + menú
              // overflow con secundarias. En desktop: Row con todos los botones.
              if (isCompact)
                _MobileFooter(
                  isSaving: _isSaving,
                  onSave: _handleSave,
                  onCancel: () => Navigator.of(context).pop(),
                  onMarkSoldOut: widget.item.productId == null
                      ? null
                      : _handleMarkSoldOut,
                  onReprint: widget.onReprint,
                  onDelete: _handleDelete,
                  primaryColor: kPrimary,
                )
              else
                Container(
                  padding: const EdgeInsets.only(top: 0),
                  child: IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: _ModalButton(
                            icon: Icons.close,
                            label: 'Cancelar',
                            color: kTextPrimary,
                            onTap: () => Navigator.of(context).pop(),
                          ),
                        ),
                        const VerticalDivider(width: 1, color: kBorder),
                        Expanded(
                          child: _ModalButton(
                            icon: Icons.warning_amber_rounded,
                            label: 'Agotar producto',
                            color: widget.item.productId == null
                                ? kTextSecondary
                                : kDangerRed,
                            onTap: widget.item.productId == null
                                ? null
                                : _handleMarkSoldOut,
                          ),
                        ),
                        const VerticalDivider(width: 1, color: kBorder),
                        if (widget.onReprint != null) ...[
                          Expanded(
                            child: _ModalButton(
                              icon: Icons.print_outlined,
                              label: 'Reimprimir comanda',
                              color: const Color(0xFF2563EB),
                              onTap: widget.onReprint,
                            ),
                          ),
                          const VerticalDivider(width: 1, color: kBorder),
                        ],
                        Expanded(
                          child: _ModalButton(
                            icon: Icons.delete_outline,
                            label: 'Eliminar pedido',
                            color: kDangerRed,
                            onTap: _handleDelete,
                          ),
                        ),
                        const VerticalDivider(width: 1, color: kBorder),
                        Expanded(
                          child: Container(
                            height: double.infinity,
                            padding: const EdgeInsets.all(8),
                            child: ElevatedButton.icon(
                              onPressed: _isSaving ? null : _handleSave,
                              icon: const Icon(
                                Icons.check_circle_outline,
                                size: 24,
                              ),
                              label: Text(
                                _isSaving ? 'Guardando...' : 'Guardar cambios',
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: kPrimary,
                                elevation: 0,
                                foregroundColor: Colors.white,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Costo agregado de modifiers por UNA unidad del item parent.
  /// `modifier.qty` representa "cuantos modifiers de este tipo por unidad".
  double _modifiersPerUnit() => widget.item.modifiers.fold(
    0.0,
    (sum, modifier) => sum + (modifier.price * modifier.qty),
  );

  /// Subtotal estimado para `quantity` unidades del item, usando la formula
  /// per-unit alineada con el trigger backend fn_compute_item_totals
  /// (migration 20260509_0004).
  double _baseSubtotalForQuantity(double quantity) {
    final q = quantity <= 0 ? 1.0 : quantity;
    return q * (widget.item.unitPrice + _modifiersPerUnit());
  }

  double _estimatedSubtotal() {
    final rawAmount = _baseSubtotalForQuantity(_quantity);
    if (widget.item.taxMode == 'inclusive') {
      final divisor = 1 + _fullTaxRateDecimal();
      if (divisor <= 0) return rawAmount;
      return rawAmount / divisor;
    }
    return rawAmount;
  }

  double _taxRateDecimal() {
    if (widget.item.taxRate > 0) return widget.item.taxRate / 100.0;
    if (widget.item.subtotal <= 0) return 0;
    return widget.item.tax / widget.item.subtotal;
  }

  double _fullTaxRateDecimal() {
    final rawFullRate = widget.item.originalTaxRate ?? widget.item.taxRate;
    if (rawFullRate > 0) return rawFullRate / 100.0;
    return _taxRateDecimal();
  }

  double _estimatedTax() {
    final rawAmount = _baseSubtotalForQuantity(_quantity);
    // Usamos la tasa COMPLETA (ITBIS + Propina Ley) para que
    // "Impuestos estimados" + subtotal = precio mostrado del producto.
    // Antes usabamos solo taxRate (18%), lo que dejaba fuera la propina y
    // hacia que "Total estimado del item" saliera menor al precio del menu.
    final fullRate = _fullTaxRateDecimal();
    if (widget.item.taxMode == 'inclusive') {
      return _estimatedSubtotal() * fullRate;
    }
    // Exclusive: el impuesto va sobre la base NETA (después del descuento /
    // oferta 4x3), igual que el cobro real del backend (28% de 750 = 210, NO
    // de 1000 = 280). Antes usaba el bruto y mostraba impuesto y "Total
    // estimado del item" inflados en ítems con descuento. Solo afecta el
    // preview del diálogo; el cobro lo computa el trigger backend y ya era
    // correcto.
    final netAmount = (rawAmount - _effectiveDiscount())
        .clamp(0, double.infinity)
        .toDouble();
    return netAmount * fullRate;
  }

  double _fullAmountForQuantity(double quantity) {
    if (widget.item.taxMode == 'inclusive') {
      return _baseSubtotalForQuantity(quantity);
    }
    final subtotal = _baseSubtotalForQuantity(quantity);
    final tax = subtotal * _taxRateDecimal();
    return subtotal + tax;
  }

  double _initialManualDiscount() {
    if (_isFullCourtesyDiscount(widget.item.discounts)) {
      return 0;
    }
    return widget.item.discounts;
  }

  bool _isFullCourtesyDiscount(double discounts) {
    final fullAmount = _fullAmountForQuantity(widget.item.quantity);
    return fullAmount > 0 && discounts >= (fullAmount - 0.01);
  }

  double _enteredDiscount() {
    final parsed = double.tryParse(
      _discountController.text.replaceAll(',', '.'),
    );
    if (parsed == null || parsed < 0) return 0;
    return parsed;
  }

  double _effectiveDiscount() {
    if (_isCourtesy) {
      return _fullAmountForQuantity(_quantity);
    }
    return _enteredDiscount().clamp(0, _fullAmountForQuantity(_quantity));
  }

  ({String notes, String? courtesyReason, String? dealMarker}) _splitStoredNotes(
    String? rawNotes,
  ) {
    if (rawNotes == null || rawNotes.trim().isEmpty) {
      return (notes: '', courtesyReason: null, dealMarker: null);
    }

    final lines = rawNotes
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();

    String? courtesyReason;
    String? dealMarker;
    final visibleNotes = <String>[];

    for (final line in lines) {
      if (line.startsWith(_courtesyPrefix) && line.endsWith(']')) {
        courtesyReason = line
            .substring(_courtesyPrefix.length, line.length - 1)
            .trim();
      } else if (line.startsWith('[DEAL:') && line.endsWith(']')) {
        // Marcador de oferta: no es nota humana, se oculta del campo editable.
        dealMarker = line;
      } else {
        visibleNotes.add(line);
      }
    }

    return (
      notes: visibleNotes.join('\n'),
      courtesyReason: courtesyReason,
      dealMarker: dealMarker,
    );
  }
}

class _ModalButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback? onTap;

  const _ModalButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              color: onTap == null ? const Color(0xFF9CA3AF) : color,
              size: 24,
            ),
            const SizedBox(height: 6),
            Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: onTap == null ? const Color(0xFF9CA3AF) : color,
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PreviewRow extends StatelessWidget {
  final String label;
  final double value;
  final bool isBold;
  final Color? valueColor;

  const _PreviewRow({
    required this.label,
    required this.value,
    this.isBold = false,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    final prefix = value < 0 ? '-RD\$' : 'RD\$';
    final amount = value.abs().toStringAsFixed(2);
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            fontWeight: isBold ? FontWeight.w700 : FontWeight.w500,
            color: const Color(0xFF475569),
          ),
        ),
        Text(
          '$prefix$amount',
          style: TextStyle(
            fontWeight: isBold ? FontWeight.w800 : FontWeight.w600,
            color: valueColor ?? const Color(0xFF0F172A),
          ),
        ),
      ],
    );
  }
}

/// Footer móvil compacto: botón Guardar a ancho completo + menú overflow
/// con las acciones secundarias (Cancelar / Agotar / Reimprimir / Eliminar).
class _MobileFooter extends StatelessWidget {
  const _MobileFooter({
    required this.isSaving,
    required this.onSave,
    required this.onCancel,
    required this.onMarkSoldOut,
    required this.onReprint,
    required this.onDelete,
    required this.primaryColor,
  });

  final bool isSaving;
  final VoidCallback onSave;
  final VoidCallback onCancel;
  final VoidCallback? onMarkSoldOut;
  final VoidCallback? onReprint;
  final VoidCallback onDelete;
  final Color primaryColor;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Expanded(
            child: SizedBox(
              height: 48,
              child: ElevatedButton.icon(
                onPressed: isSaving ? null : onSave,
                icon: const Icon(Icons.check_circle_outline, size: 22),
                label: Text(
                  isSaving ? 'Guardando...' : 'Guardar cambios',
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: primaryColor,
                  elevation: 0,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Container(
            height: 48,
            width: 48,
            decoration: BoxDecoration(
              color: const Color(0xFFF3F4F6),
              borderRadius: BorderRadius.circular(8),
            ),
            child: PopupMenuButton<String>(
              tooltip: 'Más acciones',
              icon: const Icon(Icons.more_vert, color: Color(0xFF6B7280)),
              onSelected: (v) {
                switch (v) {
                  case 'cancel':
                    onCancel();
                    break;
                  case 'soldout':
                    onMarkSoldOut?.call();
                    break;
                  case 'reprint':
                    onReprint?.call();
                    break;
                  case 'delete':
                    onDelete();
                    break;
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: 'cancel',
                  child: ListTile(
                    leading: Icon(Icons.close, color: Color(0xFF6B7280)),
                    title: Text('Cancelar'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                if (onMarkSoldOut != null)
                  const PopupMenuItem(
                    value: 'soldout',
                    child: ListTile(
                      leading: Icon(Icons.warning_amber_rounded,
                          color: Color(0xFFEF4444)),
                      title: Text('Agotar producto'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                if (onReprint != null)
                  const PopupMenuItem(
                    value: 'reprint',
                    child: ListTile(
                      leading: Icon(Icons.print_outlined,
                          color: Color(0xFF2563EB)),
                      title: Text('Reimprimir comanda'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                const PopupMenuDivider(),
                const PopupMenuItem(
                  value: 'delete',
                  child: ListTile(
                    leading: Icon(Icons.delete_outline,
                        color: Color(0xFFEF4444)),
                    title: Text('Eliminar pedido',
                        style: TextStyle(color: Color(0xFFEF4444))),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SalesModifierDialogHeader extends StatelessWidget {
  final String title;
  final String subtitle;

  const _SalesModifierDialogHeader({
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: const Color(0xFFF97316).withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(16),
          ),
          child: const Icon(Icons.tune_rounded, color: Color(0xFFF97316)),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF111827),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                subtitle,
                style: const TextStyle(
                  fontSize: 13,
                  color: Color(0xFF6B7280),
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ItemModifiersEditorDialog extends StatefulWidget {
  final MenuProduct product;
  final List<Map<String, dynamic>> groups;
  final List<OrderItemModifier> existingModifiers;

  const _ItemModifiersEditorDialog({
    required this.product,
    required this.groups,
    required this.existingModifiers,
  });

  @override
  State<_ItemModifiersEditorDialog> createState() =>
      _ItemModifiersEditorDialogState();
}

class _ItemModifiersEditorDialogState
    extends State<_ItemModifiersEditorDialog> {
  final Map<String, Set<String>> _selectedByGroup = <String, Set<String>>{};

  @override
  void initState() {
    super.initState();
    final existingNames = widget.existingModifiers.map((m) => m.name).toSet();
    for (final row in widget.groups) {
      final group = Map<String, dynamic>.from(row['modifier_groups'] as Map);
      final groupId = group['id']?.toString() ?? '';
      final modifiers = ((group['modifiers'] as List?) ?? const [])
          .map((item) => Map<String, dynamic>.from(item as Map))
          .where((item) => item['is_active'] != false)
          .toList(growable: false);
      final selected = modifiers
          .where(
            (item) => existingNames.contains(item['name']?.toString() ?? ''),
          )
          .map((item) => item['id']?.toString() ?? '')
          .where((id) => id.isNotEmpty)
          .toSet();
      _selectedByGroup[groupId] = selected;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFFFFFFFF),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720, maxHeight: 760),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SalesModifierDialogHeader(
                title: 'Editar modificadores · ${widget.product.name}',
                subtitle:
                    'Actualiza la selección de opciones del artículo actual.',
              ),
              const SizedBox(height: 18),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    children: widget.groups
                        .map((row) {
                          final group = Map<String, dynamic>.from(
                            row['modifier_groups'] as Map,
                          );
                          final groupId = group['id']?.toString() ?? '';
                          final displayType =
                              group['display_type']?.toString() ?? 'multiple';
                          final maxSelect =
                              (group['max_select'] as num?)?.toInt() ?? 0;
                          final modifiers =
                              ((group['modifiers'] as List?) ?? const [])
                                  .map(
                                    (item) =>
                                        Map<String, dynamic>.from(item as Map),
                                  )
                                  .where((item) => item['is_active'] != false)
                                  .toList(growable: false);
                          final selected =
                              _selectedByGroup[groupId] ?? <String>{};
                          return Container(
                            width: double.infinity,
                            margin: const EdgeInsets.only(bottom: 12),
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFFFFFF),
                              border: Border.all(
                                color: const Color(0xFFE2E8F0),
                              ),
                              borderRadius: BorderRadius.circular(18),
                              boxShadow: const [
                                BoxShadow(
                                  color: Color(0x10000000),
                                  blurRadius: 6,
                                  offset: Offset(0, 2),
                                ),
                              ],
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        group['name']?.toString() ?? 'Grupo',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w800,
                                          fontSize: 15,
                                        ),
                                      ),
                                    ),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 10,
                                        vertical: 6,
                                      ),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFF3F4F6),
                                        borderRadius: BorderRadius.circular(
                                          999,
                                        ),
                                      ),
                                      child: Text(
                                        displayType == 'single'
                                            ? '1 opción'
                                            : 'Múltiple',
                                        style: const TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w700,
                                          color: Color(0xFF6B7280),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 10),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: modifiers
                                      .map((modifier) {
                                        final modifierId =
                                            modifier['id']?.toString() ?? '';
                                        final price =
                                            (modifier['price_delta'] as num?)
                                                ?.toDouble() ??
                                            0.0;
                                        final isSelected = selected.contains(
                                          modifierId,
                                        );
                                        return FilterChip(
                                          selected: isSelected,
                                          showCheckmark: false,
                                          selectedColor: const Color(
                                            0xFFFFEDD5,
                                          ),
                                          backgroundColor: const Color(
                                            0xFFF8FAFC,
                                          ),
                                          side: BorderSide(
                                            color: isSelected
                                                ? const Color(0xFFF97316)
                                                : const Color(0xFFE2E8F0),
                                            width: isSelected ? 1.5 : 1,
                                          ),
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(
                                              14,
                                            ),
                                          ),
                                          avatar: Icon(
                                            isSelected
                                                ? Icons.check_circle_rounded
                                                : Icons
                                                      .add_circle_outline_rounded,
                                            size: 18,
                                            color: isSelected
                                                ? const Color(0xFFF97316)
                                                : const Color(0xFF9CA3AF),
                                          ),
                                          labelStyle: TextStyle(
                                            color: isSelected
                                                ? const Color(0xFF9A3412)
                                                : const Color(0xFF111827),
                                            fontWeight: FontWeight.w600,
                                          ),
                                          label: Text(
                                            price > 0
                                                ? '${modifier['name']} (+RD\$ ${price.toStringAsFixed(2)})'
                                                : '${modifier['name']}',
                                          ),
                                          onSelected: (_) {
                                            setState(() {
                                              final set = _selectedByGroup
                                                  .putIfAbsent(
                                                    groupId,
                                                    () => <String>{},
                                                  );
                                              if (displayType == 'single') {
                                                if (set.contains(modifierId)) {
                                                  set.clear();
                                                } else {
                                                  set
                                                    ..clear()
                                                    ..add(modifierId);
                                                }
                                              } else {
                                                if (set.contains(modifierId)) {
                                                  set.remove(modifierId);
                                                } else {
                                                  if (maxSelect > 0 &&
                                                      set.length >= maxSelect) {
                                                    return;
                                                  }
                                                  set.add(modifierId);
                                                }
                                              }
                                            });
                                          },
                                        );
                                      })
                                      .toList(growable: false),
                                ),
                              ],
                            ),
                          );
                        })
                        .toList(growable: false),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancelar'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: () {
                      final result = <SelectedModifierInput>[];
                      for (final row in widget.groups) {
                        final group = Map<String, dynamic>.from(
                          row['modifier_groups'] as Map,
                        );
                        final groupId = group['id']?.toString() ?? '';
                        final selected =
                            _selectedByGroup[groupId] ?? <String>{};
                        final modifiers =
                            ((group['modifiers'] as List?) ?? const [])
                                .map(
                                  (item) =>
                                      Map<String, dynamic>.from(item as Map),
                                )
                                .where(
                                  (item) => selected.contains(
                                    item['id']?.toString() ?? '',
                                  ),
                                );
                        for (final modifier in modifiers) {
                          result.add(
                            SelectedModifierInput(
                              name:
                                  modifier['name']?.toString() ?? 'Modificador',
                              qty: 1,
                              price:
                                  (modifier['price_delta'] as num?)
                                      ?.toDouble() ??
                                  0.0,
                            ),
                          );
                        }
                      }
                      Navigator.of(context).pop(result);
                    },
                    icon: const Icon(Icons.save_outlined, size: 18),
                    label: const Text('Guardar cambios'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
