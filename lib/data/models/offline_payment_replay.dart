/// T07 (20261010_0008): resultado de subir un cobro hecho sin red con
/// fn_replay_offline_payment / fn_resolve_offline_payment.
class OfflinePaymentReplayResult {
  const OfflinePaymentReplayResult({
    required this.status,
    this.reason,
    this.detail,
    this.paymentId,
    this.money,
    this.replayed = false,
  });

  factory OfflinePaymentReplayResult.fromMap(Map<String, dynamic> map) =>
      OfflinePaymentReplayResult(
        status: map['status']?.toString() ?? 'needs_resolution',
        reason: map['reason']?.toString(),
        detail: map['detail'] is Map
            ? Map<String, dynamic>.from(map['detail'] as Map)
            : null,
        paymentId: map['payment_id']?.toString(),
        money: map['money'] is Map
            ? Map<String, dynamic>.from(map['money'] as Map)
            : null,
        replayed: map['replayed'] == true,
      );

  /// applied | needs_resolution | resolved | acknowledged.
  final String status;
  final String? reason;
  final Map<String, dynamic>? detail;
  final String? paymentId;

  /// Foto de conciliación de la cuenta (saldo, subcuentas, comprobante).
  final Map<String, dynamic>? money;
  final bool replayed;

  bool get needsResolution => status == 'needs_resolution';

  /// Ya no queda nada por hacer con este cobro en la cola.
  bool get settled => !needsResolution;

  /// Lo que no cuadra en la cuenta después de aplicarlo.
  List<String> get flags => [
    if (money?['flags'] is List)
      for (final flag in money!['flags'] as List) flag.toString(),
  ];
}

/// Las decisiones posibles sobre un cobro «por resolver» y sus textos.
abstract final class OfflinePaymentResolution {
  static const postToOpenSession = 'post_to_open_session';
  static const applyAsPartial = 'apply_as_partial';
  static const applyAnyway = 'apply_anyway';
  static const applyToReviewOrder = 'apply_to_review_order';
  static const acknowledge = 'acknowledge';

  /// Las decisiones que tienen sentido para cada motivo. Dejar constancia sin
  /// cobrar solo cuando el dinero no puede aplicarse a esta cuenta. Con una
  /// cuenta en revisión que nació de esa cuenta (20261010_0020, [detail]
  /// `review_order_id`), también aplicarlo ahí.
  static List<String> allowedFor(
    String? reason, [
    Map<String, dynamic>? detail,
  ]) {
    final hasReviewOrder =
        (detail?['review_order_id']?.toString() ?? '').isNotEmpty;
    return switch (reason) {
      'cash_session_closed' ||
      'cash_session_unknown' ||
      'cash_session_missing' => const [postToOpenSession],
      'order_changed' => const [applyAsPartial],
      'paid_at_in_future' => const [applyAnyway],
      'order_already_paid' || 'order_voided' =>
        hasReviewOrder
            ? const [applyToReviewOrder, acknowledge]
            : const [acknowledge],
      'payment_slot_taken' => const [acknowledge],
      _ => const [],
    };
  }

  static String label(String resolution) => switch (resolution) {
    postToOpenSession => 'Registrar en la caja abierta de este equipo',
    applyAsPartial => 'Aplicarlo como abono (la cuenta queda con saldo)',
    applyAnyway => 'Aplicarlo con la fecha que trae',
    applyToReviewOrder =>
      'Aplicarlo a la cuenta en revisión de esa mesa (los productos que '
          'llegaron tarde)',
    acknowledge => 'Dejar constancia sin aplicarlo',
    _ => resolution,
  };

  /// Por qué el cobro no se aplicó solo, en palabras del cajero.
  static String reasonMessage(String? reason) => switch (reason) {
    'cash_session_closed' =>
      'La caja de este cobro ya se cerró. No se movió solo a otra caja: '
          'decide dónde registrarlo.',
    'cash_session_unknown' =>
      'La caja de este cobro no existe en el servidor o es de otro negocio.',
    'cash_session_missing' =>
      'Este cobro se hizo sin caja abierta. Decide en qué caja registrarlo.',
    'paid_at_in_future' =>
      'La fecha del cobro está adelantada respecto al servidor (reloj del '
          'equipo). Revisa la hora del equipo.',
    'order_changed' =>
      'La cuenta cambió después del cobro (entraron productos): el monto ya '
          'no la cubre.',
    'order_already_paid' =>
      'La cuenta ya la cobró otro equipo. Este cobro no se aplicó: revisa si '
          'el cliente pagó dos veces.',
    'order_voided' =>
      'La cuenta se anuló o se liberó en el servidor (sin cobros). Este cobro '
          'no se aplicó.',
    'payment_slot_taken' =>
      'Otro equipo registró un cobro distinto con el mismo método en esta '
          'cuenta. Este no se aplicó: revisa los cobros de la cuenta.',
    _ => 'Este cobro necesita una decisión antes de registrarse.',
  };
}
