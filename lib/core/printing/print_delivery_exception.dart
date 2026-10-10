/// Some print bytes may already have reached paper. Automatic recovery must
/// not retry or fail over this ticket; the operator must verify its delivery.
class PrintDeliveryUncertainException implements Exception {
  const PrintDeliveryUncertainException(this.cause);
  final Object cause;
  @override
  String toString() =>
      'No se pudo confirmar la impresión. Revisa si el ticket salió antes de reimprimir. ($cause)';
}
