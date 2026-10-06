import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../data/models/order_item_removal_reason.dart';
import '../../../../services/session/session_controller.dart';
import '../../viewmodel/sales_viewmodel.dart' show salesRepositoryProvider;

const _kDanger = Color(0xFFEF4444);
const _kMuted = Color(0xFF64748B);

/// Pregunta POR QUÉ se quita el producto y QUÉ pasa con el inventario.
///
/// Los dos POS grandes (Toast, Micros) hacen justo esto: una lista corta de
/// motivos que el dueño configuró en frío, y cada motivo ya trae la respuesta
/// de inventario. El cajero, a las 2 de la mañana, solo toca un botón; puede
/// cambiar el destino si ese caso fue distinto.
///
/// Devuelve `null` si se cancela.
Future<OrderItemRemovalDecision?> showRemovalReasonDialog(
  BuildContext context, {
  required String productName,
  required double quantity,

  /// La comanda ya salió: el producto pudo haberse preparado, así que el
  /// destino del inventario deja de ser obvio.
  bool alreadySent = false,

  /// El cajero escoge CUÁNTAS de las [quantity] unidades quita, con 1
  /// marcada. Sin esto, «Eliminar» sobre «6 × Presidente» borraba las seis
  /// aunque quisiera quitar una. Solo aplica si [quantity] es entera y > 1.
  bool chooseQuantity = false,

  /// Aviso de DÓNDE salen las unidades (p. ej. de qué subcuenta), según la
  /// cantidad elegida. `null` o texto `null` = no se muestra nada.
  String? Function(double quantity)? describeRemoval,
}) {
  return showDialog<OrderItemRemovalDecision>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _RemovalReasonDialog(
      productName: productName,
      quantity: quantity,
      alreadySent: alreadySent,
      chooseQuantity: chooseQuantity,
      describeRemoval: describeRemoval,
    ),
  );
}

class _RemovalReasonDialog extends ConsumerStatefulWidget {
  const _RemovalReasonDialog({
    required this.productName,
    required this.quantity,
    required this.alreadySent,
    required this.chooseQuantity,
    this.describeRemoval,
  });

  final String productName;
  final double quantity;
  final bool alreadySent;
  final bool chooseQuantity;
  final String? Function(double quantity)? describeRemoval;

  @override
  ConsumerState<_RemovalReasonDialog> createState() =>
      _RemovalReasonDialogState();
}

class _RemovalReasonDialogState extends ConsumerState<_RemovalReasonDialog> {
  final _note = TextEditingController();
  List<OrderItemRemovalReason> _reasons = OrderItemRemovalReason.defaults;
  OrderItemRemovalReason? _selected;
  bool? _isWasteOverride;

  /// Unidades a quitar. Con selector arranca en 1: quitar todas es la
  /// excepción y se pide a propósito con «Todas».
  late double _qty;

  bool get _canChoose =>
      widget.chooseQuantity &&
      widget.quantity >= 2 &&
      widget.quantity == widget.quantity.roundToDouble();

  @override
  void initState() {
    super.initState();
    _qty = _canChoose ? 1 : widget.quantity;
    _loadReasons();
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _loadReasons() async {
    final businessId = ref.read(sessionProvider).activeBusinessId;
    if (businessId == null || businessId.isEmpty) return;
    final reasons = await ref
        .read(salesRepositoryProvider)
        .getRemovalReasons(businessId);
    if (!mounted) return;
    setState(() {
      _reasons = reasons;
      if (_selected != null && !reasons.any((r) => r.code == _selected!.code)) {
        _selected = null;
      }
    });
  }

  bool get _isWaste => _isWasteOverride ?? _selected?.isWaste ?? false;

  @override
  Widget build(BuildContext context) {
    final selected = _selected;
    final removalWhere = widget.describeRemoval?.call(_qty);
    return AlertDialog(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: _kDanger.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.delete_outline, color: _kDanger, size: 24),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Text(
              'Quitar producto de la cuenta',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 19),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${_qtyLabel(_qty)} × ${widget.productName}',
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 15,
                ),
              ),
              if (_canChoose) ...[
                const SizedBox(height: 10),
                _quantityPicker(),
              ],
              if (removalWhere != null) ...[
                const SizedBox(height: 8),
                Text(
                  removalWhere,
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: Color(0xFFB45309),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
              if (widget.alreadySent) ...[
                const SizedBox(height: 6),
                const Text(
                  'La comanda ya salió a cocina.',
                  style: TextStyle(fontSize: 12.5, color: _kDanger),
                ),
              ],
              const SizedBox(height: 14),
              const Text(
                '¿Por qué se quita?',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final r in _reasons)
                    ChoiceChip(
                      label: Text(r.label),
                      selected: selected?.code == r.code,
                      onSelected: (_) => setState(() {
                        _selected = r;
                        // El motivo manda; si el cajero ya había tocado el
                        // destino, se respeta su elección.
                        _isWasteOverride = null;
                      }),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              const Text(
                '¿Qué pasa con el producto?',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5),
              ),
              const SizedBox(height: 8),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(
                    value: false,
                    icon: Icon(Icons.inventory_2_outlined, size: 18),
                    label: Text('Vuelve al inventario'),
                  ),
                  ButtonSegment(
                    value: true,
                    icon: Icon(Icons.delete_forever_outlined, size: 18),
                    label: Text('Merma'),
                  ),
                ],
                selected: {_isWaste},
                showSelectedIcon: false,
                onSelectionChanged: (v) =>
                    setState(() => _isWasteOverride = v.first),
              ),
              const SizedBox(height: 6),
              Text(
                _isWaste
                    ? 'Se descuenta del inventario: el producto salió y no vuelve.'
                    : 'Vuelve al inventario: no llegó a prepararse.',
                style: const TextStyle(fontSize: 12, color: _kMuted),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _note,
                maxLines: 2,
                decoration: InputDecoration(
                  filled: true,
                  fillColor: const Color(0xFFF8FAFC),
                  labelText: 'Nota (opcional)',
                  hintText: 'Algo que haga falta explicar',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                'Se imprime un comprobante con el motivo y la firma.',
                style: TextStyle(fontSize: 12, color: _kMuted),
              ),
            ],
          ),
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text(
            'CANCELAR',
            style: TextStyle(color: _kMuted, fontWeight: FontWeight.bold),
          ),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: _kDanger,
            foregroundColor: Colors.white,
            elevation: 0,
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          // Sin motivo no se borra: es la pieza que faltaba y por la que
          // hubo que reconstruir una noche entera a mano.
          onPressed: selected == null
              ? null
              : () => Navigator.of(context).pop(
                  OrderItemRemovalDecision(
                    reason: selected,
                    isWaste: _isWaste,
                    note: _note.text.trim().isEmpty ? null : _note.text.trim(),
                    quantity: _qty,
                  ),
                ),
          child: Text(
            _canChoose ? 'QUITAR ${_qtyLabel(_qty)}' : 'QUITAR PRODUCTO',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
      ],
    );
  }

  /// «¿Cuántas?» con − / + y el atajo «Todas (N)».
  Widget _quantityPicker() {
    final all = widget.quantity;
    final isAll = (_qty - all).abs() < 0.0001;
    return Row(
      children: [
        const Text(
          '¿Cuántas?',
          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5),
        ),
        const SizedBox(width: 10),
        Container(
          decoration: BoxDecoration(
            color: const Color(0xFFF3F4F6),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                key: const ValueKey('removal-qty-minus'),
                onPressed: _qty > 1 ? () => setState(() => _qty -= 1) : null,
                icon: const Icon(Icons.remove, size: 18),
              ),
              SizedBox(
                width: 36,
                child: Text(
                  _qtyLabel(_qty),
                  key: const ValueKey('removal-qty-value'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                  ),
                ),
              ),
              IconButton(
                key: const ValueKey('removal-qty-plus'),
                onPressed: _qty < all ? () => setState(() => _qty += 1) : null,
                icon: const Icon(Icons.add, size: 18),
              ),
            ],
          ),
        ),
        const SizedBox(width: 6),
        Text('de ${_qtyLabel(all)}', style: const TextStyle(color: _kMuted)),
        const Spacer(),
        TextButton(
          onPressed: isAll ? null : () => setState(() => _qty = all),
          child: Text('Todas (${_qtyLabel(all)})'),
        ),
      ],
    );
  }

  static String _qtyLabel(double v) => v == v.roundToDouble()
      ? v.toInt().toString()
      : v.toStringAsFixed(2).replaceFirst(RegExp(r'0+$'), '');
}
