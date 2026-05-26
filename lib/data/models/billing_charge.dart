// PRD-Azul-Subscriptions §5.1 — Cobro mensual.
//
// Mapea la vista `public.azul_charges_public` (oculta raw_request/response).

enum BillingChargeStatus {
  pending,
  approved,
  declined,
  error,
  voided,
  unknown;

  static BillingChargeStatus fromWire(String? s) {
    switch (s) {
      case 'pending':
        return BillingChargeStatus.pending;
      case 'approved':
        return BillingChargeStatus.approved;
      case 'declined':
        return BillingChargeStatus.declined;
      case 'error':
        return BillingChargeStatus.error;
      case 'voided':
        return BillingChargeStatus.voided;
      default:
        return BillingChargeStatus.unknown;
    }
  }

  String get label {
    switch (this) {
      case BillingChargeStatus.pending:
        return 'Procesando';
      case BillingChargeStatus.approved:
        return 'Pagado';
      case BillingChargeStatus.declined:
        return 'Rechazado';
      case BillingChargeStatus.error:
        return 'Error';
      case BillingChargeStatus.voided:
        return 'Anulado';
      case BillingChargeStatus.unknown:
        return '—';
    }
  }
}

class BillingCharge {
  final String id;
  final String businessId;
  final String membershipId;
  final String orderNumber;
  final DateTime billingPeriodStart;
  final DateTime billingPeriodEnd;
  final int attemptNumber;
  final int amountCents;
  final int itbisCents;
  final String currencyCode;
  final BillingChargeStatus status;
  final String? responseMessage;
  final String? authorizationCode;
  final String? rrn;
  final DateTime attemptedAt;
  final DateTime? completedAt;
  final String? receiptPdfPath;
  final DateTime? receiptEmailedAt;

  const BillingCharge({
    required this.id,
    required this.businessId,
    required this.membershipId,
    required this.orderNumber,
    required this.billingPeriodStart,
    required this.billingPeriodEnd,
    required this.attemptNumber,
    required this.amountCents,
    required this.itbisCents,
    required this.currencyCode,
    required this.status,
    required this.responseMessage,
    required this.authorizationCode,
    required this.rrn,
    required this.attemptedAt,
    required this.completedAt,
    required this.receiptPdfPath,
    required this.receiptEmailedAt,
  });

  String get formattedAmount {
    final totalCents = amountCents + itbisCents;
    final whole = totalCents ~/ 100;
    final cents = totalCents % 100;
    final wholeStr = whole.toString().replaceAllMapped(
      RegExp(r'(\d)(?=(\d{3})+(?!\d))'),
      (m) => '${m[1]},',
    );
    final symbol = currencyCode == 'DOP' ? r'RD$' : currencyCode;
    return '$symbol $wholeStr.${cents.toString().padLeft(2, '0')}';
  }

  factory BillingCharge.fromJson(Map<String, dynamic> json) {
    return BillingCharge(
      id: json['id'] as String,
      businessId: json['business_id'] as String,
      membershipId: json['membership_id'] as String,
      orderNumber: json['order_number'] as String,
      billingPeriodStart: DateTime.parse(json['billing_period_start'] as String),
      billingPeriodEnd: DateTime.parse(json['billing_period_end'] as String),
      attemptNumber: (json['attempt_number'] as num).toInt(),
      amountCents: (json['amount_cents'] as num).toInt(),
      itbisCents: (json['itbis_cents'] as num?)?.toInt() ?? 0,
      currencyCode: (json['currency_code'] as String?) ?? 'DOP',
      status: BillingChargeStatus.fromWire(json['status'] as String?),
      responseMessage: json['response_message'] as String?,
      authorizationCode: json['authorization_code'] as String?,
      rrn: json['rrn'] as String?,
      attemptedAt: DateTime.parse(json['attempted_at'] as String),
      completedAt: json['completed_at'] != null
          ? DateTime.parse(json['completed_at'] as String)
          : null,
      receiptPdfPath: json['receipt_pdf_path'] as String?,
      receiptEmailedAt: json['receipt_emailed_at'] != null
          ? DateTime.parse(json['receipt_emailed_at'] as String)
          : null,
    );
  }
}
