// Resultado de la nota de crédito al anular.
//
// Lo que protege: que los casos que NO llevan nota (e-CF que nunca llegó a la
// DGII, papel sin crédito fiscal — migración 20260917_0005) se lean como "no
// aplica" y no como pendiente, y que el cajero vea por qué en vez de "la venta
// no tenía comprobante fiscal".

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/data/models/credit_note_result.dart';

CreditNoteResult _rpc(Map<String, dynamic> json) =>
    CreditNoteResult.fromRpc('fd-1', json);

void main() {
  test('e-CF que nunca llegó a la DGII: no aplica y no queda pendiente', () {
    final r = _rpc({'status': 'not_applicable', 'reason': 'no_enviado'});
    expect(r.status, CreditNoteStatus.notApplicable);
    expect(r.needsAttention, isFalse);
    expect(r.hasNote, isFalse);
    expect(r.message, contains('no llegó a la DGII'));
  });

  test('papel sin crédito fiscal: no aplica, queda como anulado', () {
    final r = _rpc({'status': 'not_applicable', 'reason': 'papel_sin_credito_fiscal'});
    expect(r.status, CreditNoteStatus.notApplicable);
    expect(r.needsAttention, isFalse);
    expect(r.message, contains('sin crédito fiscal'));
  });

  test('sin NCF conserva su mensaje', () {
    final r = _rpc({'status': 'not_applicable', 'reason': 'sin_ncf'});
    expect(r.message, contains('no tenía comprobante fiscal'));
  });

  test('sin secuencia sigue pidiendo atención', () {
    final r = _rpc({'status': 'no_sequence', 'ncf_type': 'E34'});
    expect(r.needsAttention, isTrue);
    expect(r.message, contains('E34'));
  });
}
