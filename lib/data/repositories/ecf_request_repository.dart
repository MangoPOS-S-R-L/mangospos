import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/business/business_resolver.dart';

/// Solicitud de facturación electrónica que hace el dueño desde la POS.
///
/// Todo pasa por la Edge Function `ecf-onboarding` (acciones `request_status`
/// y `submit_request`), que valida que el usuario sea dueño o administrador
/// del negocio. El certificado viaja a Alanube en la misma petición y no se
/// guarda en MangoPOS.

/// En qué va la facturación electrónica del negocio (lo deriva el servidor).
enum EcfRequestStage {
  /// Nunca la pidió.
  none,

  /// Pedida; falta registrar la empresa con el proveedor.
  company,

  /// Falta la autorización de la DGII.
  certification,

  /// Autorizado; faltan las secuencias e-NCF.
  sequences,

  /// Todo listo; falta activarla.
  activation,

  /// Ya emite comprobantes electrónicos.
  active;

  static EcfRequestStage parse(String? raw) => EcfRequestStage.values.firstWhere(
        (s) => s.name == raw,
        orElse: () => EcfRequestStage.none,
      );
}

class EcfRequestStatus {
  const EcfRequestStatus({
    required this.stage,
    this.requestedAt,
    this.contactName,
    this.contactPhone,
    this.alreadyAuthorized,
    this.data = const EcfRequestData(),
  });

  final EcfRequestStage stage;
  final DateTime? requestedAt;
  final String? contactName;
  final String? contactPhone;
  final bool? alreadyAuthorized;

  /// Lo último que mandó (o lo que la POS ya tenía): precarga el formulario.
  final EcfRequestData data;

  factory EcfRequestStatus.fromJson(Map<String, dynamic> json) {
    final data = json['data'];
    return EcfRequestStatus(
      stage: EcfRequestStage.parse(json['stage'] as String?),
      requestedAt: DateTime.tryParse(json['requested_at']?.toString() ?? ''),
      contactName: json['contact_name'] as String?,
      contactPhone: json['contact_phone'] as String?,
      alreadyAuthorized: json['already_authorized'] as bool?,
      data: data is Map
          ? EcfRequestData.fromJson(Map<String, dynamic>.from(data))
          : const EcfRequestData(),
    );
  }
}

/// Datos del contribuyente tal como están en la DGII.
class EcfRequestData {
  const EcfRequestData({
    this.rnc,
    this.legalName,
    this.tradeName,
    this.fiscalAddress,
    this.province,
    this.municipality,
    this.email,
  });

  final String? rnc;
  final String? legalName;
  final String? tradeName;
  final String? fiscalAddress;
  final String? province;
  final String? municipality;
  final String? email;

  factory EcfRequestData.fromJson(Map<String, dynamic> json) => EcfRequestData(
        rnc: json['rnc'] as String?,
        legalName: json['legal_name'] as String?,
        tradeName: json['trade_name'] as String?,
        fiscalAddress: json['fiscal_address'] as String?,
        province: json['province'] as String?,
        municipality: json['municipality'] as String?,
        email: json['email'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'rnc': rnc,
        'legal_name': legalName,
        'trade_name': tradeName,
        'fiscal_address': fiscalAddress,
        'province': province,
        'municipality': municipality,
        'email': email,
      };
}

class EcfRequestSubmission {
  const EcfRequestSubmission({
    required this.data,
    required this.contactName,
    required this.contactPhone,
    required this.alreadyAuthorized,
    required this.certificateFilename,
    required this.certificateBytes,
    required this.certificatePassword,
  });

  final EcfRequestData data;
  final String contactName;
  final String contactPhone;
  final bool alreadyAuthorized;
  final String certificateFilename;
  final Uint8List certificateBytes;
  final String certificatePassword;
}

class EcfRequestResult {
  const EcfRequestResult({required this.companyRegistered, this.message});

  /// La empresa quedó registrada con el proveedor en este envío.
  final bool companyRegistered;

  /// Aviso del servidor cuando no se registró (por ejemplo, ya existía).
  final String? message;
}

class EcfRequestException implements Exception {
  const EcfRequestException(this.message, {this.code});

  final String message;
  final String? code;

  @override
  String toString() => message;
}

class EcfRequestRepository {
  EcfRequestRepository(this._client);

  final SupabaseClient _client;

  // Ajustes abre la pantalla fiscal con businessId 'auto': se resuelve al
  // negocio activo antes de mandarlo, el servidor exige el UUID real.
  Future<EcfRequestStatus> status(String businessId) async {
    final bid = await BusinessResolver.ensure(businessId);
    final data = await _invoke({'action': 'request_status', 'business_id': bid});
    return EcfRequestStatus.fromJson(data);
  }

  Future<EcfRequestResult> submit(String businessId, EcfRequestSubmission s) async {
    final bid = await BusinessResolver.ensure(businessId);
    final data = await _invoke({
      'action': 'submit_request',
      'business_id': bid,
      'data': s.data.toJson(),
      'contact_name': s.contactName,
      'contact_phone': s.contactPhone,
      'already_authorized': s.alreadyAuthorized,
      'accept_terms': true,
      'certificate': {
        'filename': s.certificateFilename,
        'content_base64': base64Encode(s.certificateBytes),
        'password': s.certificatePassword,
      },
    });
    return EcfRequestResult(
      companyRegistered: data['company_registered'] == true,
      message: data['message'] as String?,
    );
  }

  Future<Map<String, dynamic>> _invoke(Map<String, dynamic> body) async {
    try {
      final res = await _client.functions.invoke('ecf-onboarding', body: body);
      final data = res.data;
      if (data is Map) return Map<String, dynamic>.from(data);
      throw const EcfRequestException('Respuesta inesperada del servidor.');
    } on FunctionException catch (e) {
      final details = e.details;
      if (details is Map && details['error'] is Map) {
        final err = Map<String, dynamic>.from(details['error'] as Map);
        throw EcfRequestException(
          (err['message'] as String?) ?? 'No se pudo completar la solicitud.',
          code: err['code'] as String?,
        );
      }
      throw EcfRequestException(
        e.status == 404
            ? 'El servidor todavía no tiene esta función disponible.'
            : 'No se pudo completar la solicitud. Intenta de nuevo.',
      );
    }
  }
}

final ecfRequestRepositoryProvider = Provider<EcfRequestRepository>((ref) {
  return EcfRequestRepository(Supabase.instance.client);
});

final ecfRequestStatusProvider =
    FutureProvider.autoDispose.family<EcfRequestStatus, String>((ref, businessId) {
  return ref.watch(ecfRequestRepositoryProvider).status(businessId);
});
