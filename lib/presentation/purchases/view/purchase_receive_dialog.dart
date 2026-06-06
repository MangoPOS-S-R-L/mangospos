// Sprint 3 Inventario — Diálogo de recepción parcial de Órdenes de Compra.
//
// Reemplaza el viejo confirm dialog ("¿recibir orden?"). Permite recibir
// cantidades parciales por línea, con shortcuts para "todo lo pendiente"
// y validación de que la cantidad no exceda el saldo pendiente.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:mangopos/core/utils/app_toast.dart';

import '../state/purchases_state.dart';
import '../viewmodel/purchases_viewmodel.dart';

class PurchaseReceiveDialog extends ConsumerStatefulWidget {
  final PurchaseOrderSummary order;
  const PurchaseReceiveDialog({super.key, required this.order});

  @override
  ConsumerState<PurchaseReceiveDialog> createState() =>
      _PurchaseReceiveDialogState();
}

class _PurchaseReceiveDialogState extends ConsumerState<PurchaseReceiveDialog> {
  bool _loading = true;
  String? _loadError;
  List<PurchaseOrderLine> _lines = const [];
  // poi_id → draft (cantidad + lote opcional + vencimiento opcional).
  final Map<String, _PartialDraft> _drafts = {};
  final TextEditingController _notesController = TextEditingController();
  bool _submitting = false;
  String? _submitError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final lines = await ref
          .read(purchasesViewModelProvider)
          .loadOrderLines(widget.order.id);
      if (!mounted) return;
      setState(() {
        _lines = lines;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = 'No se pudieron cargar las líneas: $e';
        _loading = false;
      });
    }
  }

  void _fillAllPending() {
    setState(() {
      for (final line in _lines) {
        if (line.pending > 0) {
          _drafts[line.id] = _PartialDraft(quantity: line.pending);
        }
      }
    });
  }

  void _clearAll() {
    setState(() => _drafts.clear());
  }

  bool get _hasAnyQuantity => _drafts.values.any((d) => d.quantity > 0);

  Future<void> _submit() async {
    final lineItems = <Map<String, dynamic>>[];
    for (final line in _lines) {
      final draft = _drafts[line.id];
      final qty = draft?.quantity ?? 0;
      if (qty <= 0) continue;
      if (qty > line.pending) {
        setState(
          () => _submitError =
              '${line.itemName}: cantidad ${qty.toStringAsFixed(2)} excede el pendiente ${line.pending.toStringAsFixed(2)}',
        );
        return;
      }
      lineItems.add({
        'poi_id': line.id,
        'quantity': qty,
        if (line.tracksLots &&
            draft?.lotNumber != null &&
            draft!.lotNumber!.isNotEmpty)
          'lot_number': draft.lotNumber,
        if (line.tracksLots && draft?.expiryDate != null)
          'expiry_date': draft!.expiryDate!
              .toIso8601String()
              .split('T')
              .first,
      });
    }
    if (lineItems.isEmpty) {
      setState(() => _submitError = 'Indica al menos una línea con cantidad > 0');
      return;
    }

    setState(() {
      _submitting = true;
      _submitError = null;
    });
    final navigator = Navigator.of(context);
    try {
      final result = await ref
          .read(purchasesViewModelProvider)
          .receiveOrderPartial(
            orderId: widget.order.id,
            lineItems: lineItems,
            notes: _notesController.text.trim().isEmpty
                ? null
                : _notesController.text.trim(),
          );
      if (!mounted) return;
      final status = result['status']?.toString() ?? 'partial';
      AppToast.info(
        context,
        status == 'received'
            ? 'Orden recibida completamente. Inventario actualizado.'
            : 'Recepción parcial registrada. La orden queda en estado "parcial".',
      );
      navigator.pop();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _submitError = _humanize(e.toString());
      });
    }
  }

  String _humanize(String raw) {
    if (raw.contains('QUANTITY_EXCEEDS_PENDING')) {
      return 'Una de las cantidades supera el saldo pendiente.';
    }
    if (raw.contains('PURCHASE_RECEIVE_ACCESS_DENIED')) {
      return 'No tienes permisos para recibir órdenes de compra.';
    }
    if (raw.contains('PURCHASE_ORDER_ALREADY_RECEIVED')) {
      return 'La orden ya está totalmente recibida.';
    }
    if (raw.contains('PURCHASE_ORDER_CANCELLED')) {
      return 'La orden está cancelada.';
    }
    if (raw.contains('PURCHASE_ORDER_WAREHOUSE_REQUIRED')) {
      return 'La orden no tiene bodega asignada. Edita la orden antes de recibir.';
    }
    return 'Error: $raw';
  }

  @override
  Widget build(BuildContext context) {
    final currency = NumberFormat.currency(
      locale: 'en_US',
      symbol: 'RD\$',
      decimalDigits: 2,
    );
    final selectedCount = _drafts.values.where((d) => d.quantity > 0).length;

    return AlertDialog(
      title: Text(
        'Recibir ${widget.order.orderNumber}',
        style: const TextStyle(fontWeight: FontWeight.w800),
      ),
      content: SizedBox(
        width: 640,
        height: 520,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _loadError != null
            ? Center(
                child: Text(
                  _loadError!,
                  style: const TextStyle(color: Color(0xFFB91C1C)),
                ),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${widget.order.supplierName} · ${widget.order.warehouseName}',
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF334155),
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Total OC ${currency.format(widget.order.total)}',
                              style: const TextStyle(
                                fontSize: 12,
                                color: Color(0xFF64748B),
                              ),
                            ),
                          ],
                        ),
                      ),
                      TextButton.icon(
                        onPressed: _fillAllPending,
                        icon: const Icon(Icons.done_all_rounded, size: 18),
                        label: const Text('Recibir todo lo pendiente'),
                      ),
                      const SizedBox(width: 4),
                      TextButton(
                        onPressed: _hasAnyQuantity ? _clearAll : null,
                        child: const Text('Limpiar'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Divider(height: 1),
                  Expanded(
                    child: ListView.separated(
                      itemCount: _lines.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final line = _lines[index];
                        return _LineRow(
                          line: line,
                          draft: _drafts[line.id],
                          onChange: (d) {
                            setState(() {
                              if (d == null || d.quantity <= 0) {
                                _drafts.remove(line.id);
                              } else {
                                _drafts[line.id] = d;
                              }
                            });
                          },
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _notesController,
                    maxLines: 2,
                    decoration: const InputDecoration(
                      labelText: 'Notas (opcional)',
                      hintText: 'Ej: parcial 1/2 — falta entrega del lunes',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  if (_submitError != null) ...[
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFEF2F2),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFFFECACA)),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.error_outline,
                            color: Color(0xFFB91C1C),
                            size: 18,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _submitError!,
                              style: const TextStyle(color: Color(0xFFB91C1C)),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _submitting || _hasAnyQuantity == false ? null : _submit,
          child: _submitting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text('Confirmar ($selectedCount)'),
        ),
      ],
    );
  }
}

class _PartialDraft {
  final double quantity;
  final String? lotNumber;
  final DateTime? expiryDate;
  const _PartialDraft({
    required this.quantity,
    this.lotNumber,
    this.expiryDate,
  });

  _PartialDraft copyWith({
    double? quantity,
    String? lotNumber,
    DateTime? expiryDate,
    bool clearLotNumber = false,
    bool clearExpiryDate = false,
  }) {
    return _PartialDraft(
      quantity: quantity ?? this.quantity,
      lotNumber: clearLotNumber ? null : (lotNumber ?? this.lotNumber),
      expiryDate: clearExpiryDate ? null : (expiryDate ?? this.expiryDate),
    );
  }
}

class _LineRow extends StatefulWidget {
  final PurchaseOrderLine line;
  final _PartialDraft? draft;
  final ValueChanged<_PartialDraft?> onChange;

  const _LineRow({
    required this.line,
    required this.draft,
    required this.onChange,
  });

  @override
  State<_LineRow> createState() => _LineRowState();
}

class _LineRowState extends State<_LineRow> {
  late final TextEditingController _controller;
  late final TextEditingController _lotController;
  DateTime? _expiryDate;

  double get _qty => widget.draft?.quantity ?? 0;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: _qty > 0 ? _formatQty(_qty) : '',
    );
    _lotController = TextEditingController(text: widget.draft?.lotNumber ?? '');
    _expiryDate = widget.draft?.expiryDate;
  }

  @override
  void didUpdateWidget(_LineRow old) {
    super.didUpdateWidget(old);
    final expected = _qty > 0 ? _formatQty(_qty) : '';
    if (_controller.text != expected) {
      _controller.text = expected;
      _controller.selection = TextSelection.collapsed(offset: expected.length);
    }
  }

  String _formatQty(double v) {
    if (v == v.roundToDouble()) return v.toStringAsFixed(0);
    return v.toString();
  }

  @override
  void dispose() {
    _controller.dispose();
    _lotController.dispose();
    super.dispose();
  }

  void _emit(double qty) {
    if (qty <= 0) {
      widget.onChange(null);
      return;
    }
    final lot = _lotController.text.trim().isEmpty
        ? null
        : _lotController.text.trim();
    widget.onChange(
      _PartialDraft(quantity: qty, lotNumber: lot, expiryDate: _expiryDate),
    );
  }

  Future<void> _pickExpiry() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 10),
      initialDate: _expiryDate ?? now.add(const Duration(days: 30)),
      helpText: 'Fecha de vencimiento del lote',
    );
    if (picked != null) {
      setState(() => _expiryDate = picked);
      _emit(_qty);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = widget.line;
    final qty = _qty;
    final exceeds = qty > l.pending;
    final fulfilled = l.isFulfilled;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            l.itemName,
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: fulfilled
                                  ? const Color(0xFF94A3B8)
                                  : const Color(0xFF0F172A),
                              decoration: fulfilled
                                  ? TextDecoration.lineThrough
                                  : null,
                            ),
                          ),
                        ),
                        if (l.tracksLots)
                          Container(
                            margin: const EdgeInsets.only(left: 6),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFFEDD5),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Text(
                              'LOTE',
                              style: TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.w800,
                                color: Color(0xFFC2410C),
                                letterSpacing: 0.5,
                              ),
                            ),
                          ),
                        if (!l.tracksInventory)
                          Container(
                            margin: const EdgeInsets.only(left: 6),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFEF3C7),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Text(
                              'sin stock',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF92400E),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Pedido: ${l.quantityOrdered.toStringAsFixed(2)} ${l.unit}   ·   '
                      'Recibido: ${l.quantityReceived.toStringAsFixed(2)}   ·   '
                      'Pendiente: ${l.pending.toStringAsFixed(2)}',
                      style: TextStyle(
                        fontSize: 12,
                        color: fulfilled
                            ? const Color(0xFF059669)
                            : const Color(0xFF64748B),
                        fontWeight: fulfilled
                            ? FontWeight.w600
                            : FontWeight.normal,
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: 130,
                child: TextField(
                  controller: _controller,
                  enabled: !fulfilled,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  textAlign: TextAlign.right,
                  decoration: InputDecoration(
                    hintText: fulfilled ? '—' : '0',
                    suffixText: l.unit,
                    border: OutlineInputBorder(
                      borderSide: BorderSide(
                        color: exceeds
                            ? const Color(0xFFDC2626)
                            : const Color(0xFFCBD5E1),
                      ),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderSide: BorderSide(
                        color: exceeds
                            ? const Color(0xFFDC2626)
                            : const Color(0xFFCBD5E1),
                      ),
                    ),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 10,
                    ),
                  ),
                  onChanged: (text) {
                    final v =
                        double.tryParse(text.replaceAll(',', '.')) ?? 0;
                    _emit(v);
                  },
                ),
              ),
            ],
          ),
          if (l.tracksLots && qty > 0 && !fulfilled) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _lotController,
                    decoration: const InputDecoration(
                      labelText: 'Nº lote (auto si vacío)',
                      border: OutlineInputBorder(),
                      isDense: true,
                      prefixIcon: Icon(Icons.qr_code_2_rounded, size: 18),
                    ),
                    onChanged: (_) => _emit(qty),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _pickExpiry,
                    icon: const Icon(Icons.calendar_today_outlined, size: 16),
                    label: Text(
                      _expiryDate != null
                          ? 'Vence ${_expiryDate!.day.toString().padLeft(2, '0')}/${_expiryDate!.month.toString().padLeft(2, '0')}/${_expiryDate!.year}'
                          : 'Fecha de vencimiento',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 12,
                      ),
                      alignment: Alignment.centerLeft,
                    ),
                  ),
                ),
                if (_expiryDate != null)
                  IconButton(
                    onPressed: () {
                      setState(() => _expiryDate = null);
                      _emit(qty);
                    },
                    icon: const Icon(Icons.close_rounded, size: 18),
                    tooltip: 'Quitar fecha',
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
