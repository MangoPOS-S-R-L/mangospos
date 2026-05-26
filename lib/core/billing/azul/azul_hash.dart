// PRD-Azul-Subscriptions §6 — AuthHash HMAC-SHA512.
//
// Algoritmo Azul Payment Page:
//   - Concatenar campos en orden estricto, sin separadores. Campo vacío = "".
//   - Mensaje = concat(campos) + AuthKey (la AuthKey se incluye AL FINAL del mensaje).
//   - HMAC-SHA512 con AuthKey como clave HMAC (la misma key se usa como clave HMAC
//     y como sufijo del mensaje — peculiar pero es el algoritmo de Azul).
//   - Encoding UTF-8 (decisión D2 — validado byte-exacto contra golden test).
//   - Output hex lowercase, 128 chars.

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

class AzulHash {
  const AzulHash._();

  /// Calcula el AuthHash que va en el form HTML del Payment Page.
  /// El orden de [orderedFields] depende del TrxType (ver builders abajo).
  static String compute({
    required List<String> orderedFields,
    required String authKey,
  }) {
    final message = '${orderedFields.join()}$authKey';
    final hmac = Hmac(sha512, utf8.encode(authKey));
    return hmac.convert(utf8.encode(message)).toString().toLowerCase();
  }

  /// Comparación constant-time de dos hashes hex (PRD §7.3 — anti timing attack).
  /// Devuelve false si las longitudes difieren, sin early exit en byte-mismatch.
  static bool constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    final ba = Uint8List.fromList(a.codeUnits);
    final bb = Uint8List.fromList(b.codeUnits);
    var diff = 0;
    for (var i = 0; i < ba.length; i++) {
      diff |= ba[i] ^ bb[i];
    }
    return diff == 0;
  }
}

/// Campos ordenados de un request Sale/Hold/Create al Payment Page (PRD §6.2).
/// El campo TrxType NO entra al hash; solo viaja en el POST.
class AzulPaymentPageFields {
  final String merchantId;
  final String merchantName;
  final String merchantType;
  final String currencyCode;
  final String orderNumber;
  final String amount;
  final String itbis;
  final String approvedUrl;
  final String declinedUrl;
  final String cancelUrl;
  final String useCustomField1;
  final String customField1Label;
  final String customField1Value;
  final String useCustomField2;
  final String customField2Label;
  final String customField2Value;

  const AzulPaymentPageFields({
    required this.merchantId,
    required this.merchantName,
    required this.merchantType,
    required this.currencyCode,
    required this.orderNumber,
    required this.amount,
    required this.itbis,
    required this.approvedUrl,
    required this.declinedUrl,
    required this.cancelUrl,
    this.useCustomField1 = '0',
    this.customField1Label = '',
    this.customField1Value = '',
    this.useCustomField2 = '0',
    this.customField2Label = '',
    this.customField2Value = '',
  });

  List<String> toOrderedFields() => [
    merchantId,
    merchantName,
    merchantType,
    currencyCode,
    orderNumber,
    amount,
    itbis,
    approvedUrl,
    declinedUrl,
    cancelUrl,
    useCustomField1,
    customField1Label,
    customField1Value,
    useCustomField2,
    customField2Label,
    customField2Value,
  ];
}

/// Campos ordenados de la respuesta de Azul para validar el AuthHash recibido (PRD §6.2).
class AzulResponseFields {
  final String orderNumber;
  final String amount;
  final String authorizationCode;
  final String dateTime;
  final String responseCode;
  final String isoCode;
  final String responseMessage;
  final String errorDescription;
  final String rrn;

  const AzulResponseFields({
    required this.orderNumber,
    required this.amount,
    required this.authorizationCode,
    required this.dateTime,
    required this.responseCode,
    required this.isoCode,
    required this.responseMessage,
    required this.errorDescription,
    required this.rrn,
  });

  List<String> toOrderedFields() => [
    orderNumber,
    amount,
    authorizationCode,
    dateTime,
    responseCode,
    isoCode,
    responseMessage,
    errorDescription,
    rrn,
  ];
}
