/// Respuesta de `fn_payment_attempt_acquire` (20260929_0002): el candado de
/// cobro por cuenta, compartido entre todos los equipos del negocio.
class PaymentAttemptLease {
  const PaymentAttemptLease({
    required this.acquired,
    this.reason,
    this.holderLabel,
    this.deviceId,
    this.paidByOthers = 0,
    this.nextSplitSequence = 0,
  });

  /// true = este intento puede cobrar.
  final bool acquired;

  /// Si no se obtuvo: `held` (otro equipo está cobrando) o `closed` (la
  /// cuenta ya está cobrada).
  final String? reason;

  /// Quién tiene el candado (nombre del operador), para decírselo al cajero.
  final String? holderLabel;
  final String? deviceId;

  /// Lo ya cobrado en esta cuenta por OTROS intentos mientras sigue abierta:
  /// un cobro que quedó a medias. Este intento solo debe cobrar el restante.
  final double paidByOthers;

  /// Primer `split_sequence` libre para no chocar con abonos anteriores del
  /// mismo método en el índice único de pagos.
  final int nextSplitSequence;

  bool get heldByOther => !acquired && reason == 'held';
  bool get accountClosed => !acquired && reason == 'closed';

  factory PaymentAttemptLease.fromMap(Map<String, dynamic> map) {
    double toDouble(Object? v) =>
        v is num ? v.toDouble() : double.tryParse('$v') ?? 0;
    int toInt(Object? v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;
    return PaymentAttemptLease(
      acquired: map['acquired'] == true,
      reason: map['reason']?.toString(),
      holderLabel: map['holder_label']?.toString(),
      deviceId: map['device_id']?.toString(),
      paidByOthers: toDouble(map['paid_by_others']),
      nextSplitSequence: toInt(map['next_split_sequence']),
    );
  }
}
