// PRD 5 F2.5 — Identidad estable del device dentro del business.
//
// Cada device de la app necesita un UUID estable para registrarse como host
// de impresoras locales (USB/BT) y para que otros devices del business puedan
// rutear jobs hacia él vía LAN.
//
// El UUID se genera en el primer arranque por business y se persiste en
// SharedPreferences. La key incluye el business_id para soportar uso
// multi-business desde el mismo dispositivo (ej. owner que administra
// 2 negocios desde la misma Mac).

import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class DeviceIdentity {
  static const String _keyPrefix = 'device_id_';
  static const String _nameKey = 'device_name';

  /// Devuelve el UUID estable del device para el [businessId] dado.
  /// Lo crea si no existe.
  static Future<String> getOrCreateId(String businessId) async {
    final prefs = await SharedPreferences.getInstance();
    final key = '$_keyPrefix$businessId';
    final existing = prefs.getString(key);
    if (existing != null && existing.isNotEmpty) return existing;

    final id = _uuidV4();
    await prefs.setString(key, id);
    return id;
  }

  /// Nombre legible del device, configurable por el operador.
  /// Si no se ha configurado, devuelve un default basado en plataforma + hostname.
  static Future<String> getDisplayName() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_nameKey);
    if (saved != null && saved.isNotEmpty) return saved;
    return _platformDefaultName();
  }

  static Future<void> setDisplayName(String name) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_nameKey, name.trim());
  }

  /// Plataforma normalizada para guardar en `device_agents.platform`.
  static String currentPlatform() {
    if (kIsWeb) return 'web';
    try {
      if (Platform.isMacOS) return 'macos';
      if (Platform.isWindows) return 'windows';
      if (Platform.isLinux) return 'linux';
      if (Platform.isAndroid) return 'android';
      if (Platform.isIOS) return 'ios';
      if (Platform.isFuchsia) return 'fuchsia';
    } catch (_) {
      // ignore
    }
    return 'unknown';
  }

  static String _platformDefaultName() {
    if (kIsWeb) return 'Navegador';
    try {
      if (Platform.isMacOS) return 'Mac';
      if (Platform.isWindows) return 'PC';
      if (Platform.isLinux) return 'Linux';
      if (Platform.isAndroid) return 'Android';
      if (Platform.isIOS) return 'iOS';
    } catch (_) {
      // ignore
    }
    return 'Dispositivo';
  }

  /// UUID v4 minimal, sin agregar dependencia de uuid package.
  static String _uuidV4() {
    final r = Random.secure();
    final bytes = List<int>.generate(16, (_) => r.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 1
    String hex(int b) => b.toRadixString(16).padLeft(2, '0');
    final s = bytes.map(hex).join();
    return '${s.substring(0, 8)}-${s.substring(8, 12)}-${s.substring(12, 16)}-${s.substring(16, 20)}-${s.substring(20, 32)}';
  }
}
