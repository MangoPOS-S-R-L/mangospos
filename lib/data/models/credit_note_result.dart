// Resultado de emitir la nota de crédito que reversa un comprobante fiscal.
//
// Anular una venta con NCF no es borrarla: un comprobante que la DGII ya
// aceptó solo se reversa emitiendo una NOTA DE CRÉDITO que lo referencie
// (e-CF 34 si el original es electrónico, B04 si es de papel). El RPC
// `fn_issue_credit_note` hace esa emisión y devuelve uno de estos casos.
//
// La regla de producto está en el nombre de los estados: `noSequence` y
// `failed` NO tumban la anulación. La venta se anula igual y la nota queda
// pendiente, porque trancar al cajero con el cliente delante es peor que
// emitir la nota diez minutos más tarde. Lo que sí hace falta es que esos
// dos casos se VEAN, y para eso está `needsAttention`.

enum CreditNoteStatus {
  /// Nota emitida. Si es electrónica, ya quedó encolada hacia la DGII.
  issued,

  /// Ya existía una nota activa para ese comprobante. No se emite otra.
  alreadyIssued,

  /// El negocio no tiene secuencia E34/B04 cargada (o se le acabó el rango).
  /// La anulación siguió; la nota queda pendiente.
  noSequence,

  /// No aplica: el documento no tiene NCF, ya es una nota, o es un e-CF que
  /// la DGII rechazó (no existe ante ella, no hay nada que reversar).
  notApplicable,

  /// El documento no existe.
  notFound,

  /// Error de red o del servidor. Igual que `noSequence`: hay que reintentar.
  failed,
}

class CreditNoteResult {
  /// Comprobante original que se anuló.
  final String fiscalDocumentId;
  final CreditNoteStatus status;

  /// Id de la nota emitida (o de la que ya existía).
  final String? creditNoteId;

  /// e-NCF/NCF de la nota.
  final String? ncfNumber;

  /// 'E34' o 'B04'.
  final String? ncfType;

  /// True si la nota va a la DGII; false si es de papel.
  final bool isElectronic;

  /// NCF del comprobante anulado.
  final String? originalNcf;

  /// Motivo cuando el estado no es `issued`: 'sin_ncf', 'es_nota',
  /// 'rechazado', o el mensaje del error.
  final String? reason;

  const CreditNoteResult({
    required this.fiscalDocumentId,
    required this.status,
    this.creditNoteId,
    this.ncfNumber,
    this.ncfType,
    this.isElectronic = false,
    this.originalNcf,
    this.reason,
  });

  factory CreditNoteResult.fromRpc(
    String fiscalDocumentId,
    Map<String, dynamic> json,
  ) {
    return CreditNoteResult(
      fiscalDocumentId: fiscalDocumentId,
      status: _statusFrom(json['status']?.toString()),
      creditNoteId: json['credit_note_id']?.toString(),
      ncfNumber: json['ncf_number']?.toString(),
      ncfType: json['ncf_type']?.toString(),
      isElectronic: json['is_electronic'] == true,
      originalNcf: json['original_ncf']?.toString(),
      reason: json['reason']?.toString(),
    );
  }

  factory CreditNoteResult.failure(String fiscalDocumentId, Object error) {
    return CreditNoteResult(
      fiscalDocumentId: fiscalDocumentId,
      status: CreditNoteStatus.failed,
      reason: error.toString(),
    );
  }

  static CreditNoteStatus _statusFrom(String? raw) {
    switch (raw) {
      case 'issued':
        return CreditNoteStatus.issued;
      case 'already_issued':
        return CreditNoteStatus.alreadyIssued;
      case 'no_sequence':
        return CreditNoteStatus.noSequence;
      case 'not_applicable':
        return CreditNoteStatus.notApplicable;
      case 'not_found':
        return CreditNoteStatus.notFound;
      default:
        return CreditNoteStatus.failed;
    }
  }

  /// Hay una nota (recién emitida o ya existente) con la que trabajar.
  bool get hasNote =>
      status == CreditNoteStatus.issued ||
      status == CreditNoteStatus.alreadyIssued;

  /// La anulación quedó a medias fiscalmente: falta emitir la nota.
  bool get needsAttention =>
      status == CreditNoteStatus.noSequence ||
      status == CreditNoteStatus.failed;

  /// Mensaje para el cajero. Dice qué pasó y, cuando falta algo, qué hacer.
  String get message {
    switch (status) {
      case CreditNoteStatus.issued:
      case CreditNoteStatus.alreadyIssued:
        final ncf = ncfNumber ?? '';
        return ncf.isEmpty ? 'Nota de crédito emitida' : 'Nota de crédito $ncf';
      case CreditNoteStatus.noSequence:
        final tipo = ncfType ?? 'de nota de crédito';
        return 'La venta se anuló, pero falta la secuencia $tipo. '
            'Cárgala en Ajustes → Comprobantes fiscales y reintenta la nota.';
      case CreditNoteStatus.notApplicable:
        switch (reason) {
          case 'rechazado':
            return 'El comprobante fue rechazado por la DGII: no lleva nota '
                'de crédito.';
          case 'es_nota':
            return 'El documento ya es una nota de crédito.';
          default:
            return 'La venta no tenía comprobante fiscal: no lleva nota de '
                'crédito.';
        }
      case CreditNoteStatus.notFound:
        return 'No se encontró el comprobante fiscal.';
      case CreditNoteStatus.failed:
        return 'La venta se anuló, pero la nota de crédito no se pudo emitir. '
            'Reinténtala desde el historial.';
    }
  }
}
