import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'dart:io' show Platform;

class DeviceUtils {
  static const String _deviceIdKey = 'mangopos_unique_device_id';

  /// Obtiene un ID único para el dispositivo o lo genera si no existe.
  static Future<String> getDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    String? deviceId = prefs.getString(_deviceIdKey);

    if (deviceId == null || deviceId.isEmpty) {
      deviceId = const Uuid().v4();
      await prefs.setString(_deviceIdKey, deviceId);
    }
    return deviceId;
  }

  /// Obtiene un nombre legible para el dispositivo.
  static String getDeviceName() {
    try {
      if (Platform.isAndroid) return 'Android Terminal';
      if (Platform.isIOS) return 'iOS Device';
      if (Platform.isWindows) return 'Windows Terminal';
      if (Platform.isMacOS) return 'macOS Terminal';
      if (Platform.isLinux) return 'Linux Terminal';
    } catch (_) {
      // Si falla (ej. en web sin Platform), devolvemos algo genérico
    }
    return 'Web Browser / Generic';
  }
}
