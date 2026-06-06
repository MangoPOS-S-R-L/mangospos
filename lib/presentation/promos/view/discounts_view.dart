import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/core/utils/app_toast.dart';

import '../state/promos_state.dart';
import '../viewmodel/promos_viewmodel.dart';

class DiscountsView extends ConsumerStatefulWidget {
  /// Modo "solo ofertas": muestra únicamente Promociones (crear/listar ofertas
  /// tipo "producto al 50% un día"). Oculta cupones y gift cards, que son parte
  /// del módulo de Fidelización. Cuando es false (default), muestra el hub
  /// completo (Promociones + Cupones + Gift Cards).
  final bool offersOnly;

  const DiscountsView({super.key, this.offersOnly = false});

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
      locale: 'en_US',
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
                  _PromoHeader(
                    offersOnly: widget.offersOnly,
                    saving: state.saving,
                    onNewPromotion: () =>
                        _showCreatePromotionDialog(context, state),
                    onNewCoupon: () => _showCreateCouponDialog(context),
                    onNewGiftCard: () => _showCreateGiftCardDialog(context),
                  ),
                  const SizedBox(height: 24),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      _SummaryCard(
                        title: 'Promociones activas',
                        value: '$activePromotions',
                        color: const Color(0xFF2563EB),
                      ),
                      if (!widget.offersOnly)
                        _SummaryCard(
                          title: 'Cupones activos',
                          value: '$activeCoupons',
                          color: const Color(0xFFF59E0B),
                        ),
                      if (!widget.offersOnly)
                        _SummaryCard(
                          title: 'Saldo gift cards',
                          value: currency.format(activeGiftBalance),
                          color: const Color(0xFF059669),
                        ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  _SectionHeader(
                    icon: Icons.local_offer_rounded,
                    title: 'Ofertas',
                    count: state.promotions.length,
                  ),
                  const SizedBox(height: 12),
                  if (state.promotions.isEmpty)
                    _PromoEmptyState(
                      onNew: () => _showCreatePromotionDialog(context, state),
                    )
                  else
                    ...state.promotions.map((item) {
                      final targetNames = state.products
                          .where((product) => item.targetIds.contains(product.id))
                          .map((product) => product.name)
                          .toList(growable: false);
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: _PromoCard(
                          item: item,
                          valueLabel: _promoLabel(item, currency),
                          scopeLabel: _targetScopeLabel(
                            item.targetScope,
                            targetNames.length,
                          ),
                          daysLabel: item.daysOfWeek.isEmpty
                              ? 'Todos los días'
                              : item.daysOfWeek
                                  .map((day) => _weekdayLabels[day] ?? '$day')
                                  .join(', '),
                          minPurchaseLabel: currency.format(item.minPurchase),
                          endDateLabel: item.endDate == null
                              ? null
                              : dateFormat.format(item.endDate!),
                          targetNames: targetNames,
                          onEdit: () => _showCreatePromotionDialog(
                            context,
                            state,
                            existing: item,
                          ),
                        ),
                      );
                    }),
                  if (!widget.offersOnly) const SizedBox(height: 20),
                  if (!widget.offersOnly)
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
                  if (!widget.offersOnly) const SizedBox(height: 20),
                  if (!widget.offersOnly)
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
        return '${buy}x$pay';
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
    PromosState state, {
    PromotionSummary? existing,
  }) async {
    final result = await showDialog<_PromotionDraft>(
      context: context,
      builder: (dialogContext) =>
          _PromotionDialog(products: state.products, existing: existing),
    );
    if (result == null) return;

    final vm = ref.read(promosViewModelProvider);
    final editing = result.id != null;
    try {
      if (editing) {
        await vm.updatePromotion(
          id: result.id!,
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
          isActive: result.isActive,
        );
      } else {
        await vm.createPromotion(
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
    } catch (_) {
      // El viewmodel ya guardó el detalle en state.error; lo mostramos abajo.
    }

    if (!context.mounted) return;
    final error = ref.read(promosViewModelProvider).state.error;
    if (error == null) {
      AppToast.success(
        context,
        editing
            ? 'Oferta "${result.name}" actualizada.'
            : 'Oferta "${result.name}" creada correctamente.',
      );
    } else {
      AppToast.error(context, error);
    }
  }

  Future<void> _showCreateCouponDialog(BuildContext context) async {
    final rootContext = context;
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
                    if (code.isEmpty) {
                      AppToast.warning(dialogContext, 'Ingresa un código.');
                      return;
                    }
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
                    final error =
                        ref.read(promosViewModelProvider).state.error;
                    Navigator.of(dialogContext).pop();
                    if (!rootContext.mounted) return;
                    if (error == null) {
                      AppToast.success(rootContext, 'Cupón "$code" creado.');
                    } else {
                      AppToast.error(rootContext, error);
                    }
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
    final rootContext = context;
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
                    if (code.isEmpty) {
                      AppToast.warning(dialogContext, 'Ingresa un código.');
                      return;
                    }
                    await ref
                        .read(promosViewModelProvider)
                        .createGiftCard(
                          code: code,
                          initialBalance:
                              double.tryParse(balanceCtrl.text.trim()) ?? 0,
                          expiresAt: expiresAt,
                        );
                    if (!dialogContext.mounted) return;
                    final error =
                        ref.read(promosViewModelProvider).state.error;
                    Navigator.of(dialogContext).pop();
                    if (!rootContext.mounted) return;
                    if (error == null) {
                      AppToast.success(rootContext, 'Gift card "$code" creada.');
                    } else {
                      AppToast.error(rootContext, error);
                    }
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
  /// id de la oferta cuando se está EDITANDO; null al crear.
  final String? id;
  final bool isActive;
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
    this.id,
    this.isActive = true,
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

  /// Oferta a editar; null = crear nueva.
  final PromotionSummary? existing;

  const _PromotionDialog({required this.products, this.existing});

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
  bool _isActive = true;
  final Set<int> _selectedDays = <int>{};
  final Set<String> _selectedProductIds = <String>{};
  DateTime _startDate = DateTime.now();
  DateTime _endDate = DateTime.now().add(const Duration(days: 30));

  bool get _isEditing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e == null) return;
    // Precargar campos al EDITAR.
    _nameCtrl.text = e.name;
    _descriptionCtrl.text = e.description;
    _valueCtrl.text = e.discountValue == 0
        ? ''
        : (e.discountValue % 1 == 0
            ? e.discountValue.toStringAsFixed(0)
            : e.discountValue.toString());
    _minPurchaseCtrl.text = e.minPurchase == 0
        ? '0'
        : (e.minPurchase % 1 == 0
            ? e.minPurchase.toStringAsFixed(0)
            : e.minPurchase.toString());
    _priorityCtrl.text = '${e.priority}';
    _buyQtyCtrl.text = '${e.buyQuantity ?? 2}';
    _payQtyCtrl.text = '${e.payQuantity ?? 1}';
    _promoType = e.promoType;
    _targetScope = e.targetScope;
    _autoApply = e.autoApply;
    _stackable = e.stackable;
    _isActive = e.isActive;
    _selectedDays
      ..clear()
      ..addAll(e.daysOfWeek);
    _selectedProductIds
      ..clear()
      ..addAll(e.targetIds);
    if (e.startDate != null) _startDate = e.startDate!;
    if (e.endDate != null) _endDate = e.endDate!;
  }

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
      title: Text(_isEditing ? 'Editar oferta' : 'Nueva oferta'),
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
                          child: Text('Lleva X paga Y (2x1, 4x3…)'),
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
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('Oferta activa'),
                subtitle: const Text(
                  'Desactívala para pausarla sin borrarla',
                ),
                value: _isActive,
                onChanged: (value) => setState(() => _isActive = value),
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
    if (name.isEmpty) {
      AppToast.warning(context, 'Ponle un nombre a la oferta.');
      return;
    }
    if (_targetScope == 'product' && _selectedProductIds.isEmpty) {
      AppToast.warning(
        context,
        'Selecciona al menos un producto para esta oferta.',
      );
      return;
    }
    if (_promoType != 'bogo') {
      final value = double.tryParse(_valueCtrl.text.trim()) ?? 0;
      if (value <= 0) {
        AppToast.warning(context, 'Ingresa un valor de descuento mayor a 0.');
        return;
      }
    }

    final promoType = _promoType;
    final draft = _PromotionDraft(
      id: widget.existing?.id,
      isActive: _isActive,
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

// ===========================================================================
// UI profesional del módulo de Ofertas
// ===========================================================================

/// Estilo visual por tipo de promoción (ícono, color y etiqueta).
({IconData icon, Color color, String label}) _promoTypeStyle(String type) {
  switch (type) {
    case 'bogo':
      return (
        icon: Icons.redeem_rounded,
        color: const Color(0xFF7C3AED),
        label: 'Lleva X paga Y',
      );
    case 'fixed':
      return (
        icon: Icons.payments_rounded,
        color: const Color(0xFF2563EB),
        label: 'Monto fijo',
      );
    case 'bundle_price':
      return (
        icon: Icons.inventory_2_rounded,
        color: const Color(0xFF0891B2),
        label: 'Precio promo',
      );
    case 'percentage':
    default:
      return (
        icon: Icons.percent_rounded,
        color: MangoColors.primaryOrange,
        label: 'Porcentaje',
      );
  }
}

/// Encabezado con degradado del módulo de ofertas.
class _PromoHeader extends StatelessWidget {
  final bool offersOnly;
  final bool saving;
  final VoidCallback onNewPromotion;
  final VoidCallback onNewCoupon;
  final VoidCallback onNewGiftCard;

  const _PromoHeader({
    required this.offersOnly,
    required this.saving,
    required this.onNewPromotion,
    required this.onNewCoupon,
    required this.onNewGiftCard,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFF97316), Color(0xFFEA580C)],
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: const [
          BoxShadow(
            color: Color(0x33EA580C),
            blurRadius: 24,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 54,
                height: 54,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(15),
                ),
                child: const Icon(
                  Icons.local_offer_rounded,
                  color: Colors.white,
                  size: 28,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      offersOnly
                          ? 'Ofertas y Promociones'
                          : 'Promociones y fidelización',
                      style: const TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                        letterSpacing: -0.5,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      offersOnly
                          ? 'Crea ofertas por día y producto: ej. vender un producto al 50% un día, o un 4x3.'
                          : 'Promos por día, productos, cupones y gift cards.',
                      style: TextStyle(
                        fontSize: 13.5,
                        color: Colors.white.withValues(alpha: 0.92),
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: const Color(0xFFEA580C),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 14,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  textStyle: const TextStyle(fontWeight: FontWeight.w700),
                ),
                onPressed: saving ? null : onNewPromotion,
                icon: const Icon(Icons.add_rounded, size: 20),
                label: const Text('Nueva oferta'),
              ),
              if (!offersOnly)
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: BorderSide(
                      color: Colors.white.withValues(alpha: 0.6),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 14,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: saving ? null : onNewCoupon,
                  icon: const Icon(Icons.confirmation_number_outlined, size: 20),
                  label: const Text('Nuevo cupón'),
                ),
              if (!offersOnly)
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: BorderSide(
                      color: Colors.white.withValues(alpha: 0.6),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 14,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: saving ? null : onNewGiftCard,
                  icon: const Icon(Icons.card_giftcard, size: 20),
                  label: const Text('Nueva gift card'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Título de sección con ícono y contador.
class _SectionHeader extends StatelessWidget {
  final IconData icon;
  final String title;
  final int count;

  const _SectionHeader({
    required this.icon,
    required this.title,
    required this.count,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: MangoColors.primaryOrange, size: 20),
        const SizedBox(width: 8),
        Text(
          title,
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w800,
            color: Color(0xFF0F172A),
          ),
        ),
        const SizedBox(width: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
          decoration: BoxDecoration(
            color: const Color(0xFFF1F5F9),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            '$count',
            style: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: Color(0xFF475569),
            ),
          ),
        ),
      ],
    );
  }
}

/// Estado vacío profesional con llamada a la acción.
class _PromoEmptyState extends StatelessWidget {
  final VoidCallback onNew;

  const _PromoEmptyState({required this.onNew});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE8EDF3)),
      ),
      child: Column(
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: MangoColors.primaryOrange.withValues(alpha: 0.10),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.local_offer_rounded,
              color: MangoColors.primaryOrange,
              size: 30,
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Aún no tienes ofertas',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: Color(0xFF0F172A),
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Crea tu primera oferta: un producto al 50% un día, un 4x3, o un descuento por monto.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13.5, color: Color(0xFF64748B), height: 1.4),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: MangoColors.primaryOrange,
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: onNew,
            icon: const Icon(Icons.add_rounded, size: 20),
            label: const Text('Crear primera oferta'),
          ),
        ],
      ),
    );
  }
}

/// Tarjeta profesional de una oferta.
class _PromoCard extends StatelessWidget {
  final PromotionSummary item;
  final String valueLabel;
  final String scopeLabel;
  final String daysLabel;
  final String minPurchaseLabel;
  final String? endDateLabel;
  final List<String> targetNames;
  final VoidCallback onEdit;

  const _PromoCard({
    required this.item,
    required this.valueLabel,
    required this.scopeLabel,
    required this.daysLabel,
    required this.minPurchaseLabel,
    this.endDateLabel,
    required this.targetNames,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final type = _promoTypeStyle(item.promoType);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE8EDF3)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0F0F172A),
            blurRadius: 14,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: type.color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Icon(type.icon, color: type.color, size: 25),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            item.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF0F172A),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        _StatusPill(active: item.isActive),
                        const SizedBox(width: 2),
                        IconButton(
                          onPressed: onEdit,
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 36,
                            minHeight: 36,
                          ),
                          tooltip: 'Editar oferta',
                          icon: const Icon(
                            Icons.edit_outlined,
                            size: 19,
                            color: Color(0xFF64748B),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        _BadgeSmall(text: type.label, color: type.color),
                        const SizedBox(width: 10),
                        Text(
                          valueLabel,
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                            color: type.color,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 14),
            child: Divider(height: 1, color: Color(0xFFF1F5F9)),
          ),
          Wrap(
            spacing: 16,
            runSpacing: 8,
            children: [
              _MetaItem(icon: Icons.sell_outlined, text: scopeLabel),
              _MetaItem(icon: Icons.event_outlined, text: daysLabel),
              if (endDateLabel != null)
                _MetaItem(
                  icon: Icons.schedule_outlined,
                  text: 'Hasta $endDateLabel',
                ),
              _MetaItem(
                icon: Icons.shopping_bag_outlined,
                text: 'Mín. $minPurchaseLabel',
              ),
              if (item.autoApply)
                const _MetaItem(
                  icon: Icons.bolt_rounded,
                  text: 'Auto-aplica',
                  color: MangoColors.successGreen,
                ),
            ],
          ),
          if (targetNames.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: targetNames
                  .take(8)
                  .map((name) => _TagChip(label: name))
                  .toList(growable: false),
            ),
          ],
        ],
      ),
    );
  }
}

/// Pastilla de estado Activa/Inactiva.
class _StatusPill extends StatelessWidget {
  final bool active;

  const _StatusPill({required this.active});

  @override
  Widget build(BuildContext context) {
    final color = active
        ? MangoColors.successGreen
        : const Color(0xFF94A3B8);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            active ? 'Activa' : 'Inactiva',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

/// Badge pequeño coloreado (etiqueta de tipo).
class _BadgeSmall extends StatelessWidget {
  final String text;
  final Color color;

  const _BadgeSmall({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}

/// Ítem de metadato (ícono + texto) usado en la tarjeta de oferta.
class _MetaItem extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color? color;

  const _MetaItem({required this.icon, required this.text, this.color});

  @override
  Widget build(BuildContext context) {
    final c = color ?? const Color(0xFF64748B);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: c),
        const SizedBox(width: 5),
        Text(
          text,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: color ?? const Color(0xFF475569),
          ),
        ),
      ],
    );
  }
}
