import 'package:flutter/material.dart';
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

  late TextEditingController _nameController;
  late TextEditingController _notesController;
  late TextEditingController _courtesyReasonController;
  late TextEditingController _discountController;

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
    _nameController = TextEditingController(text: widget.item.productName);
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
    _nameController.dispose();
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
    if (baseNotes.isNotEmpty) {
      noteParts.add(baseNotes);
    }
    if (_isCourtesy && _courtesyReasonController.text.isNotEmpty) {
      noteParts.add('$_courtesyPrefix$courtesyReason]');
    }
    final finalNotes = noteParts.join('\n');

    final updated = widget.item.copyWith(
      productName: _nameController.text.trim().isEmpty
          ? widget.item.productName
          : _nameController.text.trim(),
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
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 950,
          maxHeight: MediaQuery.of(context).size.height * 0.95,
        ),
        child: Container(
          width: double.maxFinite,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
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

              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  // Nombre de reemplazo
                  Expanded(
                    flex: 4,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Nombre de reemplazo',
                          style: TextStyle(
                            fontSize: 14,
                            color: kTextSecondary,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _nameController,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                          decoration: InputDecoration(
                            filled: true,
                            fillColor: const Color(0xFFF9FAFB),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: const BorderSide(color: kBorder),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: const BorderSide(color: kBorder),
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 14,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  // Cantidad
                  Column(
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
                    ],
                  ),
                  const SizedBox(width: 24),
                  if (_isGroupedMode)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Text(
                        'Cantidad total agrupada',
                        style: TextStyle(
                          fontSize: 12,
                          color: kTextSecondary.withValues(alpha: 0.9),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  // Precio und.
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
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
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Text(
                            'RD\$',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: kTextPrimary.withValues(alpha: 0.8),
                            ),
                          ),
                          Text(
                            widget.item.unitPrice.toStringAsFixed(2),
                            style: const TextStyle(
                              fontSize: 36,
                              fontWeight: FontWeight.w900,
                              color: kTextPrimary,
                              letterSpacing: -1,
                            ),
                          ),
                        ],
                      ),
                      Container(height: 1, width: 140, color: kBorder),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // Notas y switch takeout
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
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
                        const SizedBox(height: 8),
                        TextField(
                          controller: _notesController,
                          maxLines: 2,
                          decoration: InputDecoration(
                            hintText: 'Por ejm: Caliente, con ají, sin sal...',
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
                    ),
                  ),
                  const SizedBox(width: 24),
                  Padding(
                    padding: const EdgeInsets.only(top: 28),
                    child: Row(
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
                    ),
                  ),
                ],
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
                              hasCost
                                  ? '${modifier.name} (+RD\$ ${modifier.price.toStringAsFixed(2)})'
                                  : modifier.name,
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

              // Footer Actions
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

  double _modifiersTotal() => widget.item.modifiers.fold(
    0.0,
    (sum, modifier) => sum + (modifier.price * modifier.qty),
  );

  double _modifiersTotalForQuantity(double quantity) {
    final originalQty = widget.item.quantity <= 0 ? 1.0 : widget.item.quantity;
    final ratio = quantity / originalQty;
    return _modifiersTotal() * ratio;
  }

  double _baseSubtotalForQuantity(double quantity) =>
      (widget.item.unitPrice * quantity) + _modifiersTotalForQuantity(quantity);

  double _estimatedSubtotal() => _baseSubtotalForQuantity(_quantity);

  double _taxRate() {
    if (widget.item.subtotal <= 0) return 0;
    return widget.item.tax / widget.item.subtotal;
  }

  double _estimatedTax() => _baseSubtotalForQuantity(_quantity) * _taxRate();

  double _fullAmountForQuantity(double quantity) {
    final subtotal = _baseSubtotalForQuantity(quantity);
    final tax = subtotal * _taxRate();
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
    return _enteredDiscount().clamp(0, _estimatedSubtotal());
  }

  ({String notes, String? courtesyReason}) _splitStoredNotes(String? rawNotes) {
    if (rawNotes == null || rawNotes.trim().isEmpty) {
      return (notes: '', courtesyReason: null);
    }

    final lines = rawNotes
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();

    String? courtesyReason;
    final visibleNotes = <String>[];

    for (final line in lines) {
      if (line.startsWith(_courtesyPrefix) && line.endsWith(']')) {
        courtesyReason = line
            .substring(_courtesyPrefix.length, line.length - 1)
            .trim();
      } else {
        visibleNotes.add(line);
      }
    }

    return (notes: visibleNotes.join('\n'), courtesyReason: courtesyReason);
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
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680, maxHeight: 720),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Editar modificadores · ${widget.product.name}',
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 16),
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
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              border: Border.all(
                                color: const Color(0xFFE2E8F0),
                              ),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  group['name']?.toString() ?? 'Grupo',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                  ),
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
                                        return FilterChip(
                                          selected: selected.contains(
                                            modifierId,
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
                  FilledButton(
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
                    child: const Text('Guardar cambios'),
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
