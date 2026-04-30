// PRD 5 F5.1 — Hardware UUID estable por plataforma.
//
// Hasta antes de F5.1, DeviceIdentity generaba un UUID v4 aleatorio y lo
// persistía en SharedPreferences. Problema: SharedPreferences se borra
// con reinstalaciones del binario en Windows, generando un UUID nuevo y
// rompiendo las asignaciones de impresoras (printers.host_device_id
// apunta al UUID viejo, ahora huérfano).
//
// Solución: leer un identificador estable del hardware/OS:
//
//   - macOS:   ioreg → IOPlatformUUID (UUID del firmware/T2)
//   - Windows: PowerShell → Win32_ComputerSystemProduct.UUID (SMBIOS)
//   - Linux:   /etc/machine-id (o /var/lib/dbus/machine-id)
//
// Estos sobreviven reinstalaciones, rebuilds, e incluso (Mac/Win) la
// reinstalación del sistema operativo.
//
// Móvil (Android/iOS) y Web no exponen un UUID hardware estable sin
// permisos especiales o paquetes adicionales — para esas plataformas
// caemos al UUID v4 aleatorio + SharedPreferences (comportamiento previo).
//
// Privacidad: estos UUIDs son globalmente únicos pero NO identifican al
// usuario y se usan solo internamente para mapear printers.host_device_id.
// No se comparten fuera del business.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

class MachineId {
  const MachineId._();

  /// Lee un identificador estable del OS. Retorna null si la plataforma
  /// no expone uno o si el comando falla. El caller debe tener un
  /// fallback (típicamente UUID v4 random + SharedPreferences).
  static Future<String?> read() async {
    if (kIsWeb) return null;
    try {
      if (Platform.isMacOS) return await _readMacOS();
      if (Platform.isWindows) return await _readWindows();
      if (Platform.isLinux) return await _readLinux();
    } catch (_) {
      // any error → null, caller falls back.
    }
    return null;
  }

  static Future<String?> _readMacOS() async {
    // ioreg -rd1 -c IOPlatformExpertDevice imprime el bloque del device
    // con el atributo IOPlatformUUID. Usamos awk para extraerlo.
    final result = await Process.run(
      '/bin/sh',
      [
        '-c',
        "ioreg -rd1 -c IOPlatformExpertDevice | awk -F'\"' '/IOPlatformUUID/ {print \$4; exit}'",
      ],
    ).timeout(const Duration(seconds: 4));
    if (result.exitCode != 0) return null;
    return _normalize(result.stdout.toString());
  }

  static Future<String?> _readWindows() async {
    // SMBIOS UUID — sobrevive reinstalaciones del binario y de Windows.
    final result = await Process.run(
      'powershell',
      [
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-Command',
        '(Get-CimInstance -Class Win32_ComputerSystemProduct).UUID',
      ],
    ).timeout(const Duration(seconds: 6));
    if (result.exitCode != 0) return null;
    final raw = _normalize(result.stdout.toString());
    if (raw == null) return null;
    // Algunos OEMs reportan "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF" o
    // "00000000-..." cuando el SMBIOS no tiene UUID asignado. En ese
    // caso retornamos null para que el caller caiga al fallback.
    final lower = raw.toLowerCase();
    if (lower == 'ffffffff-ffff-ffff-ffff-ffffffffffff' ||
        lower == '00000000-0000-0000-0000-000000000000') {
      return null;
    }
    return raw;
  }

  static Future<String?> _readLinux() async {
    // /etc/machine-id es estable y único por instalación de Linux.
    // Algunos sistemas lo tienen en /var/lib/dbus/machine-id; probamos
    // ambos.
    for (final path in const [
      '/etc/machine-id',
      '/var/lib/dbus/machine-id',
    ]) {
      try {
        final file = File(path);
        if (!await file.exists()) continue;
        final raw = (await file.readAsString()).trim();
        if (raw.isEmpty) continue;
        // /etc/machine-id es 32 chars hex sin guiones; lo formateamos a
        // UUID canónico para uniformidad con macOS/Windows.
        if (raw.length == 32 &&
            RegExp(r'^[0-9a-fA-F]+$').hasMatch(raw)) {
          return '${raw.substring(0, 8)}-${raw.substring(8, 12)}-'
              '${raw.substring(12, 16)}-${raw.substring(16, 20)}-'
              '${raw.substring(20, 32)}';
        }
        return raw;
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  static String? _normalize(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return null;
    // Validación liviana: si no parece UUID descartamos.
    if (!RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
    ).hasMatch(t)) {
      return null;
    }
    return t.toLowerCase();
  }
}
