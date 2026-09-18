// "Dispositivos conectados" — lado del equipo (migración 20260918_0001).
//
// Cada equipo con sesión reporta quién está logueado y en qué negocio vía
// `fn_device_session_ping`. El dueño/admin lo ve en Ajustes y puede pedir
// que un equipo cierre su sesión: el equipo se entera en su próximo ping y
// se desloguea solo (ver [DeviceSessionReporter]).
//
// Identidad:
//   - device_id  = DeviceUtils.getDeviceId(): un UUID por instalación.
//   - session_key = aleatorio por INICIO DE SESIÓN, guardado junto al user_id.
//     Sobrevive reinicios de la app (la sesión de Supabase también) y se
//     borra al cerrar sesión, así un login nuevo en el mismo equipo es una
//     sesión nueva para el servidor.
//
// Todo es best-effort: nada de esto puede frenar un login, un logout ni una
// venta.

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../data/repositories/device_sessions_repository.dart';
import '../printing/device_identity.dart';
import '../utils/device_utils.dart';

class DeviceSessionService {
  DeviceSessionService._();

  static const String _sessionKeyPref = 'device_session_key';

  /// Tope para el aviso de cierre al hacer logout: sin red, el logout no
  /// espera más que esto.
  static const Duration signOutReportTimeout = Duration(seconds: 3);

  static bool _revokedNotice = false;
  static String? _appVersion;

  static DeviceSessionsRepository _repo() =>
      DeviceSessionsRepository(Supabase.instance.client);

  /// Key de la sesión actual de [userId]. La crea si no hay, o si la guardada
  /// es de otro usuario (login con otra cuenta sin pasar por signOut).
  static Future<String> sessionKey(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    final stored = parseStoredKey(prefs.getString(_sessionKeyPref));
    if (stored != null && stored.userId == userId) return stored.key;
    return rotateSessionKey(userId);
  }

  static Future<String> rotateSessionKey(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    final key = const Uuid().v4();
    await prefs.setString(_sessionKeyPref, '$userId|$key');
    return key;
  }

  static Future<void> clearSessionKey() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_sessionKeyPref);
  }

  /// Formato guardado: `<userId>|<key>`. Público para los tests.
  @visibleForTesting
  static ({String userId, String key})? parseStoredKey(String? raw) {
    if (raw == null) return null;
    final i = raw.indexOf('|');
    if (i <= 0 || i == raw.length - 1) return null;
    return (userId: raw.substring(0, i), key: raw.substring(i + 1));
  }

  /// Reporta la sesión de este equipo en [businessId].
  static Future<DeviceSessionPingResult> ping({
    required String businessId,
    required String userId,
    String? employeeId,
  }) async {
    return _repo().ping(
      businessId: businessId,
      deviceId: await DeviceUtils.getDeviceId(),
      sessionKey: await sessionKey(userId),
      deviceName: await DeviceIdentity.getDisplayName(),
      hostname: _hostname(),
      platform: DeviceIdentity.currentPlatform(),
      osVersion: _osVersion(),
      appVersion: await _readAppVersion(),
      employeeId: employeeId,
    );
  }

  /// Marca la sesión de este equipo como cerrada. Hay que llamarlo ANTES de
  /// `auth.signOut()`: después ya no hay token y el servidor no sabe quién
  /// es. Nunca lanza y nunca tarda más de [signOutReportTimeout]; la key se
  /// borra siempre, aunque el aviso no llegue (el próximo login trae una
  /// nueva y el servidor reinicia la fila).
  static Future<void> reportSignedOut(String? businessId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = parseStoredKey(prefs.getString(_sessionKeyPref));
      if (stored == null || businessId == null || businessId.isEmpty) return;
      if (Supabase.instance.client.auth.currentUser == null) return;
      await _repo()
          .ping(
            businessId: businessId,
            deviceId: await DeviceUtils.getDeviceId(),
            sessionKey: stored.key,
            signedOut: true,
          )
          .timeout(signOutReportTimeout);
    } catch (e) {
      debugPrint('[DeviceSession] aviso de cierre no llegó: $e');
    } finally {
      try {
        await clearSessionKey();
      } catch (_) {}
    }
  }

  /// La pantalla de login lo consume para explicar por qué se cerró la
  /// sesión. En memoria a propósito: solo aplica a este arranque.
  static void markRevokedNotice() => _revokedNotice = true;

  static bool consumeRevokedNotice() {
    final value = _revokedNotice;
    _revokedNotice = false;
    return value;
  }

  static Future<String?> _readAppVersion() async {
    if (_appVersion != null) return _appVersion;
    try {
      final info = await PackageInfo.fromPlatform();
      final build = info.buildNumber.trim();
      _appVersion = build.isEmpty ? info.version : '${info.version}+$build';
    } catch (_) {
      const fromDefine = String.fromEnvironment('APP_VERSION');
      _appVersion = fromDefine.isEmpty ? null : fromDefine;
    }
    return _appVersion;
  }

  static String? _hostname() {
    if (kIsWeb) return null;
    try {
      final host = Platform.localHostname.trim();
      // Android/iOS devuelven "localhost": no distingue nada.
      if (host.isEmpty || host == 'localhost') return null;
      return host;
    } catch (_) {
      return null;
    }
  }

  static String? _osVersion() {
    if (kIsWeb) return null;
    try {
      final v = Platform.operatingSystemVersion.trim();
      return v.isEmpty ? null : v;
    } catch (_) {
      return null;
    }
  }
}
