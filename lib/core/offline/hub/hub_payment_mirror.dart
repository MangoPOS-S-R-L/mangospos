import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../offline_pos_service.dart';
import 'hub_client.dart';
import 'hub_config.dart';
import 'hub_mode_controller.dart';

Map<String, dynamic> confirmedPaymentHubOp({
  required String orderId,
  required String paymentId,
  String? checkId,
}) {
  final isCheckPayment = checkId != null && checkId.isNotEmpty;
  return {
    'type': 'process_payment',
    'order_id': orderId,
    if (isCheckPayment) 'check_id': checkId,
    'close_order': !isCheckPayment,
    'close_check': isCheckPayment,
    'op_id': 'confirmed-payment-$paymentId',
    'hub_applied': true,
  };
}

/// A payment already committed by Supabase must also close its LAN projection.
/// This is a mirror only: the Hub must never upload it as a second payment.
Future<void> mirrorConfirmedPaymentToHub({
  required Ref ref,
  required String businessId,
  required String orderId,
  required String paymentId,
  String? checkId,
}) async {
  if (businessId.isEmpty || orderId.isEmpty || paymentId.isEmpty) return;
  try {
    if (!ref.exists(hubModeProvider)) return;
    final mode = ref.read(hubModeProvider);
    if (mode != TerminalMode.hubHost && mode != TerminalMode.hubClient) return;
    final op = confirmedPaymentHubOp(
      orderId: orderId,
      paymentId: paymentId,
      checkId: checkId,
    );
    if (mode == TerminalMode.hubHost) {
      await OfflinePosService().publishHostOp(businessId, op);
    } else {
      final url = ref.read(hubModeProvider.notifier).reachableHubUrl;
      if (url != null) {
        await HubClient().postOp(url, {...op, 'business_id': businessId});
      }
    }
  } catch (error) {
    debugPrint('[HubPaymentMirror] no se pudo reflejar el pago: $error');
  }
}
