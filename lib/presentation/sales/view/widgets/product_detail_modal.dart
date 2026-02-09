import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../../data/models/sales_models.dart';

class ProductDetailModal extends StatefulWidget {
  final OrderItem item;
  final Function(OrderItem updatedItem) onSave;
  final VoidCallback onDelete;

  const ProductDetailModal({
    super.key,
    required this.item,
    required this.onSave,
    required this.onDelete,
  });

  @override
  State<ProductDetailModal> createState() => _ProductDetailModalState();
}

class _ProductDetailModalState extends State<ProductDetailModal> {
  late TextEditingController _nameController;
  late TextEditingController _notesController;
  late TextEditingController _courtesyReasonController;

  late double _quantity;
  late bool _isTakeout;
  late bool _isCourtesy;

  // To handle discounts, we might need more state, or a separate dialog.
  // For now, I'll implement the main fields shown in the screenshot.

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.item.productName);
    _notesController = TextEditingController(text: widget.item.notes ?? '');
    _courtesyReasonController = TextEditingController();

    _quantity = widget.item.quantity;
    _isTakeout = widget.item.isTakeout;

    // Simple heuristic for courtesy: if price is 0 (and it wasn't validly 0?), or if we have a flag.
    // Since we don't have a flag, we'll start false.
    _isCourtesy = false;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _notesController.dispose();
    _courtesyReasonController.dispose();
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

  void _handleSave() {
    // Recalculate totals if quantity changed
    // This simple logic assumes unitPrice stays constant unless courtesy.
    // If courtesy, unitPrice might effectively be 0 or 100% discount.

    // Logic for Courtesy (if strictly visual or affects price)
    // If courtesy is applied, usually total becomes 0.
    // Let's implement it as 100% discount for now for simplicity, or just ignore if backend handles it.
    // Re-calculating totals is complex without tax rules.
    // Ideally, we pass the "intent" to the ViewModel and let it recalculate.
    // So 'onSave' should pass back the edited fields and the VM recalculates.
    // But the signature expects 'OrderItem'.
    // I'll update what I can.

    // Notes
    String finalNotes = _notesController.text.trim();
    if (_isCourtesy && _courtesyReasonController.text.isNotEmpty) {
      finalNotes += "\n[Cortesía: ${_courtesyReasonController.text.trim()}]";
      // Apply 100% discount logic?
      // finalDiscounts = unitPrice * _quantity; // Assuming subtotal ~ total
    }

    final updated = widget.item.copyWith(
      productName: _nameController.text.trim(),
      quantity: _quantity,
      isTakeout: _isTakeout,
      notes: finalNotes.isNotEmpty ? finalNotes : null,
      // We are NOT recalculating totals here to avoid desync with backend rules.
      // The ViewModel should handle recalculation when it receives the updated item.
    );

    widget.onSave(updated);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    // Colors
    const kPrimaryBlue = Color(0xFF3B82F6);
    const kDangerRed = Color(0xFFEF4444);
    const kTextPrimary = Color(0xFF1F2937);
    const kTextSecondary = Color(0xFF6B7280);
    const kBorder = Color(0xFFE5E7EB);

    return Dialog(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        width: 600,
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              children: [
                const Icon(Icons.restaurant_menu, color: kPrimaryBlue),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    widget.item.productName,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: kTextPrimary,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close, color: kTextSecondary),
                ),
              ],
            ),
            const Divider(height: 32, color: kBorder),

            // Content Scrollable if needed, but Dialog fits.
            // Detalle del pedido
            const Text(
              'Detalle del pedido',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: kTextPrimary,
              ),
            ),
            const SizedBox(height: 16),

            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // Nombre de reemplazo
                Expanded(
                  flex: 5,
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
                        decoration: InputDecoration(
                          border: OutlineInputBorder(
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
                        children: [
                          IconButton(
                            onPressed: _decrementQty,
                            icon: const Icon(Icons.remove, size: 18),
                            color: kTextSecondary,
                          ),
                          Container(
                            color: Colors.white,
                            width: 40,
                            alignment: Alignment.center,
                            child: Text(
                              _quantity.toStringAsFixed(0),
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          IconButton(
                            onPressed: _incrementQty,
                            icon: const Icon(Icons.add, size: 18),
                            color: kPrimaryBlue,
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
                    const SizedBox(height: 8),
                    Text(
                      'RD\$${widget.item.unitPrice.toStringAsFixed(2)}',
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: kTextPrimary,
                      ),
                    ),
                    const SizedBox(height: 4), // Visual alignment
                    Container(height: 2, width: 100, color: kBorder),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 24),

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
                          hintStyle: const TextStyle(color: Color(0xFF9CA3AF)),
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
                        activeColor: kPrimaryBlue,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),

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
                  activeColor: kPrimaryBlue,
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
            const SizedBox(height: 20),

            // Descuento
            const Text(
              'Descuento aplicado al pedido',
              style: TextStyle(
                fontSize: 14,
                color: kTextPrimary,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 8),
            InkWell(
              onTap: () {
                // TODO: Implement discount logic
              },
              borderRadius: BorderRadius.circular(4),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: const [
                    Icon(
                      Icons.add_circle_outline,
                      color: Color(0xFFF97316),
                      size: 18,
                    ),
                    SizedBox(width: 6),
                    Text(
                      'Aplicar descuento a producto',
                      style: TextStyle(
                        color: Color(0xFFF97316),
                        fontWeight: FontWeight.w600,
                        decoration: TextDecoration.underline,
                        decorationColor: Color(0xFFF97316),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const Spacer(),
            const Divider(color: kBorder),
            const SizedBox(height: 16),

            // Footer Actions
            Row(
              children: [
                _ModalButton(
                  icon: Icons.close,
                  label: 'Cancelar',
                  color: kTextPrimary,
                  onTap: () => Navigator.of(context).pop(),
                ),
                const Spacer(),
                _ModalButton(
                  icon: Icons.warning_amber_rounded,
                  label: 'Agotar producto',
                  color: kDangerRed,
                  onTap: () {
                    // TODO
                  },
                ),
                const Spacer(),
                _ModalButton(
                  icon: Icons.delete_outline,
                  label: 'Eliminar pedido',
                  color: kDangerRed,
                  onTap: () {
                    widget.onDelete();
                    Navigator.of(context).pop();
                  },
                ),
                const Spacer(),
                ElevatedButton.icon(
                  onPressed: _handleSave,
                  icon: const Icon(Icons.save_rounded, size: 18), // Save icon
                  label: const Text('Guardar cambios'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: kPrimaryBlue,
                    foregroundColor: Colors.white,
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
      ),
    );
  }
}

class _ModalButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

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
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
