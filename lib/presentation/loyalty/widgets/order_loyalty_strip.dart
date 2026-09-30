import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/currency/business_currency_provider.dart';
import '../../../core/utils/app_toast.dart';
import '../../../data/models/loyalty_models.dart';
import '../../../data/models/sales_models.dart';
import '../../../data/repositories/loyalty_repository.dart';
import '../../../data/utils/loyalty_reward_utils.dart';
import '../../sales/state/sales_state.dart';
import '../../sales/viewmodel/sales_viewmodel.dart';
import '../viewmodel/loyalty_providers.dart';

const _green = Color(0xFF16A34A);
const _greenSoft = Color(0xFFE8F8EE);
const _border = Color(0xFFE5E7EB);
const _textPrimary = Color(0xFF111827);
const _textSecondary = Color(0xFF6B7280);

/// Cliente EFECTIVO de la cuenta que se está viendo: el de la subcuenta
/// seleccionada o, si no tiene, el de la mesa. Misma regla que el cobro.
String? effectiveLoyaltyCustomerId(CurrentOrderState state) {
  final selected = state.selectedCheckId;
  if (selected != null) {
    for (final check in state.checks) {
      if (check.id == selected) {
        final own = check.customerId?.trim();
        if (own != null && own.isNotEmpty) return own;
      }
    }
  }
  final general = state.customerId?.trim();
  return (general != null && general.isNotEmpty) ? general : null;
}

/// Cliente efectivo de UNA línea (subcuenta > mesa), igual que el servidor.
String? _lineCustomerId(CurrentOrderState state, OrderItem item) {
  final checkId = item.checkId;
  if (checkId != null) {
    for (final check in state.checks) {
      if (check.id == checkId) {
        final own = check.customerId?.trim();
        if (own != null && own.isNotEmpty) return own;
      }
    }
  }
  return state.customerId;
}

LoyaltyRewardLine _toRewardLine(CurrentOrderState state, OrderItem item) {
  return LoyaltyRewardLine(
    id: item.id,
    productId: item.productId,
    productName: item.productName,
    quantity: item.quantity,
    subtotal: item.subtotal,
    tax: item.tax,
    discounts: item.discounts,
    status: item.status,
    customerId: _lineCustomerId(state, item),
    notes: item.notes,
  );
}

/// Franja del carrito con la tarjeta de sellos del cliente asignado: marcas,
/// premios disponibles y el botón para canjear. No ocupa lugar si no hay
/// cliente o el negocio no tiene tarjetas activas.
class OrderLoyaltyStrip extends ConsumerWidget {
  const OrderLoyaltyStrip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final orderState = ref.watch(currentOrderProvider);
    final customerId = effectiveLoyaltyCustomerId(orderState);
    if (customerId == null || orderState.order == null) {
      return const SizedBox.shrink();
    }
    final cardsAsync = ref.watch(customerLoyaltyCardsProvider(customerId));
    return cardsAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (error, _) {
        final mapped = LoyaltyRepository.mapError(error);
        // Sin la migración el negocio simplemente no usa tarjetas todavía:
        // no ensuciar el carrito con un error.
        if (mapped.code == 'MIGRATION') return const SizedBox.shrink();
        return _StripShell(
          child: Row(
            children: [
              const Icon(Icons.card_membership_rounded,
                  size: 18, color: _textSecondary),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'No se pudo cargar la tarjeta de sellos.',
                  style: TextStyle(fontSize: 12.5, color: _textSecondary),
                ),
              ),
              TextButton(
                onPressed: () =>
                    ref.invalidate(customerLoyaltyCardsProvider(customerId)),
                child: const Text('Reintentar'),
              ),
            ],
          ),
        );
      },
      data: (cards) {
        if (cards.isEmpty) return const SizedBox.shrink();
        return _StripShell(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < cards.length; i++) ...[
                if (i > 0) const SizedBox(height: 6),
                _CardRow(
                  card: cards[i],
                  onTap: () => showLoyaltyRedeemDialog(
                    context,
                    customerId: customerId,
                    card: cards[i],
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _StripShell extends StatelessWidget {
  const _StripShell({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: const BoxDecoration(
        color: Color(0xFFF9FAFB),
        border: Border(bottom: BorderSide(color: _border)),
      ),
      child: child,
    );
  }
}

class _CardRow extends StatelessWidget {
  const _CardRow({required this.card, required this.onTap});

  final LoyaltyCard card;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final hasReward = card.availableRewards > 0;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            Icon(
              Icons.card_membership_rounded,
              size: 18,
              color: hasReward ? _green : _textSecondary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    card.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: _textPrimary,
                    ),
                  ),
                  const SizedBox(height: 3),
                  LoyaltyStampDots(
                    filled: card.progress,
                    total: card.stampsRequired,
                    rewardReady: hasReward,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (hasReward)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: _greenSoft,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: const Color(0xFFBBE5C8)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.card_giftcard_rounded,
                        size: 15, color: _green),
                    const SizedBox(width: 5),
                    Text(
                      card.availableRewards == 1
                          ? '1 gratis · Canjear'
                          : '${card.availableRewards} gratis · Canjear',
                      style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: _green,
                      ),
                    ),
                  ],
                ),
              )
            else
              Text(
                '${card.progress}/${card.stampsRequired}',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: _textSecondary,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Las marcas de la tarjeta, como en el cartón: [total] círculos y al final
/// el del premio (el corazón del cartón), que se enciende cuando ya toca la
/// gratis. Con muchas marcas (más de 20) se dibuja una barra.
class LoyaltyStampDots extends StatelessWidget {
  const LoyaltyStampDots({
    super.key,
    required this.filled,
    required this.total,
    required this.rewardReady,
    this.size = 10,
  });

  final int filled;
  final int total;
  final bool rewardReady;
  final double size;

  @override
  Widget build(BuildContext context) {
    final safeTotal = total < 1 ? 1 : total;
    final safeFilled = rewardReady ? safeTotal : filled.clamp(0, safeTotal);
    final reward = Container(
      width: size * 1.5,
      height: size * 1.5,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: rewardReady ? _green : Colors.white,
        border: Border.all(
          color: rewardReady ? _green : const Color(0xFFCBD5E1),
        ),
      ),
      child: Icon(
        Icons.card_giftcard_rounded,
        size: size,
        color: rewardReady ? Colors.white : const Color(0xFF94A3B8),
      ),
    );
    if (safeTotal > 20) {
      return Row(
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: safeFilled / safeTotal,
                minHeight: size * 0.7,
                backgroundColor: _border,
                color: _green,
              ),
            ),
          ),
          const SizedBox(width: 6),
          reward,
        ],
      );
    }
    return Wrap(
      spacing: 3,
      runSpacing: 3,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (var i = 0; i < safeTotal; i++)
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: i < safeFilled ? _green : Colors.white,
              border: Border.all(
                color: i < safeFilled ? _green : const Color(0xFFCBD5E1),
              ),
            ),
          ),
        reward,
      ],
    );
  }
}

/// Canjear o quitar el premio de [card] en la cuenta abierta.
Future<void> showLoyaltyRedeemDialog(
  BuildContext context, {
  required String customerId,
  required LoyaltyCard card,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _LoyaltyRedeemDialog(customerId: customerId, card: card),
  );
}

class _LoyaltyRedeemDialog extends ConsumerStatefulWidget {
  const _LoyaltyRedeemDialog({required this.customerId, required this.card});

  final String customerId;
  final LoyaltyCard card;

  @override
  ConsumerState<_LoyaltyRedeemDialog> createState() =>
      _LoyaltyRedeemDialogState();
}

class _LoyaltyRedeemDialogState extends ConsumerState<_LoyaltyRedeemDialog> {
  String? _selectedItemId;
  int _units = 1;
  bool _busy = false;

  LoyaltyCard get _card => widget.card;

  Future<void> _afterChange() async {
    ref.invalidate(customerLoyaltyCardsProvider(widget.customerId));
    await ref.read(currentOrderProvider.notifier).reloadOrderNow();
  }

  Future<void> _redeem(LoyaltyRewardLine line) async {
    setState(() => _busy = true);
    try {
      await ref
          .read(loyaltyRepositoryProvider)
          .redeemReward(
            programId: _card.programId,
            customerId: widget.customerId,
            orderItemId: line.id,
            units: _units,
          );
      await _afterChange();
      if (!mounted) return;
      AppToast.success(
        context,
        _units == 1
            ? '${line.productName}: 1 gratis por ${_card.name}.'
            : '${line.productName}: $_units gratis por ${_card.name}.',
      );
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      AppToast.error(context, LoyaltyRepository.mapError(e).message);
    }
  }

  Future<void> _cancel(OrderItem item) async {
    setState(() => _busy = true);
    try {
      await ref.read(loyaltyRepositoryProvider).cancelReward(item.id);
      await _afterChange();
      if (!mounted) return;
      AppToast.success(
        context,
        'Premio quitado de ${item.productName}. Los sellos volvieron a la '
        'tarjeta.',
      );
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      AppToast.error(context, LoyaltyRepository.mapError(e).message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final orderState = ref.watch(currentOrderProvider);
    final currency = currentBusinessCurrencyOrFallback(ref);
    final offline =
        orderState.isOfflineMode ||
        (orderState.order?.id.startsWith('local-order-') ?? true);

    final eligible = _card.eligibleProductIds;
    final rewardLines = orderState.items
        .where((item) => item.status != 'void')
        .where((item) => hasLoyaltyReward(item.notes))
        .where(
          (item) =>
              item.productId != null && eligible.contains(item.productId),
        )
        .toList(growable: false);
    final candidates = loyaltyRewardCandidates(
      lines: orderState.items
          .map((item) => _toRewardLine(orderState, item))
          .toList(growable: false),
      eligibleProductIds: eligible,
      customerId: widget.customerId,
    );
    final selected = candidates.firstWhere(
      (line) => line.id == _selectedItemId,
      orElse: () => candidates.isNotEmpty
          ? candidates.first
          : const LoyaltyRewardLine(
              id: '',
              productId: null,
              productName: '',
              quantity: 0,
              subtotal: 0,
              tax: 0,
              discounts: 0,
              status: '',
              customerId: null,
            ),
    );
    final hasSelection = selected.id.isNotEmpty;
    final maxUnits = hasSelection
        ? [
            _card.availableRewards,
            selected.quantity.floor(),
            20,
          ].reduce((a, b) => a < b ? a : b)
        : 0;
    if (_units > maxUnits && maxUnits > 0) _units = maxUnits;

    String checkLabel(String? checkId) {
      if (checkId == null || orderState.checks.length < 2) return '';
      for (final check in orderState.checks) {
        if (check.id == checkId) {
          return check.label.isEmpty
              ? ' · C${check.position}'
              : ' · ${check.label}';
        }
      }
      return '';
    }

    String? checkIdOf(String itemId) {
      for (final item in orderState.items) {
        if (item.id == itemId) return item.checkId;
      }
      return null;
    }

    return AlertDialog(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.white,
      title: Row(
        children: [
          const Icon(Icons.card_membership_rounded, color: _green),
          const SizedBox(width: 8),
          Expanded(child: Text(_card.name)),
        ],
      ),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LoyaltyStampDots(
                filled: _card.progress,
                total: _card.stampsRequired,
                rewardReady: _card.availableRewards > 0,
                size: 14,
              ),
              const SizedBox(height: 8),
              Text(
                _card.availableRewards > 0
                    ? 'Tarjeta completa: le toca '
                          '${_card.availableRewards == 1 ? '1 gratis' : '${_card.availableRewards} gratis'}'
                          ' (${_card.ruleLabel.toLowerCase()}).'
                    : 'Lleva ${_card.progress} de ${_card.stampsRequired}. '
                          'Le ${_card.stampsRequired - _card.progress == 1 ? 'falta' : 'faltan'} '
                          '${_card.stampsRequired - _card.progress} '
                          '${_card.perVisit ? (_card.stampsRequired - _card.progress == 1 ? 'compra' : 'compras') : (_card.stampsRequired - _card.progress == 1 ? 'unidad' : 'unidades')}'
                          ' para la gratis.',
                style: const TextStyle(fontSize: 13.5, color: _textPrimary),
              ),
              if (_card.reserved > 0) ...[
                const SizedBox(height: 4),
                Text(
                  '${_card.reserved} marcas apartadas en premios de cuentas '
                  'abiertas (se descuentan al cobrar; vuelven si se quita el '
                  'premio o se anula).',
                  style: const TextStyle(fontSize: 12, color: _textSecondary),
                ),
              ],
              if (rewardLines.isNotEmpty) ...[
                const SizedBox(height: 16),
                const Text(
                  'Premios en esta cuenta',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                for (final item in rewardLines)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(
                      Icons.card_giftcard_rounded,
                      color: _green,
                    ),
                    title: Text(
                      '${loyaltyRewardUnits(item.notes)} × '
                      '${item.productName}${checkLabel(item.checkId)}',
                    ),
                    subtitle: Text(
                      'Gratis: ${currency.formatAmount(item.discounts)}',
                    ),
                    trailing: (item.status == 'paid' || offline)
                        ? null
                        : TextButton(
                            onPressed: _busy ? null : () => _cancel(item),
                            child: const Text('Quitar'),
                          ),
                  ),
              ],
              if (_card.availableRewards > 0) ...[
                const SizedBox(height: 16),
                const Text(
                  '¿Qué producto va gratis?',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                if (offline)
                  const Text(
                    'Canjear necesita conexión con el servidor.',
                    style: TextStyle(fontSize: 13, color: _textSecondary),
                  )
                else if (candidates.isEmpty)
                  const Text(
                    'En la cuenta de este cliente no hay un producto de la '
                    'tarjeta sin descuento. Agrégalo y vuelve a canjear.',
                    style: TextStyle(fontSize: 13, color: _textSecondary),
                  )
                else ...[
                  for (final line in candidates)
                    InkWell(
                      onTap: _busy
                          ? null
                          : () => setState(() => _selectedItemId = line.id),
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          children: [
                            Icon(
                              line.id == selected.id
                                  ? Icons.radio_button_checked
                                  : Icons.radio_button_unchecked,
                              size: 20,
                              color: line.id == selected.id
                                  ? _green
                                  : _textSecondary,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                '${line.quantity % 1 == 0 ? line.quantity.toStringAsFixed(0) : line.quantity.toStringAsFixed(2)}'
                                ' × ${line.productName}'
                                '${checkLabel(checkIdOf(line.id))}',
                                style: const TextStyle(fontSize: 13.5),
                              ),
                            ),
                            Text(
                              '${currency.formatAmount(line.perUnitGross)} c/u',
                              style: const TextStyle(
                                fontSize: 13,
                                color: _textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (maxUnits > 1) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        const Text(
                          'Unidades gratis',
                          style: TextStyle(fontSize: 13),
                        ),
                        const Spacer(),
                        IconButton(
                          onPressed: _busy || _units <= 1
                              ? null
                              : () => setState(() => _units--),
                          icon: const Icon(Icons.remove_circle_outline),
                        ),
                        Text(
                          '$_units',
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        IconButton(
                          onPressed: _busy || _units >= maxUnits
                              ? null
                              : () => setState(() => _units++),
                          icon: const Icon(Icons.add_circle_outline),
                        ),
                      ],
                    ),
                  ],
                ],
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cerrar'),
        ),
        if (_card.availableRewards > 0 && !offline && hasSelection)
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: _green),
            onPressed: _busy ? null : () => _redeem(selected),
            icon: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.card_giftcard_rounded, size: 18),
            label: Text(
              'Dar ${_units == 1 ? '1' : '$_units'} gratis '
              '(${currency.formatAmount(selected.perUnitGross * _units)})',
            ),
          ),
      ],
    );
  }
}
