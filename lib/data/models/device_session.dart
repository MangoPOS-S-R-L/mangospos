// Sesión abierta en un equipo del negocio (tabla `device_sessions`,
// migración 20260918_0001). La lista la arma `fn_device_sessions_list`.

/// Un equipo se considera "en línea" si reportó hace menos de esto. El ping
/// corre cada 5 min, así que 7 min deja margen para un ping atrasado sin
/// marcar como inactivo a un equipo sano.
const Duration kDeviceSessionOnlineWindow = Duration(minutes: 7);

class DeviceSession {
  final String id;
  final String deviceId;
  final String? label;
  final String? deviceName;
  final String? hostname;
  final String? platform;
  final String? osVersion;
  final String? appVersion;
  final String? userId;
  final String? userEmail;
  final String? userName;
  final String? employeeId;
  final String? employeeName;
  final DateTime? signedInAt;
  final DateTime? lastSeenAt;

  /// Segundos desde el último ping, calculados en el SERVIDOR. No se usa el
  /// reloj del equipo que mira la lista: los POS suelen tenerlo desfasado.
  final int idleSeconds;
  final DateTime? revokedAt;
  final String? revokedByName;

  const DeviceSession({
    required this.id,
    required this.deviceId,
    required this.idleSeconds,
    this.label,
    this.deviceName,
    this.hostname,
    this.platform,
    this.osVersion,
    this.appVersion,
    this.userId,
    this.userEmail,
    this.userName,
    this.employeeId,
    this.employeeName,
    this.signedInAt,
    this.lastSeenAt,
    this.revokedAt,
    this.revokedByName,
  });

  factory DeviceSession.fromMap(Map<String, dynamic> map) {
    return DeviceSession(
      id: map['id']?.toString() ?? '',
      deviceId: map['device_id']?.toString() ?? '',
      label: _text(map['label']),
      deviceName: _text(map['device_name']),
      hostname: _text(map['hostname']),
      platform: _text(map['platform']),
      osVersion: _text(map['os_version']),
      appVersion: _text(map['app_version']),
      userId: _text(map['user_id']),
      userEmail: _text(map['user_email']),
      userName: _text(map['user_name']),
      employeeId: _text(map['employee_id']),
      employeeName: _text(map['employee_name']),
      signedInAt: _date(map['signed_in_at']),
      lastSeenAt: _date(map['last_seen_at']),
      idleSeconds: (map['idle_seconds'] as num?)?.toInt() ?? 0,
      revokedAt: _date(map['revoked_at']),
      revokedByName: _text(map['revoked_by_name']),
    );
  }

  bool get isOnline =>
      idleSeconds < kDeviceSessionOnlineWindow.inSeconds;

  /// Un admin pidió cerrarla y el equipo todavía no se ha enterado.
  bool get isRevokePending => revokedAt != null;

  /// Nombre principal: la etiqueta del admin o, si no hay, el que reporta la
  /// app más el hostname cuando ayuda a distinguir ("PC · CAJA-01").
  String get displayName {
    if (label != null) return label!;
    final base = deviceName ?? 'Dispositivo';
    if (hostname != null && hostname != base) return '$base · $hostname';
    return base;
  }

  /// Quién tiene la sesión: nombre del perfil o, si no tiene, el correo.
  String get accountLabel => userName ?? userEmail ?? 'Cuenta desconocida';

  static String? _text(dynamic value) {
    if (value == null) return null;
    final s = value.toString().trim();
    return s.isEmpty ? null : s;
  }

  static DateTime? _date(dynamic value) {
    if (value == null) return null;
    if (value is DateTime) return value;
    return DateTime.tryParse(value.toString());
  }
}

/// "hace 3 min", "hace 2 h", "hace 5 días". Recibe segundos del servidor.
String formatIdle(int seconds) {
  if (seconds < 60) return 'hace un momento';
  final minutes = seconds ~/ 60;
  if (minutes < 60) return 'hace $minutes min';
  final hours = minutes ~/ 60;
  if (hours < 24) return 'hace $hours h';
  final days = hours ~/ 24;
  return days == 1 ? 'hace 1 día' : 'hace $days días';
}
