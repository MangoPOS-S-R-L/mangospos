import 'package:flutter/material.dart';
import '../../../../data/models/sales_models.dart';

class ProductDetailModal extends StatefulWidget {
  final OrderItem item;
  final Future<void> Function(OrderItem updatedItem) onSave;
  final Future<void> Function(String reason) onDelete;
  final Future<void> Function()? onMarkSoldOut;
  final VoidCallback? onReprint;

  const ProductDetailModal({
    super.key,
    required this.item,
    required this.onSave,
    required this.onDelete,
    this.onMarkSoldOut,
    this.onReprint,
  });

  @override
  State<ProductDetailModal> createState() => _ProductDetailModalState();
}

class _ProductDetailModalState extends State<ProductDetailModal> {
  static const _courtesyPrefix = '[CORTESIA:';

  late TextEditingController _nameController;
  late TextEditingController _notesController;
  late TextEditingController _courtesyReasonController;
  late TextEditingController _discountController;

  late double _quantity;
  late bool _isTakeout;
  late bool _isCourtesy;
  bool _isMarkingSoldOut = false;
  bool _isSaving = false;

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

    _quantity = widget.item.quantity;
    _isTakeout = widget.item.isTakeout;
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

  void _incrementQty() {
    setState(() {
      _quantity++;
    });
  }

  void _decrementQty() {
    if (_quantity > 1) {
      setState(() {
        _quantity--;
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
                color: Colors.red.withOpacity(0.1),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.delete_outline, color: Colors.red, size: 24),
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
              autofocus: true,
              decoration: InputDecoration(
                filled: true,
                fillColor: const Color(0xFFF8FAFC),
                hintText: 'Ej: Error de digitación, Cliente cambió de opinión...',
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
              style: TextStyle(color: Color(0xFF64748B), fontWeight: FontWeight.bold),
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
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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

  Future<void> _handleSave() async {
    if (_isSaving) return;

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
      await widget.onSave(updated);
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
                      icon: const Icon(Icons.close, color: kTextSecondary, size: 24),
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
                                  _quantity.toStringAsFixed(0),
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
                                color: kTextPrimary.withOpacity(0.8),
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
                              hintText:
                                  'Por ejm: Caliente, con ají, sin sal...',
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
                    TextButton.icon(
                      onPressed: () {}, // TODO: Implementar selección de descuento
                      icon: const Icon(Icons.add_circle_outline, size: 18),
                      label: const Text('Aplicar descuento a producto'),
                      style: TextButton.styleFrom(
                        foregroundColor: kPrimary,
                        padding: EdgeInsets.zero,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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
                            icon: const Icon(Icons.check_circle_outline, size: 24),
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
