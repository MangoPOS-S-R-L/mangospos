import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../viewmodel/promos_viewmodel.dart';

class DiscountsView extends ConsumerStatefulWidget {
  const DiscountsView({super.key});

  @override
  ConsumerState<DiscountsView> createState() => _DiscountsViewState();
}

class _DiscountsViewState extends ConsumerState<DiscountsView> {
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

    final activePromotions = state.promotions.where((item) => item.isActive).length;
    final activeCoupons = state.coupons.where((item) => item.isActive).length;
    final activeGiftBalance = state.giftCards
        .where((item) => item.isActive)
        .fold<double>(0, (sum, item) => sum + item.currentBalance);

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      body: state.loading &&
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
                            'Gestiona promociones, cupones y gift cards del negocio',
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
                                : () => _showCreatePromotionDialog(context),
                            icon: const Icon(Icons.local_offer_outlined),
                            label: const Text('Nueva promoción'),
                          ),
                          OutlinedButton.icon(
                            onPressed: state.saving
                                ? null
                                : () => _showCreateCouponDialog(context),
                            icon: const Icon(Icons.confirmation_number_outlined),
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
                              return ListTile(
                                title: Text(item.name),
                                subtitle: Text(
                                  '${_discountLabel(item.discountType, item.discountValue)}'
                                  ' · Min compra ${currency.format(item.minPurchase)}'
                                  '${item.endDate == null ? '' : ' · Hasta ${dateFormat.format(item.endDate!)}'}',
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
                                  '${_discountLabel(item.discountType, item.discountValue)}'
                                  ' · $usageLabel'
                                  '${item.validUntil == null ? '' : ' · Hasta ${dateFormat.format(item.validUntil!)}'}',
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
                                  'Inicial ${currency.format(item.initialBalance)}'
                                  ' · Disponible ${currency.format(item.currentBalance)}'
                                  '${item.expiresAt == null ? '' : ' · Expira ${dateFormat.format(item.expiresAt!)}'}',
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

  Future<void> _showCreatePromotionDialog(BuildContext context) async {
    final nameCtrl = TextEditingController();
    final descriptionCtrl = TextEditingController();
    final valueCtrl = TextEditingController(text: '10');
    final minPurchaseCtrl = TextEditingController(text: '0');
    String discountType = 'percentage';
    DateTime startDate = DateTime.now();
    DateTime endDate = DateTime.now().add(const Duration(days: 30));

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Nueva promoción'),
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: nameCtrl,
                      decoration: const InputDecoration(labelText: 'Nombre'),
                    ),
                    TextField(
                      controller: descriptionCtrl,
                      decoration: const InputDecoration(labelText: 'Descripción'),
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
                        DropdownMenuItem(value: 'fixed', child: Text('Monto fijo')),
                        DropdownMenuItem(value: 'bogo', child: Text('BOGO')),
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
                      decoration: const InputDecoration(labelText: 'Compra mínima'),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () async {
                              final picked = await showDatePicker(
                                context: dialogContext,
                                initialDate: startDate,
                                firstDate: DateTime.now().subtract(
                                  const Duration(days: 365),
                                ),
                                lastDate: DateTime.now().add(
                                  const Duration(days: 365),
                                ),
                              );
                              if (picked == null) return;
                              setDialogState(() {
                                startDate = picked;
                              });
                            },
                            child: Text(
                              'Inicio ${DateFormat('dd/MM/yyyy').format(startDate)}',
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () async {
                              final picked = await showDatePicker(
                                context: dialogContext,
                                initialDate: endDate,
                                firstDate: startDate,
                                lastDate: DateTime.now().add(
                                  const Duration(days: 730),
                                ),
                              );
                              if (picked == null) return;
                              setDialogState(() {
                                endDate = picked;
                              });
                            },
                            child: Text(
                              'Fin ${DateFormat('dd/MM/yyyy').format(endDate)}',
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
                    final name = nameCtrl.text.trim();
                    if (name.isEmpty) return;
                    await ref.read(promosViewModelProvider).createPromotion(
                      name: name,
                      description: descriptionCtrl.text.trim(),
                      discountType: discountType,
                      discountValue: double.tryParse(valueCtrl.text.trim()) ?? 0,
                      minPurchase:
                          double.tryParse(minPurchaseCtrl.text.trim()) ?? 0,
                      startDate: startDate,
                      endDate: endDate,
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
                        DropdownMenuItem(value: 'fixed', child: Text('Monto fijo')),
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
                      decoration: const InputDecoration(labelText: 'Compra mínima'),
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
                    await ref.read(promosViewModelProvider).createCoupon(
                      code: code,
                      discountType: discountType,
                      discountValue: double.tryParse(valueCtrl.text.trim()) ?? 0,
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
                              expiresAt ?? DateTime.now().add(const Duration(days: 365)),
                          firstDate: DateTime.now(),
                          lastDate: DateTime.now().add(const Duration(days: 1825)),
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
                    await ref.read(promosViewModelProvider).createGiftCard(
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
              fontWeight: FontWeight.w800,
              fontSize: 20,
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
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (child == null)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                emptyMessage,
                style: const TextStyle(color: Color(0xFF64748B)),
              ),
            )
          else
            child!,
        ],
      ),
    );
  }
}
