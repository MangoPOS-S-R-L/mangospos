import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/business/business_resolver.dart';

/// Enlaces de una factura electrónica ya emitida, para abrirla desde el
/// historial.
///
/// El PDF y el XML de Alanube vencen, así que se piden en el momento a la Edge
/// Function `ecf-document-links`; no se guardan. La consulta en la DGII no
/// vence (y es lo que codifica el QR del ticket).
class EcfDocumentLinks {
  const EcfDocumentLinks({
    this.stampUrl,
    this.pdfUrl,
    this.xmlUrl,
    this.legalStatus,
  });

  /// Consulta del comprobante en la DGII.
  final String? stampUrl;

  /// Representación impresa que genera Alanube.
  final String? pdfUrl;

  /// XML firmado.
  final String? xmlUrl;

  /// Estado ante la DGII según Alanube (ACCEPTED, REJECTED, IN_PROCESS…).
  final String? legalStatus;

  factory EcfDocumentLinks.fromJson(Map<String, dynamic> json) {
    String? url(Object? v) =>
        v is String && v.startsWith('http') ? v : null;
    return EcfDocumentLinks(
      stampUrl: url(json['stamp_url']),
      pdfUrl: url(json['pdf_url']),
      xmlUrl: url(json['xml_url']),
      legalStatus: json['legal_status'] as String?,
    );
  }
}

/// Error con el mensaje que arma el servidor, listo para mostrar.
class EcfDocumentsException implements Exception {
  const EcfDocumentsException(this.message, {this.code});

  final String message;
  final String? code;

  @override
  String toString() => message;
}

class EcfDocumentsRepository {
  EcfDocumentsRepository(this._client);

  final SupabaseClient _client;

  Future<EcfDocumentLinks> getLinks(String fiscalDocumentId) async {
    try {
      final res = await _client.functions.invoke(
        'ecf-document-links',
        body: {'fiscal_document_id': fiscalDocumentId},
      );
      final data = res.data;
      if (data is! Map) {
        throw const EcfDocumentsException(
          'Respuesta inesperada al consultar la factura electrónica.',
        );
      }
      return EcfDocumentLinks.fromJson(Map<String, dynamic>.from(data));
    } on FunctionException catch (e) {
      final details = e.details;
      if (details is Map && details['error'] is Map) {
        final err = Map<String, dynamic>.from(details['error'] as Map);
        throw EcfDocumentsException(
          (err['message'] as String?) ??
              'No se pudo abrir la factura electrónica.',
          code: err['code'] as String?,
        );
      }
      throw EcfDocumentsException(
        e.status == 404
            ? 'El servidor todavía no tiene esta función desplegada.'
            : 'No se pudo abrir la factura electrónica.',
      );
    }
  }

  /// True si el negocio emite contra el ambiente de PRUEBAS de Alanube/DGII.
  /// Ante cualquier duda (sin configuración, sin red) se asume producción: un
  /// QR de pruebas en un ticket real es peor que uno de producción.
  Future<bool> isSandbox(String businessId) async {
    try {
      final bid = await BusinessResolver.ensure(businessId);
      final row = await _client
          .from('business_alanube_settings')
          .select('environment')
          .eq('business_id', bid)
          .maybeSingle();
      return row?['environment'] == 'sandbox';
    } catch (_) {
      return false;
    }
  }
}

final ecfDocumentsRepositoryProvider = Provider<EcfDocumentsRepository>((ref) {
  return EcfDocumentsRepository(Supabase.instance.client);
});
