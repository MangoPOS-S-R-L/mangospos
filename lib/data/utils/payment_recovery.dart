import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/sales_models.dart';

/// Older RPCs return the last payment when the container is already closed.
/// That row is not necessarily the split being replayed.
Future<Payment> validatePaymentResponse(
  SupabaseClient client,
  Map<String, dynamic> row, {
  required String orderId,
  required String? checkId,
  required String paymentMethodId,
  required int splitSequence,
  required double amount,
  required double changeAmount,
}) async {
  final payment = Payment.fromMap(row);
  final methodMatches = paymentMethodId.contains('-')
      ? payment.paymentMethodId == paymentMethodId
      : payment.paymentMethodCode == null ||
            payment.paymentMethodCode == paymentMethodId;
  if (payment.id.isNotEmpty &&
      payment.orderId == orderId &&
      payment.checkId == checkId &&
      payment.status == 'completed' &&
      (row['split_sequence'] ?? 0) == splitSequence &&
      methodMatches &&
      (payment.amount - amount).abs() < 0.001 &&
      (payment.changeAmount - changeAmount).abs() < 0.001) {
    return payment;
  }
  final recovered = await recoverCompletedPayment(
    client,
    orderId: orderId,
    checkId: checkId,
    paymentMethodId: paymentMethodId,
    splitSequence: splitSequence,
    amount: amount,
    changeAmount: changeAmount,
  );
  if (recovered != null) return recovered;
  throw StateError(
    'PAYMENT_RESPONSE_MISMATCH: el servidor no confirmo '
    'el abono solicitado. Verifica el historial antes de volver a cobrar.',
  );
}

/// Recover only the requested split, never another payment for the same amount.
Future<Payment?> recoverCompletedPayment(
  SupabaseClient client, {
  required String orderId,
  required String? checkId,
  required String paymentMethodId,
  required int splitSequence,
  required double amount,
  required double changeAmount,
}) async {
  try {
    var query = client
        .from('payments')
        .select('*, payment_methods!inner(code)')
        .eq('order_id', orderId)
        .eq('status', 'completed')
        .eq('split_sequence', splitSequence);
    query = checkId == null
        ? query.isFilter('check_id', null)
        : query.eq('check_id', checkId);
    final isUuid = RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
    ).hasMatch(paymentMethodId);
    query = isUuid
        ? query.eq('payment_method_id', paymentMethodId)
        : query.eq('payment_methods.code', paymentMethodId);
    final rows = await query.limit(2).timeout(const Duration(seconds: 3));
    if (rows.length != 1) return null;
    final row = rows.single;
    final method = row['payment_methods'] as Map?;
    final payment = Payment.fromMap(row);
    if (payment.id.isEmpty ||
        !payment.amount.isFinite ||
        !payment.changeAmount.isFinite ||
        payment.orderId != orderId ||
        payment.checkId != checkId ||
        payment.status != 'completed' ||
        (row['split_sequence'] as num?)?.toInt() != splitSequence ||
        (payment.paymentMethodId != paymentMethodId &&
            method?['code'] != paymentMethodId) ||
        (payment.amount - amount).abs() > 0.001 ||
        (payment.changeAmount - changeAmount).abs() > 0.001) {
      return null;
    }
    return payment.copyWith(paymentMethodCode: method?['code'] as String?);
  } catch (_) {
    // An unavailable recovery query is not proof that the payment was cancelled.
    return null;
  }
}
