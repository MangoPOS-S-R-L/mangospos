import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../state/promos_state.dart';
import '../viewmodel/promos_viewmodel.dart';

class DiscountsView extends ConsumerStatefulWidget {
  const DiscountsView({super.key});

  @override
  ConsumerState<DiscountsView> createState() => _DiscountsViewState();
}

class _DiscountsViewState extends ConsumerState<DiscountsView> {
  static const _weekdayLabels = <int, String>{
    0: 'Dom',
    1: 'Lun',
    2: 'Mar',
    3: 'Mié',
    4: 'Jue',
    5: 'Vie',
    6: 'Sáb',
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(promosViewModelProvider).init();
    });
  }

  @override
  Widget build(BuildContext context) {
    final vm = ref.watch(promosViewModelProvider);
    final state = vm.state;
    final currency = NumberFormat.currency(
      locale: 'es_DO',
      symbol: 'RD\$',
      decimalDigits: 2,
    );
    final dateFormat = DateFormat('dd/MM/yyyy');

    final activePromotions = state.promotions
        .where((item) => item.isActive)
        .length;
    final activeCoupons = state.coupons.where((item) => item.isActive).length;
    final activeGiftBalance = state.giftCards
        .where((item) => item.isActive)
        .fold<double>(0, (sum, item) => sum + item.currentBalance);

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      body:
          state.loading &&
              state.promotions.isEmpty &&
              state.coupons.isEmpty &&
              state.giftCards.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Promociones y fidelización',
                            style: TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF0F172A),
                            ),
                          ),
                          SizedBox(height: 6),
                          Text(
                            'Promos por día, productos seleccionados, cupones y gift cards',
                            style: TextStyle(
                              fontSize: 14,
                              color: Color(0xFF64748B),
                            ),
                          ),
                        ],
                      ),
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          OutlinedButton.icon(
                            onPressed: state.saving
                                ? null
                                : () => _showCreatePromotionDialog(
                                    context,
                                    state,
                                  ),
                            icon: const Icon(Icons.local_offer_outlined),
                            label: const Text('Nueva promoción'),
                          ),
                          OutlinedButton.icon(
                            onPressed: state.saving
                                ? null
                                : () => _showCreateCouponDialog(context),
                            icon: const Icon(
                              Icons.confirmation_number_outlined,
                            ),
                            label: const Text('Nuevo cupón'),
                          ),
                          FilledButton.icon(
                            onPressed: state.saving
                                ? null
                                : () => _showCreateGiftCardDialog(context),
                            icon: const Icon(Icons.card_giftcard),
                            label: const Text('Nueva gift card'),
                          ),
                        ],
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
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      _SummaryCard(
                        title: 'Promociones activas',
                        value: '$activePromotions',
                        color: const Color(0xFF2563EB),
                      ),
                      _SummaryCard(
                        title: 'Cupones activos',
                        value: '$activeCoupons',
                        color: const Color(0xFFF59E0B),
                      ),
                      _SummaryCard(
                        title: 'Saldo gift cards',
                        value: currency.format(activeGiftBalance),
                        color: const Color(0xFF059669),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  _SectionCard(
                    title: 'Promociones',
                    emptyMessage: 'No hay promociones registradas.',
                    child: state.promotions.isEmpty
                        ? null
                        : ListView.separated(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            itemCount: state.promotions.length,
                            separatorBuilder: (context, index) =>
                                const Divider(height: 1),
                            itemBuilder: (context, index) {
                              final item = state.promotions[index];
                              final targetNames = state.products
                                  .where(
                                    (product) =>
                                        item.targetIds.contains(product.id),
                                  )
                                  .map((product) => product.name)
                                  .toList(growable: false);
                              final scopeLabel = _targetScopeLabel(
                                item.targetScope,
                                targetNames.length,
                              );
                              final daysLabel = item.daysOfWeek.isEmpty
                                  ? 'Todos los días'
                                  : item.daysOfWeek
                                        .map(
                                          (day) =>
                                              _weekdayLabels[day] ?? '$day',
                                        )
                                        .join(', ');

                              return ListTile(
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                  vertical: 6,
                                ),
                                title: Text(
                                  item.name,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                subtitle: Padding(
                                  padding: const EdgeInsets.only(top: 6),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '${_promoLabel(item, currency)} · Min compra ${currency.format(item.minPurchase)}',
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        '$scopeLabel · $daysLabel${item.endDate == null ? '' : ' · Hasta ${dateFormat.format(item.endDate!)}'}',
                                        style: const TextStyle(
                                          color: Color(0xFF64748B),
                                        ),
                                      ),
                                      if (targetNames.isNotEmpty) ...[
                                        const SizedBox(height: 8),
                                        Wrap(
                                          spacing: 8,
                                          runSpacing: 8,
                                          children: targetNames
                                              .take(6)
                                              .map(
                                                (name) => _TagChip(label: name),
                                              )
                                              .toList(growable: false),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                                trailing: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Text(
                                      item.isActive ? 'Activa' : 'Inactiva',
                                      style: TextStyle(
                                        color: item.isActive
                                            ? const Color(0xFF059669)
                                            : const Color(0xFF94A3B8),
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      'Prioridad ${item.priority}',
                                      style: const TextStyle(
                                        color: Color(0xFF64748B),
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                  ),
                  const SizedBox(height: 20),
                  _SectionCard(
                    title: 'Cupones',
                    emptyMessage: 'No hay cupones registrados.',
                    child: state.coupons.isEmpty
                        ? null
                        : ListView.separated(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            itemCount: state.coupons.length,
                            separatorBuilder: (context, index) =>
                                const Divider(height: 1),
                            itemBuilder: (context, index) {
                              final item = state.coupons[index];
                              final usageLabel = item.usageLimit == null
                                  ? '${item.timesUsed} usos'
                                  : '${item.timesUsed}/${item.usageLimit} usos';
                              return ListTile(
                                title: Text(item.code),
                                subtitle: Text(
                                  '${_discountLabel(item.discountType, item.discountValue)} · $usageLabel${item.validUntil == null ? '' : ' · Hasta ${dateFormat.format(item.validUntil!)}'}',
                                ),
                                trailing: Text(
                                  item.isActive ? 'Activo' : 'Inactivo',
                                  style: TextStyle(
                                    color: item.isActive
                                        ? const Color(0xFF059669)
                                        : const Color(0xFF94A3B8),
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                  const SizedBox(height: 20),
                  _SectionCard(
                    title: 'Gift Cards',
                    emptyMessage: 'No hay gift cards registradas.',
                    child: state.giftCards.isEmpty
                        ? null
                        : ListView.separated(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            itemCount: state.giftCards.length,
                            separatorBuilder: (context, index) =>
                                const Divider(height: 1),
                            itemBuilder: (context, index) {
                              final item = state.giftCards[index];
                              return ListTile(
                                title: Text(item.code),
                                subtitle: Text(
                                  'Inicial ${currency.format(item.initialBalance)} · Disponible ${currency.format(item.currentBalance)}${item.expiresAt == null ? '' : ' · Expira ${dateFormat.format(item.expiresAt!)}'}',
                                ),
                                trailing: Text(
                                  item.isActive ? 'Activa' : 'Inactiva',
                                  style: TextStyle(
                                    color: item.isActive
                                        ? const Color(0xFF059669)
                                        : const Color(0xFF94A3B8),
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
    );
  }

  String _discountLabel(String type, double value) {
    switch (type) {
      case 'fixed':
        return 'Descuento fijo RD\$${value.toStringAsFixed(2)}';
      case 'bogo':
        return 'Promoción BOGO';
      case 'percentage':
      default:
        return 'Descuento ${value.toStringAsFixed(0)}%';
    }
  }

  String _promoLabel(PromotionSummary item, NumberFormat currency) {
    switch (item.promoType) {
      case 'bogo':
        final buy = item.buyQuantity ?? 2;
        final pay = item.payQuantity ?? 1;
        return '$buy x $pay';
      case 'fixed':
        return 'Descuento fijo ${currency.format(item.discountValue)}';
      case 'bundle_price':
        return 'Precio promo ${currency.format(item.discountValue)}';
      case 'percentage':
      default:
        return 'Descuento ${item.discountValue.toStringAsFixed(0)}%';
    }
  }

  String _targetScopeLabel(String scope, int count) {
    switch (scope) {
      case 'product':
        return count <= 0 ? 'Productos específicos' : '$count productos';
      case 'category':
        return 'Categorías';
      default:
        return 'Todo el menú';
    }
  }

  Future<void> _showCreatePromotionDialog(
    BuildContext context,
    PromosState state,
  ) async {
    final result = await showDialog<_PromotionDraft>(
      context: context,
      builder: (dialogContext) => _PromotionDialog(products: state.products),
    );
    if (result == null) return;

    await ref
        .read(promosViewModelProvider)
        .createPromotion(
          name: result.name,
          description: result.description,
          discountType: result.discountType,
          promoType: result.promoType,
          discountValue: result.discountValue,
          minPurchase: result.minPurchase,
          appliesTo: result.targetScope,
          targetScope: result.targetScope,
          targetIds: result.targetIds,
          daysOfWeek: result.daysOfWeek,
          autoApply: result.autoApply,
          stackable: result.stackable,
          priority: result.priority,
          buyQuantity: result.buyQuantity,
          payQuantity: result.payQuantity,
          rewardQuantity: result.rewardQuantity,
          startDate: result.startDate,
          endDate: result.endDate,
        );
  }

  Future<void> _showCreateCouponDialog(BuildContext context) async {
    final codeCtrl = TextEditingController();
    final valueCtrl = TextEditingController(text: '10');
    final minPurchaseCtrl = TextEditingController(text: '0');
    final usageCtrl = TextEditingController();
    String discountType = 'percentage';
    DateTime validFrom = DateTime.now();
    DateTime validUntil = DateTime.now().add(const Duration(days: 30));

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Nuevo cupón'),
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: codeCtrl,
                      decoration: const InputDecoration(labelText: 'Código'),
                    ),
                    DropdownButtonFormField<String>(
                      initialValue: discountType,
                      decoration: const InputDecoration(
                        labelText: 'Tipo de descuento',
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: 'percentage',
                          child: Text('Porcentaje'),
                        ),
                        DropdownMenuItem(
                          value: 'fixed',
                          child: Text('Monto fijo'),
                        ),
                      ],
                      onChanged: (value) {
                        if (value == null) return;
                        setDialogState(() {
                          discountType = value;
                        });
                      },
                    ),
                    TextField(
                      controller: valueCtrl,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(labelText: 'Valor'),
                    ),
                    TextField(
                      controller: minPurchaseCtrl,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'Compra mínima',
                      ),
                    ),
                    TextField(
                      controller: usageCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Límite de usos (opcional)',
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () async {
                              final picked = await showDatePicker(
                                context: dialogContext,
                                initialDate: validFrom,
                                firstDate: DateTime.now().subtract(
                                  const Duration(days: 365),
                                ),
                                lastDate: DateTime.now().add(
                                  const Duration(days: 365),
                                ),
                              );
                              if (picked == null) return;
                              setDialogState(() {
                                validFrom = picked;
                              });
                            },
                            child: Text(
                              'Desde ${DateFormat('dd/MM/yyyy').format(validFrom)}',
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () async {
                              final picked = await showDatePicker(
                                context: dialogContext,
                                initialDate: validUntil,
                                firstDate: validFrom,
                                lastDate: DateTime.now().add(
                                  const Duration(days: 730),
                                ),
                              );
                              if (picked == null) return;
                              setDialogState(() {
                                validUntil = picked;
                              });
                            },
                            child: Text(
                              'Hasta ${DateFormat('dd/MM/yyyy').format(validUntil)}',
                            ),
                          ),
                        ),
                      ],
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
                    final code = codeCtrl.text.trim().toUpperCase();
                    if (code.isEmpty) return;
                    await ref
                        .read(promosViewModelProvider)
                        .createCoupon(
                          code: code,
                          discountType: discountType,
                          discountValue:
                              double.tryParse(valueCtrl.text.trim()) ?? 0,
                          usageLimit: int.tryParse(usageCtrl.text.trim()),
                          minPurchase:
                              double.tryParse(minPurchaseCtrl.text.trim()) ?? 0,
                          validFrom: validFrom,
                          validUntil: validUntil,
                        );
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

  Future<void> _showCreateGiftCardDialog(BuildContext context) async {
    final codeCtrl = TextEditingController();
    final balanceCtrl = TextEditingController(text: '1000');
    DateTime? expiresAt;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Nueva gift card'),
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: codeCtrl,
                      decoration: const InputDecoration(labelText: 'Código'),
                    ),
                    TextField(
                      controller: balanceCtrl,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'Balance inicial',
                      ),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton(
                      onPressed: () async {
                        final picked = await showDatePicker(
                          context: dialogContext,
                          initialDate:
                              expiresAt ??
                              DateTime.now().add(const Duration(days: 365)),
                          firstDate: DateTime.now(),
                          lastDate: DateTime.now().add(
                            const Duration(days: 1825),
                          ),
                        );
                        if (picked == null) return;
                        setDialogState(() {
                          expiresAt = picked;
                        });
                      },
                      child: Text(
                        expiresAt == null
                            ? 'Sin fecha de expiración'
                            : 'Expira ${DateFormat('dd/MM/yyyy').format(expiresAt!)}',
                      ),
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
                    final code = codeCtrl.text.trim().toUpperCase();
                    if (code.isEmpty) return;
                    await ref
                        .read(promosViewModelProvider)
                        .createGiftCard(
                          code: code,
                          initialBalance:
                              double.tryParse(balanceCtrl.text.trim()) ?? 0,
                          expiresAt: expiresAt,
                        );
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
}

class _PromotionDraft {
  final String name;
  final String description;
  final String discountType;
  final String promoType;
  final double discountValue;
  final double minPurchase;
  final String targetScope;
  final List<String> targetIds;
  final List<int> daysOfWeek;
  final bool autoApply;
  final bool stackable;
  final int priority;
  final int? buyQuantity;
  final int? payQuantity;
  final int? rewardQuantity;
  final DateTime startDate;
  final DateTime endDate;

  const _PromotionDraft({
    required this.name,
    required this.description,
    required this.discountType,
    required this.promoType,
    required this.discountValue,
    required this.minPurchase,
    required this.targetScope,
    required this.targetIds,
    required this.daysOfWeek,
    required this.autoApply,
    required this.stackable,
    required this.priority,
    required this.buyQuantity,
    required this.payQuantity,
    required this.rewardQuantity,
    required this.startDate,
    required this.endDate,
  });
}

class _PromotionDialog extends StatefulWidget {
  final List<PromoProductSummary> products;

  const _PromotionDialog({required this.products});

  @override
  State<_PromotionDialog> createState() => _PromotionDialogState();
}

class _PromotionDialogState extends State<_PromotionDialog> {
  static const _weekdays = <int, String>{
    0: 'Domingo',
    1: 'Lunes',
    2: 'Martes',
    3: 'Miércoles',
    4: 'Jueves',
    5: 'Viernes',
    6: 'Sábado',
  };

  final _nameCtrl = TextEditingController();
  final _descriptionCtrl = TextEditingController();
  final _valueCtrl = TextEditingController(text: '10');
  final _minPurchaseCtrl = TextEditingController(text: '0');
  final _priorityCtrl = TextEditingController(text: '0');
  final _buyQtyCtrl = TextEditingController(text: '2');
  final _payQtyCtrl = TextEditingController(text: '1');
  final _searchCtrl = TextEditingController();

  String _promoType = 'percentage';
  String _targetScope = 'all';
  bool _autoApply = true;
  bool _stackable = false;
  final Set<int> _selectedDays = <int>{};
  final Set<String> _selectedProductIds = <String>{};
  DateTime _startDate = DateTime.now();
  DateTime _endDate = DateTime.now().add(const Duration(days: 30));

  @override
  void dispose() {
    _nameCtrl.dispose();
    _descriptionCtrl.dispose();
    _valueCtrl.dispose();
    _minPurchaseCtrl.dispose();
    _priorityCtrl.dispose();
    _buyQtyCtrl.dispose();
    _payQtyCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final filteredProducts = widget.products
        .where((product) => product.isActive)
        .where((product) {
          final query = _searchCtrl.text.trim().toLowerCase();
          if (query.isEmpty) return true;
          return product.name.toLowerCase().contains(query);
        })
        .toList(growable: false);

    final isBogo = _promoType == 'bogo';
    final isAll = _targetScope == 'all';

    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(24, 22, 24, 0),
      contentPadding: const EdgeInsets.fromLTRB(24, 18, 24, 12),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      title: const Text('Nueva promoción'),
      content: SizedBox(
        width: 760,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _nameCtrl,
                      decoration: const InputDecoration(labelText: 'Nombre'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 180,
                    child: TextField(
                      controller: _priorityCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Prioridad'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _descriptionCtrl,
                decoration: const InputDecoration(labelText: 'Descripción'),
                maxLines: 2,
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _promoType,
                      decoration: const InputDecoration(labelText: 'Tipo'),
                      items: const [
                        DropdownMenuItem(
                          value: 'percentage',
                          child: Text('Porcentaje'),
                        ),
                        DropdownMenuItem(
                          value: 'fixed',
                          child: Text('Monto fijo'),
                        ),
                        DropdownMenuItem(
                          value: 'bogo',
                          child: Text('2x1 / BOGO'),
                        ),
                        DropdownMenuItem(
                          value: 'bundle_price',
                          child: Text('Precio promo'),
                        ),
                      ],
                      onChanged: (value) {
                        if (value == null) return;
                        setState(() {
                          _promoType = value;
                        });
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _targetScope,
                      decoration: const InputDecoration(labelText: 'Aplica a'),
                      items: const [
                        DropdownMenuItem(
                          value: 'all',
                          child: Text('Todo el menú'),
                        ),
                        DropdownMenuItem(
                          value: 'product',
                          child: Text('Productos específicos'),
                        ),
                      ],
                      onChanged: (value) {
                        if (value == null) return;
                        setState(() {
                          _targetScope = value;
                          if (value == 'all') {
                            _selectedProductIds.clear();
                          }
                        });
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _valueCtrl,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: InputDecoration(
                        labelText: isBogo
                            ? 'Valor referencial (opcional)'
                            : 'Valor',
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _minPurchaseCtrl,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'Compra mínima',
                      ),
                    ),
                  ),
                ],
              ),
              if (isBogo) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _buyQtyCtrl,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: 'Lleva'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _payQtyCtrl,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: 'Paga'),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 16),
              const Text(
                'Días de aplicación',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF0F172A),
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _weekdays.entries
                    .map((entry) {
                      final selected = _selectedDays.contains(entry.key);
                      return FilterChip(
                        selected: selected,
                        label: Text(entry.value),
                        onSelected: (value) {
                          setState(() {
                            if (value) {
                              _selectedDays.add(entry.key);
                            } else {
                              _selectedDays.remove(entry.key);
                            }
                          });
                        },
                      );
                    })
                    .toList(growable: false),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () async {
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: _startDate,
                          firstDate: DateTime.now().subtract(
                            const Duration(days: 365),
                          ),
                          lastDate: DateTime.now().add(
                            const Duration(days: 365),
                          ),
                        );
                        if (picked == null) return;
                        setState(() {
                          _startDate = picked;
                          if (_endDate.isBefore(_startDate)) {
                            _endDate = _startDate;
                          }
                        });
                      },
                      child: Text(
                        'Inicio ${DateFormat('dd/MM/yyyy').format(_startDate)}',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () async {
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: _endDate,
                          firstDate: _startDate,
                          lastDate: DateTime.now().add(
                            const Duration(days: 730),
                          ),
                        );
                        if (picked == null) return;
                        setState(() {
                          _endDate = picked;
                        });
                      },
                      child: Text(
                        'Fin ${DateFormat('dd/MM/yyyy').format(_endDate)}',
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('Aplicar automáticamente'),
                subtitle: const Text(
                  'La promo entra sola cuando el pedido cumple',
                ),
                value: _autoApply,
                onChanged: (value) => setState(() => _autoApply = value),
              ),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('Permitir combinar con otras promos'),
                subtitle: const Text(
                  'Útil si luego soportas stacking por prioridad',
                ),
                value: _stackable,
                onChanged: (value) => setState(() => _stackable = value),
              ),
              if (!isAll) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFFE2E8F0)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Productos incluidos',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF0F172A),
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _searchCtrl,
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.search),
                          hintText: 'Buscar productos',
                        ),
                      ),
                      const SizedBox(height: 12),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 240),
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemCount: filteredProducts.length,
                          separatorBuilder: (context, index) =>
                              const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final product = filteredProducts[index];
                            final selected = _selectedProductIds.contains(
                              product.id,
                            );
                            return CheckboxListTile(
                              value: selected,
                              controlAffinity: ListTileControlAffinity.leading,
                              contentPadding: EdgeInsets.zero,
                              title: Text(product.name),
                              onChanged: (value) {
                                setState(() {
                                  if (value == true) {
                                    _selectedProductIds.add(product.id);
                                  } else {
                                    _selectedProductIds.remove(product.id);
                                  }
                                });
                              },
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Guardar')),
      ],
    );
  }

  void _submit() {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) return;
    if (_targetScope == 'product' && _selectedProductIds.isEmpty) return;

    final promoType = _promoType;
    final draft = _PromotionDraft(
      name: name,
      description: _descriptionCtrl.text.trim(),
      discountType: promoType,
      promoType: promoType,
      discountValue: double.tryParse(_valueCtrl.text.trim()) ?? 0,
      minPurchase: double.tryParse(_minPurchaseCtrl.text.trim()) ?? 0,
      targetScope: _targetScope,
      targetIds: _selectedProductIds.toList(growable: false),
      daysOfWeek: _selectedDays.toList()..sort(),
      autoApply: _autoApply,
      stackable: _stackable,
      priority: int.tryParse(_priorityCtrl.text.trim()) ?? 0,
      buyQuantity: promoType == 'bogo'
          ? int.tryParse(_buyQtyCtrl.text.trim()) ?? 2
          : null,
      payQuantity: promoType == 'bogo'
          ? int.tryParse(_payQtyCtrl.text.trim()) ?? 1
          : null,
      rewardQuantity: promoType == 'bogo'
          ? ((int.tryParse(_buyQtyCtrl.text.trim()) ?? 2) -
                    (int.tryParse(_payQtyCtrl.text.trim()) ?? 1))
                .clamp(1, 999)
          : null,
      startDate: _startDate,
      endDate: _endDate,
    );

    Navigator.of(context).pop(draft);
  }
}

class _SummaryCard extends StatelessWidget {
  final String title;
  final String value;
  final Color color;

  const _SummaryCard({
    required this.title,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 220,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: Color(0xFF64748B),
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: TextStyle(
              color: color,
              fontSize: 24,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  final String title;
  final String emptyMessage;
  final Widget? child;

  const _SectionCard({
    required this.title,
    required this.emptyMessage,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: Color(0xFF0F172A),
            ),
          ),
          const SizedBox(height: 16),
          if (child == null)
            Text(emptyMessage, style: const TextStyle(color: Color(0xFF64748B)))
          else
            child!,
        ],
      ),
    );
  }
}

class _TagChip extends StatelessWidget {
  final String label;

  const _TagChip({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: Color(0xFF334155),
        ),
      ),
    );
  }
}
