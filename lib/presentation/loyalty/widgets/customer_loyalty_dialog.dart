import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/multimesero/operator_permissions.dart';
import '../../../core/utils/app_toast.dart';
import '../../../data/models/loyalty_models.dart';
import '../../../data/repositories/loyalty_repository.dart';
import '../viewmodel/loyalty_providers.dart';
import 'order_loyalty_strip.dart' show LoyaltyStampDots;

const _green = Color(0xFF16A34A);
const _textSecondary = Color(0xFF6B7280);

/// Ficha de sellos de un cliente: cómo va en cada tarjeta, de dónde salen los
/// sellos y el ajuste manual (para pasar la tarjeta física al sistema).
Future<void> showCustomerLoyaltyDialog(
  BuildContext context, {
  required String customerId,
  required String customerName,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _CustomerLoyaltyDialog(
      customerId: customerId,
      customerName: customerName,
    ),
  );
}

class _CustomerLoyaltyDialog extends ConsumerWidget {
  const _CustomerLoyaltyDialog({
    required this.customerId,
    required this.customerName,
  });

  final String customerId;
  final String customerName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cardsAsync = ref.watch(customerLoyaltyCardsProvider(customerId));
    final canAdjust =
        operatorIsOwner(ref) ||
        operatorHasPermission(ref, 'clientes.crear_editar');

    return AlertDialog(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.white,
      title: Text('Tarjetas de sellos · $customerName'),
      content: SizedBox(
        width: 480,
        child: cardsAsync.when(
          loading: () => const SizedBox(
            height: 120,
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (error, _) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(LoyaltyRepository.mapError(error).message),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () =>
                    ref.invalidate(customerLoyaltyCardsProvider(customerId)),
                child: const Text('Reintentar'),
              ),
            ],
          ),
          data: (cards) {
            if (cards.isEmpty) {
              return const Text(
                'El negocio no tiene tarjetas de sellos activas. Créalas en '
                'Ajustes → Fidelización → Tarjeta de Fidelidad.',
              );
            }
            return SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final card in cards)
                    _CardSummary(
                      card: card,
                      customerId: customerId,
                      canAdjust: canAdjust,
                    ),
                ],
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cerrar'),
        ),
      ],
    );
  }
}

class _CardSummary extends ConsumerStatefulWidget {
  const _CardSummary({
    required this.card,
    required this.customerId,
    required this.canAdjust,
  });

  final LoyaltyCard card;
  final String customerId;
  final bool canAdjust;

  @override
  ConsumerState<_CardSummary> createState() => _CardSummaryState();
}

class _CardSummaryState extends ConsumerState<_CardSummary> {
  late Future<List<LoyaltyAdjustment>> _adjustments;

  @override
  void initState() {
    super.initState();
    _loadAdjustments();
  }

  void _loadAdjustments() {
    _adjustments = ref
        .read(loyaltyRepositoryProvider)
        .getAdjustments(
          customerId: widget.customerId,
          programId: widget.card.programId,
        );
  }

  Future<void> _adjust() async {
    final done = await showDialog<bool>(
      context: context,
      builder: (_) => _AdjustStampsDialog(
        card: widget.card,
        customerId: widget.customerId,
      ),
    );
    if (done != true || !mounted) return;
    setState(_loadAdjustments);
    ref.invalidate(customerLoyaltyCardsProvider(widget.customerId));
  }

  @override
  Widget build(BuildContext context) {
    final card = widget.card;
    final dateFmt = DateFormat('dd/MM/yyyy');
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  card.name,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (card.availableRewards > 0)
                Text(
                  '${card.availableRewards} gratis',
                  style: const TextStyle(
                    color: _green,
                    fontWeight: FontWeight.w700,
                  ),
                )
              else
                Text(
                  '${card.progress}/${card.stampsRequired}',
                  style: const TextStyle(
                    color: _textSecondary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          LoyaltyStampDots(
            filled: card.progress,
            total: card.stampsRequired,
            rewardReady: card.availableRewards > 0,
            size: 14,
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 14,
            runSpacing: 4,
            children: [
              _Fact(card.perVisit ? 'Compras' : 'Unidades', '${card.earned}'),
              _Fact('Ajustes', _signed(card.adjustments)),
              _Fact('Canjeados', '${card.redeemed}'),
              if (card.reserved > 0) _Fact('Apartados', '${card.reserved}'),
              _Fact('Disponibles', '${card.balance}'),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${card.ruleLabel}. Solo cuentan ventas cobradas con este '
            'cliente asignado'
            '${card.perVisit ? ' (una marca por compra, lleve 1 o varias)' : ''}.',
            style: const TextStyle(fontSize: 12, color: _textSecondary),
          ),
          FutureBuilder<List<LoyaltyAdjustment>>(
            future: _adjustments,
            builder: (context, snapshot) {
              final rows = snapshot.data ?? const <LoyaltyAdjustment>[];
              if (rows.isEmpty) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Ajustes manuales',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    for (final row in rows)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text(
                          '${dateFmt.format(row.createdAt)}  '
                          '${_signed(row.stamps)}  ·  ${row.reason}',
                          style: const TextStyle(
                            fontSize: 12,
                            color: _textSecondary,
                          ),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
          if (widget.canAdjust)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: _adjust,
                icon: const Icon(Icons.tune_rounded, size: 18),
                label: const Text('Ajustar sellos'),
              ),
            ),
        ],
      ),
    );
  }
}

String _signed(int value) => value > 0 ? '+$value' : '$value';

class _Fact extends StatelessWidget {
  const _Fact(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: '$label ',
            style: const TextStyle(fontSize: 12.5, color: _textSecondary),
          ),
          TextSpan(
            text: value,
            style: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _AdjustStampsDialog extends ConsumerStatefulWidget {
  const _AdjustStampsDialog({required this.card, required this.customerId});

  final LoyaltyCard card;
  final String customerId;

  @override
  ConsumerState<_AdjustStampsDialog> createState() =>
      _AdjustStampsDialogState();
}

class _AdjustStampsDialogState extends ConsumerState<_AdjustStampsDialog> {
  final _stampsCtrl = TextEditingController();
  final _reasonCtrl = TextEditingController(
    text: 'Tarjeta física del cliente',
  );
  bool _add = true;
  bool _saving = false;

  @override
  void dispose() {
    _stampsCtrl.dispose();
    _reasonCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final amount = int.tryParse(_stampsCtrl.text.trim()) ?? 0;
    if (amount <= 0) {
      AppToast.error(context, 'Escribe cuántos sellos.');
      return;
    }
    if (_reasonCtrl.text.trim().length < 3) {
      AppToast.error(context, 'Escribe el motivo del ajuste.');
      return;
    }
    setState(() => _saving = true);
    try {
      await ref
          .read(loyaltyRepositoryProvider)
          .adjustStamps(
            programId: widget.card.programId,
            customerId: widget.customerId,
            stamps: _add ? amount : -amount,
            reason: _reasonCtrl.text,
          );
      if (!mounted) return;
      AppToast.success(
        context,
        _add ? 'Se sumaron $amount sellos.' : 'Se quitaron $amount sellos.',
      );
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      AppToast.error(context, LoyaltyRepository.mapError(e).message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.white,
      title: Text('Ajustar sellos · ${widget.card.name}'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Úsalo para pasar las marcas de la tarjeta física o corregir un '
              'error. Queda registrado quién lo hizo y por qué.',
              style: TextStyle(fontSize: 12.5, color: _textSecondary),
            ),
            const SizedBox(height: 12),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(
                  value: true,
                  label: Text('Sumar'),
                  icon: Icon(Icons.add),
                ),
                ButtonSegment(
                  value: false,
                  label: Text('Quitar'),
                  icon: Icon(Icons.remove),
                ),
              ],
              selected: {_add},
              onSelectionChanged: (value) =>
                  setState(() => _add = value.first),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _stampsCtrl,
              autofocus: true,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                labelText: 'Sellos',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _reasonCtrl,
              maxLength: 200,
              decoration: const InputDecoration(
                labelText: 'Motivo',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Guardar'),
        ),
      ],
    );
  }
}
