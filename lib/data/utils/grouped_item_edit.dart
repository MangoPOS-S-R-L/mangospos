import '../models/order_edit.dart';
import '../models/order_item_tax_line.dart';
import '../models/sales_models.dart';
import 'offer_deal_pricing.dart';
import 'order_pricing_utils.dart';

/// Intención completa: una sola entrada en cola y una sola transacción SQL.
class GroupedItemEdit {
  const GroupedItemEdit(this.actions, this.items, this.removedIds);
  final List<Map<String, dynamic>> actions;
  final List<OrderItem> items;
  final List<String> removedIds;
}

List<OrderItem> repriceOfferGroups(List<OrderItem> items) {
  final result = [...items];
  final groups = <String, List<int>>{};
  for (var i = 0; i < result.length; i++) {
    final item = result[i];
    final rule = OfferDealRule.fromNotes(item.notes);
    if (!isOfferDealItem(item) ||
        rule == null ||
        item.status == 'paid' ||
        item.status == 'void' ||
        (item.notes ?? '').contains('[CORTESIA:')) {
      continue;
    }
    final marker = RegExp(r'\[DEAL:[^\]]*\]').firstMatch(item.notes!)!.group(0);
    final key =
        '${item.checkId}|${item.productId}|$marker|${rule.marker}|${item.unitPrice}';
    groups.putIfAbsent(key, () => []).add(i);
  }
  for (final indices in groups.values) {
    // El servidor usa el mismo orden. Las rondas conservan su identidad.
    indices.sort((a, b) {
      final c = result[a].createdAt.compareTo(result[b].createdAt);
      return c != 0 ? c : result[a].id.compareTo(result[b].id);
    });
    final rule = OfferDealRule.fromNotes(result[indices.first].notes)!;
    var units = 0.0;
    var previousBenefit = 0.0;
    for (var position = 0; position < indices.length; position++) {
      final index = indices[position];
      final item = result[index];
      result[index] = item.copyWith(discounts: 0);
      units += item.quantity;
      var budget = rule.discountFor(units) - previousBenefit;
      previousBenefit += budget;
      // Cada paquete completo libera su beneficio entero. Se asigna desde
      // su última unidad hacia atrás, sin descuentos negativos ni > bruto.
      for (var p = position; p >= 0 && budget > 0.004; p--) {
        final ix = indices[p];
        final row = result[ix];
        final room = (row.subtotal + row.tax - row.discounts).clamp(
          0,
          double.infinity,
        );
        final amount = budget.clamp(0, room).toDouble();
        result[ix] = row.copyWith(
          discounts: double.parse((row.discounts + amount).toStringAsFixed(2)),
        );
        budget -= amount;
      }
    }
  }
  return result
      .map((i) => i.copyWith(total: summarizeOrderPricing(null, [i]).total))
      .toList();
}

GroupedItemEdit planGroupedItemEdit({
  required List<OrderItem> rows,
  required OrderItem edited,
  required String Function() newId,
  String? reductionReason,
}) {
  final actions = <Map<String, dynamic>>[];
  final result = <OrderItem>[];
  final removed = <String>[];
  var remaining = edited.quantity;
  for (var index = 0; index < rows.length; index++) {
    final originalRow = rows[index];
    final row = recoverLegacyOfferRule(originalRow);
    final qty = index == rows.length - 1
        ? remaining
        : remaining.clamp(0, row.quantity).toDouble();
    remaining = (remaining - qty).clamp(0, double.infinity).toDouble();
    final sent = !const {'draft', 'open'}.contains(row.status);
    final keepQty = sent && qty > row.quantity ? row.quantity : qty;
    final notes = preserveOfferRule(
      [
        if (edited.notes?.isNotEmpty == true) edited.notes!,
        if (reductionReason != null && keepQty < row.quantity)
          '[REDUCCION:$reductionReason]',
      ].join('\n'),
      row,
    );
    if (keepQty <= 0) {
      removed.add(row.id);
      actions.add({
        'kind': 'delete',
        'item_id': row.id,
        ...OrderEditBase.ofItem(originalRow).toAction(),
      });
    } else {
      if (isOfferDealItem(row) &&
          OfferDealRule.fromNotes(row.notes) == null &&
          !(row.notes ?? '').contains('[CORTESIA:') &&
          (qty - row.quantity).abs() > 0.0001) {
        throw const OfferRuleUnavailable();
      }
      final ratio = keepQty / row.quantity;
      final managed =
          isOfferDealItem(row) && OfferDealRule.fromNotes(row.notes) != null;
      final groupGross = rows.fold<double>(0, (s, i) => s + i.subtotal + i.tax);
      final preserveLegacyRound =
          isOfferDealItem(row) &&
          !managed &&
          keepQty == row.quantity &&
          edited.quantity != rows.fold<double>(0, (s, i) => s + i.quantity) &&
          !(edited.notes ?? '').contains('[CORTESIA:');
      final discount = managed
          ? discountAtQuantity(row, keepQty)
          : preserveLegacyRound
          ? row.discounts
          : (groupGross > 0
                ? edited.discounts * (row.subtotal + row.tax) / groupGross
                : 0.0);
      final next = row.copyWith(
        quantity: keepQty,
        subtotal: row.subtotal * ratio,
        tax: row.tax * ratio,
        discounts: discount,
        productName: edited.productName,
        isTakeout: edited.isTakeout,
        notes: notes ?? '',
        taxLines: row.taxLines
            .map(
              (t) => OrderItemTaxLine(
                id: t.id,
                orderItemId: t.orderItemId,
                taxId: t.taxId,
                taxName: t.taxName,
                taxRate: t.taxRate,
                amount: t.amount * ratio,
                createdAt: t.createdAt,
              ),
            )
            .toList(),
      );
      result.add(next);
      actions.add({
        'kind': 'details',
        'item_id': row.id,
        ...OrderEditBase.ofItem(originalRow).toAction(),
        'args': {
          'qty': keepQty,
          'discounts': discount,
          'product_name': edited.productName,
          'is_takeout': edited.isTakeout,
          'notes': notes,
        },
      });
      if (qty > keepQty) {
        final extra = qty - keepQty;
        final added = row.copyWith(
          id: newId(),
          quantity: extra,
          status: 'draft',
          version: 1,
          subtotal: row.subtotal / row.quantity * extra,
          tax: row.tax / row.quantity * extra,
          discounts: managed ? discountAtQuantity(row, extra) : 0,
          notes: preserveOfferRule(edited.notes, row) ?? '',
          isTakeout: edited.isTakeout,
          createdAt: DateTime.now(),
          taxLines: row.taxLines
              .map(
                (t) => OrderItemTaxLine(
                  id: t.id,
                  orderItemId: t.orderItemId,
                  taxId: t.taxId,
                  taxName: t.taxName,
                  taxRate: t.taxRate,
                  amount: t.amount / row.quantity * extra,
                  createdAt: t.createdAt,
                ),
              )
              .toList(),
        );
        result.add(added);
        actions.add({
          'kind': 'add',
          'item_id': added.id,
          'source_id': row.id,
          'args': {
            'qty': extra,
            'notes': added.notes,
            'is_takeout': added.isTakeout,
          },
        });
      }
    }
  }
  if (!rows.any(isOfferDealItem) ||
      (edited.notes ?? '').contains('[CORTESIA:')) {
    final gross = result.fold<double>(0, (s, i) => s + i.subtotal + i.tax);
    final discount = edited.discounts.clamp(0, gross).toDouble();
    var budget = double.parse(discount.toStringAsFixed(2));
    for (var i = 0; i < result.length; i++) {
      final item = result[i];
      final amount = gross <= 0
          ? 0.0
          : ((discount * (item.subtotal + item.tax) / gross) * 100 + 0.0000001)
                    .floor() /
                100.0;
      result[i] = item.copyWith(discounts: amount);
      budget -= amount;
    }
    for (var i = result.length - 1; i >= 0 && budget > 0.004; i--) {
      final item = result[i];
      final room = (item.subtotal + item.tax - item.discounts).clamp(
        0,
        double.infinity,
      );
      final amount = budget.clamp(0, room).toDouble();
      result[i] = item.copyWith(
        discounts: double.parse((item.discounts + amount).toStringAsFixed(2)),
      );
      budget -= amount;
    }
    for (final action in actions) {
      if (action['kind'] == 'delete') continue;
      final item = result.firstWhere((i) => i.id == action['item_id']);
      (action['args'] as Map<String, dynamic>)['discounts'] = item.discounts;
    }
  }
  return GroupedItemEdit(actions, repriceOfferGroups(result), removed);
}
