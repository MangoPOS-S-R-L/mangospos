// QR de respaldo del e-CF (cuando el comprobante no trae `public_url`).
//
// Lo que protege: que el ticket NUNCA salga con un QR que la DGII no valida.
// Antes se armaba con el ambiente de PRUEBAS fijo, con el dominio de E31 para
// cualquier tipo y con el total cobrado (propina legal incluida) en vez del
// declarado. Formatos tomados de los ejemplos de la API de Alanube.

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/data/models/sales_models.dart';

FiscalDocument _doc({
  String type = 'E32',
  double taxable = 67.80,
  double itbis = 12.20,
  double total = 80.00,
  String? code = 'DJOULN',
}) =>
    FiscalDocument(
      id: 'fd-1',
      businessId: 'b-1',
      ncfType: type,
      ncfNumber: '${type}0000000003',
      customerName: 'CONSUMIDOR FINAL',
      subtotal: taxable,
      taxableAmount: taxable,
      itbisAmount: itbis,
      total: total,
      status: 'active',
      issuedAt: DateTime.utc(2026, 8, 29, 16, 44),
      isElectronic: true,
      ecfStatus: 'accepted',
      ecfSecurityCode: code,
    );

void main() {
  test('E32 en producción: fc.dgii.gov.do/ecf/ConsultaTimbreFC sin fechas', () {
    final url = _doc().buildDgiiVerifyUrl(emitterRnc: '133328828', sandbox: false)!;
    final uri = Uri.parse(url);
    expect(uri.host, 'fc.dgii.gov.do');
    expect(uri.path, '/ecf/ConsultaTimbreFC');
    expect(uri.queryParameters['RncEmisor'], '133328828');
    expect(uri.queryParameters['ENCF'], 'E320000000003');
    expect(uri.queryParameters['MontoTotal'], '80.00');
    expect(uri.queryParameters['CodigoSeguridad'], 'DJOULN');
    expect(uri.queryParameters.containsKey('FechaEmision'), isFalse);
  });

  test('pruebas solo si el negocio está en sandbox', () {
    final url = _doc().buildDgiiVerifyUrl(emitterRnc: '133328828', sandbox: true)!;
    expect(Uri.parse(url).path, '/testecf/ConsultaTimbreFC');
  });

  test('con propina legal el total no es el declarado: no se arma', () {
    // Caso real Tropella: 80.00 cobrado, 73.11 declarado.
    final doc = _doc(taxable: 57.63, itbis: 10.37, total: 80.00);
    expect(doc.buildDgiiVerifyUrl(emitterRnc: '133328828', sandbox: false), isNull);
  });

  test('E31 lleva fecha de firma exacta: sin public_url no se inventa', () {
    expect(_doc(type: 'E31').buildDgiiVerifyUrl(emitterRnc: '133328828', sandbox: false), isNull);
  });

  test('E32 de RD\$250,000 o más usa el formato completo: no se arma', () {
    final doc = _doc(taxable: 211864.41, itbis: 38135.59, total: 250000);
    expect(doc.buildDgiiVerifyUrl(emitterRnc: '133328828', sandbox: false), isNull);
  });

  test('sin código de seguridad o sin RNC no hay QR', () {
    expect(_doc(code: null).buildDgiiVerifyUrl(emitterRnc: '133328828', sandbox: false), isNull);
    expect(_doc().buildDgiiVerifyUrl(emitterRnc: '  ', sandbox: false), isNull);
  });
}
