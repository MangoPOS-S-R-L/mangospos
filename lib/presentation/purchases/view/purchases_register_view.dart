import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show Supabase;

import '../../../app/router/routes.dart';
import '../../../app/theme/mango_styles.dart';
import '../../../core/inventory/pack_conversion.dart';
import '../../../data/repositories/credits_repository.dart';
import '../state/purchases_state.dart';
import '../utils/discount_input.dart';
import '../viewmodel/purchases_viewmodel.dart';
import '../widgets/create_supplier_dialog.dart';
import '../../../core/theme/app_colors.dart';

/// Cómo trae el ITBIS cada línea de la factura del proveedor.
/// - [included]: el costo digitado YA trae el ITBIS → se desglosa con el %
///   digitado (neto = costo / (1 + %/100), default 18).
/// - [separate]: el costo es neto; ITBIS = % digitado (default 18) o, si se
///   escribe el pagado POR UNIDAD con ITBIS, pagado − costo (escala con la
///   cantidad).
/// - [exempt]: la línea no lleva ITBIS.
enum _TaxMode { included, separate, exempt }

extension _TaxModeLabel on _TaxMode {
  String get short {
    switch (this) {
      case _TaxMode.included:
        return 'Incluido';
      case _TaxMode.separate:
        return 'Aparte';
      case _TaxMode.exempt:
        return 'Exento';
    }
  }
}

class PurchasesRegisterView extends ConsumerStatefulWidget {
  const PurchasesRegisterView({super.key});

  @override
  ConsumerState<PurchasesRegisterView> createState() =>
      _PurchasesRegisterViewState();
}

class _PurchasesRegisterViewState extends ConsumerState<PurchasesRegisterView> {
  final _notesCtrl = TextEditingController();
  final _orderNumberCtrl = TextEditingController();
  final _invoiceNumberCtrl = TextEditingController();
  String? _supplierId;
  String? _warehouseId;
  // Por defecto la compra se registra ya "Recibida": el caso común es que la
  // mercancía ya llegó, así que el registro debe sumar el stock de una vez.
  // El usuario puede bajarlo a Borrador/Enviada para órdenes que aún no llegan.
  String _status = 'received';
  DateTime _expectedDate = DateTime.now().add(const Duration(days: 3));

  // Condición de pago: al contado (default) o a crédito. A crédito se crea
  // una cuenta por pagar (supplier_credits) vinculada a la orden, visible
  // en Créditos → Cuentas por Pagar. La UI para elegir crédito está APAGADA
  // por ahora (decisión 2026-07-14); el flujo en _submit queda listo para
  // cuando se reactive.
  final bool _isCredit = false;
  final DateTime _creditDueDate = DateTime.now().add(const Duration(days: 30));

  /// Productos ya agregados a la factura (la lista de abajo). Empieza vacía;
  /// se llena con el flujo rápido de teclado o con el buscador multi-selección.
  final List<_DraftItemControllers> _lines = [];

  // Descuento GLOBAL de la orden (Resumen): monto RD$ o "%" (ej. "500" ó
  // "5%"). Es financiero: rebaja el total pero no toca costos ni kardex.
  final _orderDiscountCtrl = TextEditingController();

  // ── Estado del renglón de captura rápida (producto → cant → costo → Enter).
  final _entryQtyCtrl = TextEditingController(text: '1');
  final _entryCostCtrl = TextEditingController(text: '0');
  final _entryPaidCtrl = TextEditingController();
  // Descuento de la LÍNEA en captura: monto RD$ por línea o "%" del valor.
  final _entryDiscountCtrl = TextEditingController();
  // % de ITBIS para el modo "Aparte". Se conserva entre líneas porque una
  // misma factura suele traer la misma tasa en todos sus renglones.
  final _entryTaxPctCtrl = TextEditingController(text: '18');
  final _qtyFocus = FocusNode();
  final _costFocus = FocusNode();
  final _paidFocus = FocusNode();
  PurchaseInventoryItem? _entrySelected;
  _TaxMode _entryTaxMode = _TaxMode.included;
  // Snapshot de empaque del insumo seleccionado en el renglón de captura.
  String _entryPurchaseUnit = '';
  double _entryPackSize = 1;
  String _entryBaseUnit = '';

  // Controlador/foco del campo de búsqueda del Autocomplete (capturados en
  // fieldViewBuilder para poder limpiar y devolver el foco tras cada alta).
  TextEditingController? _productFieldCtrl;
  FocusNode? _productFocus;

  bool get _entryHasPack =>
      _entryPackSize > 1 && _entryPurchaseUnit.trim().isNotEmpty;

  /// % de ITBIS vigente en el renglón de captura; vacío/ilegible cae al 18%.
  double get _entryTaxPct =>
      double.tryParse(_entryTaxPctCtrl.text.trim()) ?? 18;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final vm = ref.read(purchasesViewModelProvider);
      await vm.init();
      if (!mounted) return;
      final state = vm.state;
      if (_supplierId == null && state.suppliers.isNotEmpty) {
        _supplierId = state.suppliers.first.id;
      }
      if (_warehouseId == null && state.warehouses.isNotEmpty) {
        _warehouseId = state.warehouses.first.id;
      }
      final nextNumber = await vm.generateNextOrderNumber();
      if (!mounted) return;
      setState(() {
        _orderNumberCtrl.text = nextNumber;
      });
    });
  }

  @override
  void dispose() {
    _notesCtrl.dispose();
    _orderNumberCtrl.dispose();
    _invoiceNumberCtrl.dispose();
    _orderDiscountCtrl.dispose();
    _entryQtyCtrl.dispose();
    _entryCostCtrl.dispose();
    _entryPaidCtrl.dispose();
    _entryDiscountCtrl.dispose();
    _entryTaxPctCtrl.dispose();
    _qtyFocus.dispose();
    _costFocus.dispose();
    _paidFocus.dispose();
    for (final line in _lines) {
      line.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vm = ref.watch(purchasesViewModelProvider);
    final state = vm.state;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: state.loading && state.suppliers.isEmpty && state.warehouses.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      IconButton(
                        onPressed: () => context.go(AppRoutes.purchasesList),
                        icon: const Icon(Icons.arrow_back),
                      ),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Registro de compra',
                              style: TextStyle(
                                fontSize: 28,
                                fontWeight: FontWeight.w800,
                                color: Color(0xFF0F172A),
                              ),
                            ),
                            SizedBox(height: 6),
                            Text(
                              'Registra la factura del proveedor y agrega sus productos',
                              style: TextStyle(
                                fontSize: 14,
                                color: Color(0xFF64748B),
                              ),
                            ),
                          ],
                        ),
                      ),
                      FilledButton.icon(
                        onPressed: state.saving ? null : _submit,
                        icon: const Icon(Icons.save_outlined),
                        label: const Text('Guardar orden'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  if (state.error != null) ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFEF2F2),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFFFECACA)),
                      ),
                      child: Text(
                        state.error!,
                        style: const TextStyle(color: Color(0xFF991B1B)),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  _card(child: _buildHeaderCard(state)),
                  const SizedBox(height: 20),
                  _card(child: _buildProductsCard(state)),
                ],
              ),
            ),
    );
  }

  Widget _card({required Widget child}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: child,
    );
  }

  // ─────────────────────────────────────────── Datos generales / factura ──
  Widget _buildHeaderCard(PurchasesState state) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Datos generales',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _orderNumberCtrl,
                decoration: const InputDecoration(labelText: 'Número de orden'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _invoiceNumberCtrl,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(
                  labelText: 'Número de factura',
                  hintText: 'Ej. B0100000284',
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: DropdownButtonFormField<String>(
                initialValue: _status,
                decoration: const InputDecoration(labelText: 'Estado'),
                items: const [
                  DropdownMenuItem(value: 'draft', child: Text('Borrador')),
                  DropdownMenuItem(value: 'sent', child: Text('Enviada')),
                  DropdownMenuItem(value: 'received', child: Text('Recibida')),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  setState(() => _status = value);
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                initialValue: _supplierId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Proveedor'),
                items: state.suppliers
                    .map(
                      (supplier) => DropdownMenuItem(
                        value: supplier.id,
                        child: Text(
                          supplier.name,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
                    .toList(growable: false),
                onChanged: (value) => setState(() => _supplierId = value),
              ),
            ),
            const SizedBox(width: 6),
            _AddIconButton(
              tooltip: 'Nuevo proveedor',
              onPressed: state.saving ? null : _showCreateSupplierDialog,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: DropdownButtonFormField<String>(
                initialValue: _warehouseId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Almacén'),
                items: state.warehouses
                    .map(
                      (warehouse) => DropdownMenuItem(
                        value: warehouse.id,
                        child: Text(
                          warehouse.isMain
                              ? '${warehouse.name} · Principal'
                              : warehouse.name,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
                    .toList(growable: false),
                onChanged: (value) => setState(() => _warehouseId = value),
              ),
            ),
            const SizedBox(width: 6),
            _AddIconButton(
              tooltip: 'Nuevo almacén',
              onPressed: state.saving ? null : _showCreateWarehouseDialog,
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: InputDecorator(
                decoration: const InputDecoration(labelText: 'Fecha de entrega'),
                child: InkWell(
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: _expectedDate,
                      firstDate: DateTime.now().subtract(const Duration(days: 90)),
                      lastDate: DateTime.now().add(const Duration(days: 365)),
                    );
                    if (picked == null) return;
                    setState(() => _expectedDate = picked);
                  },
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        DateFormat('dd/MM/yyyy').format(_expectedDate),
                        style: const TextStyle(fontSize: 14),
                      ),
                      const Icon(Icons.event_outlined, size: 18, color: Color(0xFF64748B)),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            const Expanded(child: SizedBox()),
            const SizedBox(width: 12),
            const Expanded(child: SizedBox()),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _notesCtrl,
          maxLines: 2,
          decoration: const InputDecoration(
            labelText: 'Notas',
            alignLabelWithHint: true,
          ),
        ),
      ],
    );
  }

  // ─────────────────────────────────────────────── Productos / captura ──
  Widget _buildProductsCard(PurchasesState state) {
    final currency = NumberFormat.currency(
      locale: 'en_US',
      symbol: 'RD\$',
      decimalDigits: 2,
    );
    final subtotal = _lines.fold<double>(0, (sum, l) => sum + l.baseSubtotal);
    final estimatedTax = _lines.fold<double>(0, (sum, l) => sum + l.taxAmount);
    // Descuentos por línea ya aplicados (informativo: el subtotal ya los trae
    // rebajados) y descuento global de la orden sobre subtotal + ITBIS.
    final lineDiscounts =
        _lines.fold<double>(0, (sum, l) => sum + l.lineDiscountNet);
    final orderDiscount = DiscountInput.parse(_orderDiscountCtrl.text)
        .amountOn(subtotal + estimatedTax);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                'Productos de la factura',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
            ),
            OutlinedButton.icon(
              onPressed: () => _openMultiSearchDialog(state),
              icon: const Icon(Icons.playlist_add_check, size: 18),
              label: const Text('Buscar y seleccionar varios'),
            ),
          ],
        ),
        const SizedBox(height: 6),
        const Text(
          'Escribe el producto y presiona Enter, luego cantidad · Enter, luego costo · Enter.',
          style: TextStyle(fontSize: 12, color: Color(0xFF64748B)),
        ),
        const SizedBox(height: 14),
        _buildEntryRow(state),
        const SizedBox(height: 18),
        if (_lines.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 28),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFE2E8F0)),
            ),
            child: const Text(
              'Aún no has agregado productos a esta factura.',
              style: TextStyle(color: Color(0xFF64748B)),
            ),
          )
        else ...[
          _buildLinesTable(),
          const SizedBox(height: 20),
          Align(
            alignment: Alignment.centerRight,
            child: Container(
              width: 320,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFE2E8F0)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Resumen',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF0F172A),
                    ),
                  ),
                  const SizedBox(height: 12),
                  _SummaryRow(
                    label: 'Líneas',
                    value: '${_lines.length}',
                  ),
                  const SizedBox(height: 8),
                  _SummaryRow(
                    label: 'Subtotal (neto)',
                    value: currency.format(subtotal),
                  ),
                  if (lineDiscounts > 0) ...[
                    const SizedBox(height: 8),
                    _SummaryRow(
                      label: 'Desc. en líneas (aplicado)',
                      value: '−${currency.format(lineDiscounts)}',
                    ),
                  ],
                  const SizedBox(height: 8),
                  _SummaryRow(
                    label: 'ITBIS',
                    value: currency.format(estimatedTax),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Desc. a la orden',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF64748B),
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 110,
                        child: _MiniField(
                          controller: _orderDiscountCtrl,
                          hint: '0 ó 5%',
                          allowPercent: true,
                          onChanged: () => setState(() {}),
                        ),
                      ),
                    ],
                  ),
                  const Divider(height: 20),
                  _SummaryRow(
                    label: 'Total',
                    value: currency.format(
                      subtotal + estimatedTax - orderDiscount,
                    ),
                    bold: true,
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildEntryRow(PurchasesState state) {
    final selected = _entrySelected;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFCBD5E1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 4, child: _buildProductAutocomplete(state)),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: TextField(
                  controller: _entryQtyCtrl,
                  focusNode: _qtyFocus,
                  enabled: selected != null,
                  textInputAction: TextInputAction.next,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                  ],
                  decoration: InputDecoration(
                    labelText: _entryHasPack
                        ? 'Cant. ($_entryPurchaseUnit)'
                        : 'Cantidad',
                    filled: true,
                    fillColor: Colors.white,
                  ),
                  onSubmitted: (_) => _costFocus.requestFocus(),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: TextField(
                  controller: _entryCostCtrl,
                  focusNode: _costFocus,
                  enabled: selected != null,
                  textInputAction: _entryTaxMode == _TaxMode.separate
                      ? TextInputAction.next
                      : TextInputAction.done,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                  ],
                  decoration: InputDecoration(
                    labelText: _entryHasPack
                        ? 'Costo x $_entryPurchaseUnit'
                        : 'Costo unitario',
                    suffixText: _entryTaxMode == _TaxMode.included
                        ? 'c/ITBIS'
                        : null,
                    filled: true,
                    fillColor: Colors.white,
                  ),
                  onSubmitted: (_) {
                    if (_entryTaxMode == _TaxMode.separate) {
                      _paidFocus.requestFocus();
                    } else {
                      _commitEntry();
                    }
                  },
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                height: 48,
                child: FilledButton(
                  onPressed: selected == null ? null : _commitEntry,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                    ),
                  ),
                  child: const Text('Agregar'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const Text(
                'ITBIS:',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF475569),
                ),
              ),
              const SizedBox(width: 8),
              _TaxModeDropdown(
                value: _entryTaxMode,
                onChanged: (m) => setState(() {
                  _entryTaxMode = m;
                  if (m != _TaxMode.separate) _entryPaidCtrl.clear();
                }),
              ),
              if (_entryTaxMode != _TaxMode.exempt) ...[
                const SizedBox(width: 12),
                SizedBox(
                  width: 90,
                  child: TextField(
                    controller: _entryTaxPctCtrl,
                    enabled: selected != null,
                    textInputAction: TextInputAction.done,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                    ],
                    decoration: const InputDecoration(
                      labelText: '% ITBIS',
                      isDense: true,
                      filled: true,
                      fillColor: Colors.white,
                    ),
                    // % y pagado son alternativas: digitar el % descarta el
                    // pagado (que tiene prioridad cuando existe).
                    onChanged: (_) => setState(() => _entryPaidCtrl.clear()),
                    onSubmitted: (_) => _commitEntry(),
                  ),
                ),
              ],
              if (_entryTaxMode == _TaxMode.separate) ...[
                const SizedBox(width: 8),
                SizedBox(
                  width: 200,
                  child: TextField(
                    controller: _entryPaidCtrl,
                    focusNode: _paidFocus,
                    enabled: selected != null,
                    textInputAction: TextInputAction.done,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                    ],
                    decoration: const InputDecoration(
                      labelText: 'Pagado por unidad (c/ITBIS)',
                      helperText: 'opcional · manda sobre el %',
                      isDense: true,
                      filled: true,
                      fillColor: Colors.white,
                    ),
                    // Pagado y descuento son alternativas (el pagado ya
                    // debería venir con el descuento aplicado).
                    onChanged: (_) => setState(() => _entryDiscountCtrl.clear()),
                    onSubmitted: (_) => _commitEntry(),
                  ),
                ),
              ],
              const SizedBox(width: 12),
              SizedBox(
                width: 120,
                child: TextField(
                  controller: _entryDiscountCtrl,
                  enabled: selected != null,
                  textInputAction: TextInputAction.done,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.%]')),
                  ],
                  decoration: const InputDecoration(
                    labelText: 'Descuento',
                    hintText: '150 ó 10%',
                    helperText: 'RD\$ por línea o %',
                    isDense: true,
                    filled: true,
                    fillColor: Colors.white,
                  ),
                  // Descuento y pagado son alternativas: digitar el descuento
                  // descarta el pagado (evita que el ITBIS se infle al bajar
                  // el neto con un pagado viejo).
                  onChanged: (_) => setState(() => _entryPaidCtrl.clear()),
                  onSubmitted: (_) => _commitEntry(),
                ),
              ),
              const Spacer(),
              if (_entryHasPack && selected != null)
                Builder(
                  builder: (_) {
                    final qty = double.tryParse(_entryQtyCtrl.text.trim()) ?? 0;
                    final base = packToBase(qty, _entryPackSize);
                    return Text(
                      '= ${_trimNum(base)} $_entryBaseUnit '
                      '(1 $_entryPurchaseUnit = '
                      '${_trimNum(_entryPackSize)} $_entryBaseUnit)',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF64748B),
                      ),
                    );
                  },
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildProductAutocomplete(PurchasesState state) {
    return Autocomplete<_ProductOption>(
      displayStringForOption: (opt) => opt.label,
      optionsBuilder: (TextEditingValue value) {
        final raw = value.text.trim();
        if (raw.isEmpty) return const Iterable<_ProductOption>.empty();
        final q = raw.toLowerCase();
        final matches = state.inventoryItems
            .where(
              (it) =>
                  it.name.toLowerCase().contains(q) ||
                  it.sku.toLowerCase().contains(q),
            )
            .take(20)
            .map(_ProductOption.item)
            .toList();
        matches.add(_ProductOption.create(raw));
        return matches;
      },
      onSelected: (opt) => _onProductOptionSelected(opt),
      fieldViewBuilder: (context, textController, focusNode, onFieldSubmitted) {
        _productFieldCtrl = textController;
        _productFocus = focusNode;
        return TextField(
          controller: textController,
          focusNode: focusNode,
          decoration: const InputDecoration(
            labelText: 'Producto',
            hintText: 'Busca por nombre o SKU…',
            prefixIcon: Icon(Icons.search),
            filled: true,
            fillColor: Colors.white,
          ),
          onSubmitted: (value) {
            final query = value.trim().toLowerCase();
            if (query.isNotEmpty) {
              PurchaseInventoryItem? match;
              for (final it in state.inventoryItems) {
                if (it.sku.trim().toLowerCase() == query) {
                  match = it;
                  break;
                }
              }
              if (match != null) {
                _addSkuProductDirectly(match);
                return;
              }
            }
            onFieldSubmitted();
          },
        );
      },
      optionsViewBuilder: (context, onSelected, options) {
        final currency = NumberFormat.currency(
          locale: 'en_US',
          symbol: 'RD\$',
          decimalDigits: 2,
        );
        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 4,
            borderRadius: BorderRadius.circular(12),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320, maxWidth: 520),
              child: ListView.builder(
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                itemCount: options.length,
                itemBuilder: (context, index) {
                  final opt = options.elementAt(index);
                  if (opt.isCreate) {
                    return ListTile(
                      leading: const Icon(
                        Icons.add_circle_outline,
                        color: Color(0xFF2563EB),
                      ),
                      title: Text('Crear "${opt.rawText}"'),
                      subtitle: const Text('Nuevo insumo en inventario'),
                      onTap: () => onSelected(opt),
                    );
                  }
                  final item = opt.item!;
                  return ListTile(
                    title: Text(item.name),
                    subtitle: Text(
                      [
                        if (item.sku.trim().isNotEmpty) item.sku,
                        if (item.cost > 0)
                          'Costo actual ${currency.format(item.cost)}',
                      ].join(' · '),
                    ),
                    onTap: () => onSelected(opt),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _onProductOptionSelected(_ProductOption opt) async {
    PurchaseInventoryItem? item = opt.item;
    if (opt.isCreate) {
      try {
        item = await ref
            .read(purchasesViewModelProvider)
            .createInventoryItem(name: opt.rawText);
      } catch (_) {
        return; // el error ya quedó en el state.error de la vista
      }
      if (!mounted) return;
    }
    if (item == null) return;
    final hasPack = item.packSize > 1 && item.purchaseUnit.trim().isNotEmpty;
    // Costo NETO por unidad de compra (el costo maestro se guarda sin ITBIS).
    final netPurchaseUnit = hasPack ? item.cost * item.packSize : item.cost;
    setState(() {
      _entrySelected = item;
      _entryPurchaseUnit = hasPack ? item!.purchaseUnit : '';
      _entryPackSize = hasPack ? item!.packSize : 1;
      _entryBaseUnit = item!.unit;
      _entryQtyCtrl.text = '1';
      _entryPaidCtrl.clear();
      // Si el modo es "incluido", el campo costo espera el precio CON ITBIS
      // (al % vigente del renglón de captura).
      final prefill = netPurchaseUnit <= 0
          ? ''
          : (_entryTaxMode == _TaxMode.included
                    ? netPurchaseUnit * (1 + _entryTaxPct / 100)
                    : netPurchaseUnit)
                .toStringAsFixed(2);
      _entryCostCtrl.text = prefill;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _qtyFocus.requestFocus();
    });
  }

  void _commitEntry() {
    final item = _entrySelected;
    if (item == null) return;
    final qty = double.tryParse(_entryQtyCtrl.text.trim()) ?? 0;
    if (qty <= 0) {
      _qtyFocus.requestFocus();
      return;
    }
    final cost = double.tryParse(_entryCostCtrl.text.trim()) ?? 0;
    final paid = double.tryParse(_entryPaidCtrl.text.trim()) ?? 0;
    final taxPct = double.tryParse(_entryTaxPctCtrl.text.trim()) ?? 18;
    setState(() {
      _lines.add(
        _DraftItemControllers.fromItem(
          item,
          qty: qty,
          cost: cost,
          taxMode: _entryTaxMode,
          paid: paid,
          taxPct: taxPct,
          discountText: _entryDiscountCtrl.text.trim(),
        ),
      );
    });
    _resetEntry();
  }

  void _resetEntry() {
    setState(() {
      _entrySelected = null;
      _entryPurchaseUnit = '';
      _entryPackSize = 1;
      _entryBaseUnit = '';
      _entryQtyCtrl.text = '1';
      _entryCostCtrl.text = '0';
      _entryPaidCtrl.clear();
      // El descuento no persiste entre líneas: suele ser puntual por renglón.
      _entryDiscountCtrl.clear();
    });
    _productFieldCtrl?.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _productFocus?.requestFocus();
    });
  }

  void _addSkuProductDirectly(PurchaseInventoryItem item) {
    final hasPack = item.packSize > 1 && item.purchaseUnit.trim().isNotEmpty;
    final netPurchaseUnit = hasPack ? item.cost * item.packSize : item.cost;
    final cost = _entryTaxMode == _TaxMode.included
        ? netPurchaseUnit * (1 + _entryTaxPct / 100)
        : netPurchaseUnit;

    setState(() {
      final existingIndex = _lines.indexWhere((l) => l.inventoryItemId == item.id);
      if (existingIndex != -1) {
        final currentQty = double.tryParse(_lines[existingIndex].quantity.text.trim()) ?? 0;
        _lines[existingIndex].quantity.text = _trimNum(currentQty + 1);
      } else {
        _lines.add(
          _DraftItemControllers.fromItem(
            item,
            qty: 1,
            cost: cost,
            taxMode: _entryTaxMode,
            paid: 0,
            taxPct: _entryTaxPct,
          ),
        );
      }
    });

    _resetEntry();
  }

  Widget _buildLinesTable() {
    final currency = NumberFormat.currency(
      locale: 'en_US',
      symbol: 'RD\$',
      decimalDigits: 2,
    );
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: const BoxDecoration(
            color: Color(0xFFF1F5F9),
            borderRadius: BorderRadius.vertical(top: Radius.circular(10)),
          ),
          child: Row(
            children: const [
              Expanded(flex: 4, child: _HeaderCell('Descripción')),
              SizedBox(width: 8),
              Expanded(flex: 2, child: _HeaderCell('Cantidad', alignCenter: true)),
              SizedBox(width: 8),
              Expanded(flex: 2, child: _HeaderCell('Costo', alignCenter: true)),
              SizedBox(width: 8),
              Expanded(flex: 2, child: _HeaderCell('Desc.', alignCenter: true)),
              SizedBox(width: 8),
              SizedBox(width: 176, child: _HeaderCell('ITBIS', alignCenter: true)),
              SizedBox(width: 8),
              Expanded(flex: 2, child: _HeaderCell('Pagado und.', alignCenter: true)),
              SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: _HeaderCell('ITBIS \$', alignRight: true),
              ),
              SizedBox(width: 8),
              Expanded(flex: 2, child: _HeaderCell('Valor', alignRight: true)),
              SizedBox(width: 8),
              SizedBox(width: 36),
            ],
          ),
        ),
        for (var i = 0; i < _lines.length; i++)
          _LineRow(
            key: ValueKey(_lines[i].key),
            line: _lines[i],
            currency: currency,
            onChanged: () => setState(() {}),
            onRemove: () => setState(() {
              final removed = _lines.removeAt(i);
              removed.dispose();
            }),
          ),
      ],
    );
  }

  // ─────────────────────────────────────── Buscador multi-selección ──
  Future<void> _openMultiSearchDialog(PurchasesState state) async {
    final selectedIds = <String>{};
    final searchCtrl = TextEditingController();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setLocal) {
            final q = searchCtrl.text.trim().toLowerCase();
            final items = state.inventoryItems
                .where(
                  (it) =>
                      q.isEmpty ||
                      it.name.toLowerCase().contains(q) ||
                      it.sku.toLowerCase().contains(q),
                )
                .toList(growable: false);
            final currency = NumberFormat.currency(
              locale: 'en_US',
              symbol: 'RD\$',
              decimalDigits: 2,
            );
            return AlertDialog(
              title: const Text('Seleccionar productos'),
              content: SizedBox(
                width: 520,
                height: 480,
                child: Column(
                  children: [
                    TextField(
                      controller: searchCtrl,
                      autofocus: true,
                      decoration: const InputDecoration(
                        labelText: 'Buscar por nombre o SKU',
                        prefixIcon: Icon(Icons.search),
                      ),
                      onChanged: (_) => setLocal(() {}),
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: items.isEmpty
                          ? const Center(child: Text('Sin resultados'))
                          : ListView.builder(
                              itemCount: items.length,
                              itemBuilder: (context, index) {
                                final it = items[index];
                                final checked = selectedIds.contains(it.id);
                                return CheckboxListTile(
                                  value: checked,
                                  dense: true,
                                  controlAffinity:
                                      ListTileControlAffinity.leading,
                                  title: Text(it.name),
                                  subtitle: Text(
                                    [
                                      if (it.sku.trim().isNotEmpty) it.sku,
                                      if (it.cost > 0) currency.format(it.cost),
                                    ].join(' · '),
                                  ),
                                  onChanged: (v) => setLocal(() {
                                    if (v == true) {
                                      selectedIds.add(it.id);
                                    } else {
                                      selectedIds.remove(it.id);
                                    }
                                  }),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: const Text('Cancelar'),
                ),
                FilledButton(
                  onPressed: selectedIds.isEmpty
                      ? null
                      : () => Navigator.of(dialogContext).pop(true),
                  child: Text('Agregar (${selectedIds.length})'),
                ),
              ],
            );
          },
        );
      },
    );

    searchCtrl.dispose();
    if (confirmed != true || !mounted) return;

    setState(() {
      for (final it in state.inventoryItems) {
        if (!selectedIds.contains(it.id)) continue;
        // No duplicar: si el insumo ya está en la lista, se omite.
        final already = _lines.any((l) => l.inventoryItemId == it.id);
        if (already) continue;
        final hasPack = it.packSize > 1 && it.purchaseUnit.trim().isNotEmpty;
        final netPU = hasPack ? it.cost * it.packSize : it.cost;
        // Se agregan con el modo y % de ITBIS actuales del renglón de captura.
        final cost = _entryTaxMode == _TaxMode.included
            ? netPU * (1 + _entryTaxPct / 100)
            : netPU;
        _lines.add(
          _DraftItemControllers.fromItem(
            it,
            qty: 1,
            cost: cost,
            taxMode: _entryTaxMode,
            paid: 0,
            taxPct: _entryTaxPct,
          ),
        );
      }
    });
  }

  // ─────────────────────────────────────────────── Diálogos de alta ──
  Future<void> _showCreateSupplierDialog() async {
    final created = await showCreateSupplierDialog(context, ref);
    if (!mounted || created == null) return;
    setState(() => _supplierId = created.id);
  }

  Future<void> _showCreateWarehouseDialog() async {
    final nameCtrl = TextEditingController();
    var isMain = false;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setLocal) {
            return AlertDialog(
              title: const Text('Nuevo almacén'),
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: nameCtrl,
                      autofocus: true,
                      decoration: const InputDecoration(labelText: 'Nombre'),
                    ),
                    const SizedBox(height: 8),
                    CheckboxListTile(
                      value: isMain,
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: const Text('Marcar como almacén principal'),
                      onChanged: (v) => setLocal(() => isMain = v ?? false),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('Cancelar'),
                ),
                FilledButton(
                  onPressed: () async {
                    final name = nameCtrl.text.trim();
                    if (name.isEmpty) return;
                    try {
                      final created = await ref
                          .read(purchasesViewModelProvider)
                          .createWarehouse(name: name, isMain: isMain);
                      if (!mounted) return;
                      setState(() => _warehouseId = created.id);
                    } catch (_) {
                      // el error se muestra vía state.error
                    }
                    if (!dialogContext.mounted) return;
                    Navigator.of(dialogContext).pop();
                  },
                  child: const Text('Guardar'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // ───────────────────────────────────────────────────────── Guardar ──
  List<PurchaseDraftItem> get _draftItems => _lines
      .map((l) => l.toDraftItem())
      .where(
        (item) =>
            (item.description.trim().isNotEmpty ||
                item.inventoryItemId != null) &&
            item.quantity > 0,
      )
      .toList(growable: false);

  Future<void> _submit() async {
    if (_supplierId == null || _warehouseId == null) {
      _snack('Selecciona proveedor y almacén.');
      return;
    }
    final items = _draftItems;
    if (items.isEmpty) {
      _snack('Agrega al menos un producto a la factura.');
      return;
    }

    // Descuento global de la orden (monto o %) sobre subtotal + ITBIS.
    final grossTotal = items.fold<double>(
      0,
      (sum, item) => sum + item.total + item.taxValue,
    );
    final orderDiscount =
        DiscountInput.parse(_orderDiscountCtrl.text).amountOn(grossTotal);

    final orderId = await ref
        .read(purchasesViewModelProvider)
        .createPurchaseOrder(
          supplierId: _supplierId!,
          warehouseId: _warehouseId!,
          orderNumber: _orderNumberCtrl.text.trim(),
          status: _status,
          expectedDate: _expectedDate,
          notes: _notesCtrl.text.trim(),
          invoiceNumber: _invoiceNumberCtrl.text.trim(),
          items: items,
          updateItemCost: true,
          discount: orderDiscount,
        );

    if (!mounted) return;
    if (ref.read(purchasesViewModelProvider).state.error != null) return;

    // Compra a crédito → cuenta por pagar vinculada a la orden. La orden ya
    // quedó registrada; si la CxP falla, avisamos para registrarla manual en
    // Créditos → Cuentas por Pagar (no se revierte la compra).
    if (_isCredit) {
      // La CxP nace por lo realmente adeudado: total menos descuento global.
      final total = grossTotal - orderDiscount;
      try {
        final businessId =
            ref.read(purchasesViewModelProvider).state.businessId;
        if (businessId == null) {
          throw Exception('No hay negocio activo.');
        }
        await CreditsRepository(Supabase.instance.client).createPayable(
          businessId: businessId,
          supplierId: _supplierId!,
          amount: double.parse(total.toStringAsFixed(2)),
          purchaseOrderId: orderId,
          invoiceNumber: _invoiceNumberCtrl.text.trim().isEmpty
              ? null
              : _invoiceNumberCtrl.text.trim(),
          dueDate: _creditDueDate,
          notes: 'Compra a crédito ${_orderNumberCtrl.text.trim()}',
        );
      } catch (e) {
        _snack(
          'Compra registrada, pero no se pudo crear la cuenta por pagar: $e. '
          'Regístrala manualmente en Créditos → Cuentas por Pagar.',
        );
      }
    }

    if (!mounted) return;
    context.go(AppRoutes.purchasesList);
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

// ─────────────────────────────────────────────────────── Widgets aux ──

class _AddIconButton extends StatelessWidget {
  final String tooltip;
  final VoidCallback? onPressed;

  const _AddIconButton({required this.tooltip, this.onPressed});

  @override
  Widget build(BuildContext context) {
    final borderCol = Theme.of(context).colorScheme.outline;
    return IconButton.outlined(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: const Icon(Icons.add, size: 20),
      style: IconButton.styleFrom(
        foregroundColor: Theme.of(context).colorScheme.primary,
        side: BorderSide(color: borderCol),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(MangoRadius.input),
        ),
        minimumSize: const Size(48, 48),
        maximumSize: const Size(48, 48),
      ),
    );
  }
}

/// Selector compacto del modo de ITBIS de una línea.
class _TaxModeDropdown extends StatelessWidget {
  final _TaxMode value;
  final ValueChanged<_TaxMode> onChanged;
  final bool dense;

  const _TaxModeDropdown({
    required this.value,
    required this.onChanged,
    this.dense = false,
  });

  @override
  Widget build(BuildContext context) {
    final bgCol = dense ? const Color(0xFFF8FAFC) : Colors.white;
    final borderCol = dense ? const Color(0xFFE2E8F0) : const Color(0xFFCBD5E1);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 8, vertical: dense ? 4 : 8),
      decoration: BoxDecoration(
        color: bgCol,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderCol),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<_TaxMode>(
          value: value,
          isDense: true,
          style: TextStyle(
            fontSize: dense ? 12 : 13,
            fontWeight: FontWeight.w600,
            color: const Color(0xFF0F172A),
          ),
          items: _TaxMode.values
              .map((m) => DropdownMenuItem(value: m, child: Text(m.short)))
              .toList(growable: false),
          onChanged: (m) {
            if (m != null) onChanged(m);
          },
        ),
      ),
    );
  }
}

class _HeaderCell extends StatelessWidget {
  final String label;
  final bool alignRight;
  final bool alignCenter;

  const _HeaderCell(
    this.label, {
    this.alignRight = false,
    this.alignCenter = false,
  });

  @override
  Widget build(BuildContext context) {
    final align = alignRight
        ? TextAlign.right
        : (alignCenter ? TextAlign.center : TextAlign.left);
    return Text(
      label,
      textAlign: align,
      style: const TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w700,
        color: Color(0xFF475569),
      ),
    );
  }
}

class _LineRow extends StatelessWidget {
  final _DraftItemControllers line;
  final NumberFormat currency;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  const _LineRow({
    super.key,
    required this.line,
    required this.currency,
    required this.onChanged,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final isSeparate = line.taxMode == _TaxMode.separate;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFFE2E8F0))),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            flex: 4,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  line.description.text,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                if (line.hasPack)
                  Text(
                    '1 ${line.purchaseUnit} = ${_trimNum(line.packSize)} ${line.baseUnit}',
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFF94A3B8),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: _MiniField(
              controller: line.quantity,
              suffix: line.hasPack ? line.purchaseUnit : null,
              onChanged: onChanged,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: _MiniField(controller: line.unitCost, onChanged: onChanged),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: _MiniField(
              controller: line.discount,
              hint: '0 ó %',
              allowPercent: true,
              onChanged: () {
                // Descuento y pagado son alternativas (el pagado real ya
                // debería traer el descuento aplicado).
                line.paid.clear();
                onChanged();
              },
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 176,
            child: Row(
              children: [
                _TaxModeDropdown(
                  value: line.taxMode,
                  dense: true,
                  onChanged: (m) {
                    line.taxMode = m;
                    onChanged();
                  },
                ),
                if (line.taxMode != _TaxMode.exempt) ...[
                  const SizedBox(width: 6),
                  Expanded(
                    child: _MiniField(
                      controller: line.taxPct,
                      suffix: '%',
                      onChanged: () {
                        // % y pagado son alternativas: digitar el % descarta
                        // el pagado (que tiene prioridad cuando existe).
                        line.paid.clear();
                        onChanged();
                      },
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: isSeparate
                ? _MiniField(
                    controller: line.paid,
                    hint: 'Pagado/und.',
                    onChanged: () {
                      // El pagado real ya trae el descuento: digitarlo
                      // descarta el descuento de la línea.
                      line.discount.clear();
                      onChanged();
                    },
                  )
                // En "incluido"/"exento" lo pagado por unidad ES el costo
                // digitado; se muestra como referencia (no editable).
                : Center(
                    child: Text(
                      currency.format(line.paidPerUnitDisplay),
                      style: const TextStyle(color: Color(0xFF64748B)),
                    ),
                  ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: Text(
              currency.format(line.taxAmount),
              textAlign: TextAlign.right,
              style: const TextStyle(color: Color(0xFF64748B)),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: Text(
              currency.format(line.lineTotal),
              textAlign: TextAlign.right,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 36,
            child: IconButton(
              tooltip: 'Quitar',
              onPressed: onRemove,
              icon: const Icon(Icons.close, size: 18, color: Color(0xFF94A3B8)),
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniField extends StatelessWidget {
  final TextEditingController controller;
  final String? suffix;
  final String? hint;
  // Permite el carácter '%' (campos de descuento: monto RD$ o porcentaje).
  final bool allowPercent;
  final VoidCallback onChanged;

  const _MiniField({
    required this.controller,
    required this.onChanged,
    this.suffix,
    this.hint,
    this.allowPercent = false,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [
        FilteringTextInputFormatter.allow(
          allowPercent ? RegExp(r'[0-9.%]') : RegExp(r'[0-9.]'),
        ),
      ],
      textAlign: TextAlign.center,
      style: const TextStyle(fontSize: 14),
      decoration: InputDecoration(
        isDense: true,
        hintText: hint,
        filled: true,
        fillColor: const Color(0xFFF8FAFC),
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        suffixText: suffix,
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(
            color: Theme.of(context).colorScheme.primary,
            width: 1.5,
          ),
        ),
      ),
      onChanged: (_) => onChanged(),
    );
  }
}

String _trimNum(double v) {
  final s = v.toStringAsFixed(2);
  if (s.endsWith('.00')) return s.substring(0, s.length - 3);
  if (s.endsWith('0')) return s.substring(0, s.length - 1);
  return s;
}

class _SummaryRow extends StatelessWidget {
  final String label;
  final String value;
  final bool bold;

  const _SummaryRow({
    required this.label,
    required this.value,
    this.bold = false,
  });

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontWeight: bold ? FontWeight.w800 : FontWeight.w600,
      color: const Color(0xFF0F172A),
    );
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: style.copyWith(
              color: bold ? const Color(0xFF0F172A) : const Color(0xFF64748B),
            ),
          ),
        ),
        Text(value, style: style),
      ],
    );
  }
}

/// Opción del buscador: un insumo existente o el sentinel "crear nuevo".
class _ProductOption {
  final PurchaseInventoryItem? item;
  final String rawText;

  const _ProductOption._(this.item, this.rawText);

  factory _ProductOption.item(PurchaseInventoryItem it) =>
      _ProductOption._(it, it.name);

  factory _ProductOption.create(String rawText) =>
      _ProductOption._(null, rawText);

  bool get isCreate => item == null;

  String get label => item?.name ?? rawText;
}

class _DraftItemControllers {
  // Clave estable para keys de widgets al reordenar/eliminar filas.
  static int _seq = 0;
  final int key = _seq++;

  final TextEditingController description;
  final TextEditingController quantity;
  final TextEditingController unitCost;
  // Pagado POR UNIDAD (con ITBIS) para el modo "aparte". Es por unidad, no
  // por línea, para que el ITBIS escale con la cantidad en vez de anularse.
  final TextEditingController paid;
  // % de ITBIS para el modo "aparte" (editable; el pagado tiene prioridad).
  final TextEditingController taxPct;
  // Descuento del proveedor en la línea: monto RD$ por LÍNEA o "%" (ej.
  // "150" ó "10%"). Se aplica sobre el costo digitado (con ITBIS en
  // "incluido", neto en "aparte"/"exento") ANTES de desglosar el ITBIS, así
  // neto, ITBIS, costo maestro y kardex salen del costo real pagado.
  // Descuento y pagado son alternativas: la UI limpia uno al digitar el otro.
  final TextEditingController discount;
  String? inventoryItemId;
  _TaxMode taxMode;
  // Snapshot del empaque del insumo seleccionado. La cantidad/costo se
  // digitan en la unidad de compra y se convierten a base al guardar.
  String purchaseUnit;
  double packSize;
  String baseUnit;

  _DraftItemControllers({
    String description = '',
    double quantity = 1,
    double unitCost = 0,
    double paid = 0,
    double taxPct = 18,
    String discountText = '',
    this.inventoryItemId,
    this.taxMode = _TaxMode.included,
    this.purchaseUnit = '',
    this.packSize = 1,
    this.baseUnit = '',
  }) : description = TextEditingController(text: description),
       quantity = TextEditingController(text: _fmt(quantity)),
       unitCost = TextEditingController(text: _fmt(unitCost)),
       paid = TextEditingController(text: paid <= 0 ? '' : _fmt(paid)),
       taxPct = TextEditingController(text: _fmt(taxPct)),
       discount = TextEditingController(text: discountText);

  factory _DraftItemControllers.fromItem(
    PurchaseInventoryItem item, {
    required double qty,
    required double cost,
    required _TaxMode taxMode,
    required double paid,
    double taxPct = 18,
    String discountText = '',
  }) {
    final hasPack = item.packSize > 1 && item.purchaseUnit.trim().isNotEmpty;
    return _DraftItemControllers(
      description: item.name,
      quantity: qty,
      unitCost: cost,
      paid: paid,
      taxPct: taxPct,
      discountText: discountText,
      inventoryItemId: item.id,
      taxMode: taxMode,
      purchaseUnit: hasPack ? item.purchaseUnit : '',
      packSize: hasPack ? item.packSize : 1,
      baseUnit: item.unit,
    );
  }

  static String _fmt(double v) {
    if (v == v.roundToDouble()) return v.toStringAsFixed(0);
    return v.toStringAsFixed(2);
  }

  bool get hasPack => packSize > 1 && purchaseUnit.trim().isNotEmpty;

  double get _enteredQty => double.tryParse(quantity.text.trim()) ?? 0;
  double get _enteredCost => double.tryParse(unitCost.text.trim()) ?? 0;
  double get _enteredPaid => double.tryParse(paid.text.trim()) ?? 0;
  // % digitado; vacío o ilegible cae al 18% estándar.
  double get _enteredTaxPct => double.tryParse(taxPct.text.trim()) ?? 18;

  /// Costo por unidad DIGITADO tras aplicar el descuento de la línea, en el
  /// mismo dinero del costo digitado. Un "%" rebaja el costo ese porcentaje;
  /// un monto RD$ rebaja el valor de la LÍNEA completa (se reparte entre las
  /// unidades). Clampado: el descuento nunca deja la línea negativa.
  double get _effectiveEnteredCost {
    final qty = _enteredQty;
    if (qty <= 0) return _enteredCost;
    final lineValue = _enteredCost * qty;
    final off = DiscountInput.parse(discount.text).amountOn(lineValue);
    if (off <= 0) return _enteredCost;
    return (lineValue - off) / qty;
  }

  /// Costo NETO (sin ITBIS) por unidad de compra, YA descontado. En
  /// "incluido" el desglose usa el % digitado (16, 18, lo que traiga la
  /// factura), no un 18% fijo.
  double get _netUnitEntered => taxMode == _TaxMode.included
      ? _effectiveEnteredCost / (1 + _enteredTaxPct / 100)
      : _effectiveEnteredCost;

  /// Descuento NETO (sin ITBIS) de la línea completa, para guardarlo como
  /// dato de auditoría (el neto/costo/kardex ya lo traen aplicado).
  double get lineDiscountNet {
    final qty = _enteredQty;
    if (qty <= 0) return 0;
    final undiscountedNetUnit = taxMode == _TaxMode.included
        ? _enteredCost / (1 + _enteredTaxPct / 100)
        : _enteredCost;
    final net = (undiscountedNetUnit * qty) - baseSubtotal;
    return net > 0 ? net : 0;
  }

  /// Pagado por unidad (con ITBIS) que muestra la tabla en modos sin campo
  /// editable: el costo digitado con el descuento de la línea ya aplicado
  /// ("incluido" trae ITBIS; "exento" no lleva).
  double get paidPerUnitDisplay => _effectiveEnteredCost;

  /// Base NETA de la línea (cantidad × costo neto). Consistente en unidad de
  /// compra o base porque packToBase(q)·packCostToBase(c) = q·c.
  double get baseSubtotal => _netUnitEntered * _enteredQty;

  /// ITBIS absoluto de la línea (en dinero).
  double get taxAmount {
    switch (taxMode) {
      case _TaxMode.exempt:
        return 0;
      case _TaxMode.included:
        // Bruto descontado − neto descontado (el descuento ya viene aplicado
        // en ambos, así el ITBIS también baja con el descuento).
        return (_effectiveEnteredCost * _enteredQty) - baseSubtotal;
      case _TaxMode.separate:
        // Con "Pagado por unidad" digitado, el ITBIS unitario es
        // pagado − costo neto y escala con la cantidad (antes se restaba
        // contra la base de toda la línea y con cantidad > 1 se anulaba).
        if (_enteredPaid > 0) {
          final perUnit = _enteredPaid - _netUnitEntered;
          return perUnit > 0 ? perUnit * _enteredQty : 0;
        }
        // Sin pagado, aplica el % digitado (default 18) sobre el neto.
        return baseSubtotal * (_enteredTaxPct / 100);
    }
  }

  /// Total de la línea con ITBIS.
  double get lineTotal => baseSubtotal + taxAmount;

  PurchaseDraftItem toDraftItem() {
    // Convertir a unidad base si hay empaque (ej. 6 botellas → 4500 ml;
    // costo neto por botella → costo neto por ml). Sin empaque, 1:1.
    final qtyBase = hasPack ? packToBase(_enteredQty, packSize) : _enteredQty;
    final netUnitBase = hasPack
        ? packCostToBaseCost(_netUnitEntered, packSize)
        : _netUnitEntered;
    final base = baseSubtotal;
    final tax = taxAmount;
    return PurchaseDraftItem(
      inventoryItemId: inventoryItemId,
      description: description.text.trim(),
      quantity: qtyBase,
      // Costo NETO por unidad base, YA descontado → costo maestro y
      // movimiento de stock reflejan el costo real pagado.
      unitCost: netUnitBase,
      // Tasa efectiva (por si el ITBIS no es 18% exacto en modo "aparte").
      taxRate: base > 0 ? (tax / base * 100) : 0,
      taxAmount: tax,
      discountAmount: lineDiscountNet,
      purchaseUnit: hasPack ? purchaseUnit.trim() : '',
      packSize: hasPack ? packSize : 1,
    );
  }

  void dispose() {
    description.dispose();
    quantity.dispose();
    unitCost.dispose();
    paid.dispose();
    taxPct.dispose();
    discount.dispose();
  }
}
