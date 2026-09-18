import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/device_session.dart';

/// Respuesta de `fn_device_session_ping`.
class DeviceSessionPingResult {
  /// Un admin pidió cerrar la sesión de este equipo.
  final bool revoked;

  /// La key ya estaba cerrada en el servidor (ping tardío): hay que generar
  /// otra y volver a reportar.
  final bool closed;

  const DeviceSessionPingResult({required this.revoked, required this.closed});

  factory DeviceSessionPingResult.fromResponse(dynamic response) {
    if (response is! Map) {
      return const DeviceSessionPingResult(revoked: false, closed: false);
    }
    return DeviceSessionPingResult(
      revoked: response['revoked'] == true,
      closed: response['closed'] == true,
    );
  }
}

/// Sesiones abiertas por equipo (migración 20260918_0001).
///
/// El ping lo usa el propio equipo ([DeviceSessionService]); listar, cerrar
/// remoto y renombrar son de dueño/admin y el servidor lo valida.
class DeviceSessionsRepository {
  final SupabaseClient _client;

  DeviceSessionsRepository(this._client);

  Future<DeviceSessionPingResult> ping({
    required String businessId,
    required String deviceId,
    required String sessionKey,
    String? deviceName,
    String? hostname,
    String? platform,
    String? osVersion,
    String? appVersion,
    String? employeeId,
    bool signedOut = false,
  }) async {
    final response = await _client.rpc('fn_device_session_ping', params: {
      'p_business_id': businessId,
      'p_device_id': deviceId,
      'p_session_key': sessionKey,
      'p_device_name': deviceName,
      'p_hostname': hostname,
      'p_platform': platform,
      'p_os_version': osVersion,
      'p_app_version': appVersion,
      'p_employee_id': employeeId,
      'p_signed_out': signedOut,
    });
    return DeviceSessionPingResult.fromResponse(response);
  }

  Future<List<DeviceSession>> list(String businessId) async {
    final rows = await _client.rpc(
      'fn_device_sessions_list',
      params: {'p_business_id': businessId},
    );
    if (rows is! List) return const [];
    return rows
        .whereType<Map>()
        .map((r) => DeviceSession.fromMap(Map<String, dynamic>.from(r)))
        .toList(growable: false);
  }

  Future<void> revoke(String sessionId) async {
    await _client.rpc(
      'fn_device_session_revoke',
      params: {'p_session_id': sessionId},
    );
  }

  /// `label` vacío o null quita la etiqueta.
  Future<void> rename(String sessionId, String? label) async {
    await _client.rpc(
      'fn_device_session_rename',
      params: {'p_session_id': sessionId, 'p_label': label ?? ''},
    );
  }

  static String humanizeError(Object error) {
    final msg = error.toString();
    if (msg.contains('ACCESS_DENIED')) {
      return 'Solo el dueño o un administrador puede ver y cerrar sesiones '
          'de otros dispositivos.';
    }
    if (msg.contains('NOT_FOUND')) {
      return 'Ese dispositivo ya no tiene una sesión abierta.';
    }
    if (msg.contains('PGRST202') ||
        msg.contains('42883') ||
        msg.contains('Could not find the function')) {
      return 'Esta función todavía no está instalada en el servidor.';
    }
    return 'No se pudo completar la operación. Revisa la conexión e '
        'inténtalo de nuevo.';
  }
}

final deviceSessionsRepositoryProvider =
    Provider<DeviceSessionsRepository>((ref) {
  return DeviceSessionsRepository(Supabase.instance.client);
});
