// PRD 5 F2.5 — Identidad estable del device dentro del business.
// PRD 5 F5.1 — preferir hardware UUID del OS sobre UUID v4 aleatorio.
//
// Cada device de la app necesita un UUID estable para registrarse como host
// de impresoras locales (USB/BT) y para que otros devices del business puedan
// rutear jobs hacia él vía LAN.
//
// Estrategia (F5.1):
//   1. Intentar leer el UUID hardware del OS (MachineId.read).
//      → macOS: IOPlatformUUID. Windows: SMBIOS UUID. Linux: /etc/machine-id.
//      Sobrevive reinstalaciones y rebuilds — caso del bug donde rebuild
//      Windows generaba un UUID nuevo y rompía printers.host_device_id.
//   2. Si el hardware UUID está disponible, lo guardamos en SharedPreferences
//      por business y lo usamos. Si ya había un UUID viejo en SP distinto del
//      hardware, devolvemos el VIEJO en este arranque (evita romper
//      printers.host_device_id del business hasta que se haga la migración
//      manual con _adoptHardwareId), y guardamos un flag para mostrarle al
//      operador la opción de "Adoptar identidad de hardware" en la UI.
//   3. Móvil (Android/iOS) y Web: fallback a UUID v4 random + SP (comportamiento
//      original).

import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'machine_id.dart';

class DeviceIdentity {
  static const String _keyPrefix = 'device_id_';
  static const String _nameKey = 'device_name';
  static const String _hwAdoptedPrefix = 'device_id_hw_adopted_';

  /// Devuelve el UUID estable del device para el [businessId] dado.
  /// Lo crea si no existe.
  ///
  /// Para nuevos installs en desktop (Mac/Win/Linux), usa hardware UUID.
  /// Para installs existentes que ya tenían UUID en SP, conserva el viejo
  /// para no romper asignaciones — la migración a hardware UUID se hace
  /// vía [adoptHardwareId] (acción explícita desde la UI de admin).
  static Future<String> getOrCreateId(String businessId) async {
    final prefs = await SharedPreferences.getInstance();
    final key = '$_keyPrefix$businessId';
    final existing = prefs.getString(key);
    if (existing != null && existing.isNotEmpty) return existing;

    // Sin SP: nuevo install. Si hay hardware UUID lo usamos directamente.
    final hw = await MachineId.read();
    final id = hw ?? _uuidV4();
    await prefs.setString(key, id);
    if (hw != null) {
      await prefs.setBool('$_hwAdoptedPrefix$businessId', true);
    }
    return id;
  }

  /// Retorna el hardware UUID actual (si la plataforma lo expone), sin
  /// tocar SharedPreferences. Útil para que la UI muestre "tu device id
  /// guardado es X, el hardware reporta Y, querés migrarlo?".
  static Future<String?> readHardwareId() => MachineId.read();

  /// Detecta si el ID guardado para [businessId] coincide con el hardware
  /// UUID. Si retorna `false` y `readHardwareId()` no es null, conviene
  /// ofrecer al admin la opción de [adoptHardwareId] para que rebuilds
  /// futuros del binario no rompan la asignación.
  static Future<bool> isUsingHardwareId(String businessId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('$_hwAdoptedPrefix$businessId') ?? false;
  }

  /// Migra explícitamente el device a usar el hardware UUID.
  ///
  /// Pasos atómicos:
  ///   1. Llama al RPC `fn_migrate_device_identity` que mueve
  ///      `device_agents.id` y `printers.host_device_id` del UUID viejo
  ///      al hardware UUID en una transacción.
  ///   2. Si el RPC tuvo éxito, persiste el hardware UUID en
  ///      SharedPreferences y marca el flag de adopción.
  ///
  /// Devuelve `(oldId, newId)` cuando la migración se aplicó.
  /// Retorna null si la plataforma no expone hardware UUID o si ya
  /// estaba adoptado.
  ///
  /// Si el paso 1 falla (red caída, RLS), no toca SharedPreferences —
  /// el caller puede reintentar más tarde.
  static Future<({String oldId, String newId})?> adoptHardwareId(
    String businessId,
  ) async {
    final hw = await MachineId.read();
    if (hw == null) return null;

    final prefs = await SharedPreferences.getInstance();
    final key = '$_keyPrefix$businessId';
    final old = prefs.getString(key);
    if (old == hw) return null;

    if (old != null && old.isNotEmpty) {
      // Mover device_agents + printers en backend antes de tocar local.
      try {
        await Supabase.instance.client.rpc(
          'fn_migrate_device_identity',
          params: {
            'p_old_id': old,
            'p_new_id': hw,
            'p_business_id': businessId,
          },
        );
      } catch (e) {
        // Backend rechazó la migración; no actualizamos local para
        // mantener consistencia. El caller decide si reintentar.
        rethrow;
      }
    }

    await prefs.setString(key, hw);
    await prefs.setBool('$_hwAdoptedPrefix$businessId', true);

    return (oldId: old ?? '', newId: hw);
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
