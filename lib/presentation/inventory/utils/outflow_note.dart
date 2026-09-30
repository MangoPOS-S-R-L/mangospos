import '../state/adjust_reasons.dart';

/// Separa el motivo del detalle en la nota de una salida.
///
/// Toda salida guarda la nota como «Vencido — nevera 2» (el motivo va de
/// prefijo aunque también exista `reason_code`, para que se lea en servidores
/// sin la columna). Si el prefijo no es un motivo de salida conocido, la nota
/// entera es el detalle y el motivo es «Merma».
({String reason, String detail}) splitOutflowNote(String notes) {
  final text = notes.trim();
  final dash = text.indexOf(' — ');
  final head = dash >= 0 ? text.substring(0, dash) : text;
  final isReason = kAdjustReasons.any((r) => r.isExit && r.label == head);
  if (!isReason) return (reason: 'Merma', detail: text);
  return (
    reason: head,
    detail: dash >= 0 ? text.substring(dash + 3).trim() : '',
  );
}
