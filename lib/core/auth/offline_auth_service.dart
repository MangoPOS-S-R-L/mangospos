import 'dart:async';
import 'dart:convert';

import 'package:bcrypt/bcrypt.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../network/connectivity_service.dart';
import '../security/secure_blob_cipher.dart';
import '../storage/storage_service.dart';

/// Snapshot de un usuario autorizado al business, persistido offline.
///
/// `pinHash` es el hash bcrypt generado por `pgcrypto` server-side. El
/// cliente lo valida con `BCrypt.checkpw(plain, hash)` sin pegarle a la DB.
@immutable
class OfflineRosterUser {
  const OfflineRosterUser({
    required this.userId,
    required this.employeeId,
    required this.name,
    required this.email,
    required this.pinHash,
    required this.role,
    required this.permissions,
    required this.isActive,
  });

  final String userId;
  final String? employeeId;
  final String name;
  final String? email;
  final String? pinHash;
  final String role;
  final List<String> permissions;
  final bool isActive;

  factory OfflineRosterUser.fromJson(Map<String, dynamic> json) {
    final rawPerms = json['permissions'];
    final permissions = rawPerms is List
        ? rawPerms.map((p) => p?.toString() ?? '').where((p) => p.isNotEmpty).toList()
        : <String>[];
    return OfflineRosterUser(
      userId: json['user_id']?.toString() ?? '',
      employeeId: json['employee_id']?.toString(),
      name: json['name']?.toString() ?? '',
      email: json['email']?.toString(),
      pinHash: json['pin_hash']?.toString(),
      role: json['role']?.toString() ?? '',
      permissions: permissions,
      isActive: json['is_active'] == true,
    );
  }

  Map<String, dynamic> toJson() => {
        'user_id': userId,
        'employee_id': employeeId,
        'name': name,
        'email': email,
        'pin_hash': pinHash,
        'role': role,
        'permissions': permissions,
        'is_active': isActive,
      };
}

/// Excepción cuando el roster no se puede sincronizar.
class OfflineRosterSyncException implements Exception {
  OfflineRosterSyncException(this.message);
  final String message;
  @override
  String toString() => 'OfflineRosterSyncException: $message';
}

/// Servicio de autenticación offline nivel Toast.
///
/// Responsabilidades:
///  - Vincular el terminal al business con un `device_token` revocable
///    (`bind(businessId, deviceName)`), almacenado en flutter_secure_storage.
///  - Sincronizar el roster de usuarios autorizados desde Supabase
///    (`syncRoster()`), persistirlo en SharedPreferences (los `pin_hash`
///    ya son seguros).
///  - Validar PIN offline contra el cache (`verifyPin(pin)`).
///  - Refrescar TTL del roster y bloquear operativamente si pasó demasiado
///    tiempo sin sync (`isRosterStale`).
class OfflineAuthService {
  OfflineAuthService._();

  static final OfflineAuthService _instance = OfflineAuthService._();
  factory OfflineAuthService() => _instance;

  /// `flutter_secure_storage` con opciones por plataforma. En Android usamos
  /// EncryptedSharedPreferences; en iOS Keychain con `first_unlock_this_device`
  /// para que el roster se acceda sólo después del primer unlock.
  static const _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
    // macOS: en builds ad-hoc/dev (sin DEVELOPMENT_TEAM) el data-protection
    // keychain falla con errSecMissingEntitlement (-34018) porque el
    // access-group no tiene prefijo de Team. Usamos el keychain de archivo,
    // válido bajo App Sandbox con la identidad propia de la app. Sus prompts de
    // ACL (-128 si se cancelan) ya no tronan: las lecturas están blindadas.
    mOptions: MacOsOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
      usesDataProtectionKeychain: false,
    ),
  );

  static const _kDeviceTokenKey = 'mp_offline_device_token';
  static const _kDeviceIdKey = 'mp_offline_device_id';
  static const _kDeviceBusinessKey = 'mp_offline_device_business';

  String _rosterKey(String businessId) => 'mp_offline_roster_$businessId';
  String _rosterSyncedAtKey(String businessId) =>
      'mp_offline_roster_synced_at_$businessId';

  /// Después de este tiempo sin sincronizar el roster, los logins offline
  /// se bloquean operativamente (forzar reconexión).
  static const Duration rosterTtl = Duration(hours: 24);

  // ─────────────────────────────────────────────────────────────────────
  // Device binding
  // ─────────────────────────────────────────────────────────────────────

  /// Vincula este terminal al business. Llama a `fn_device_bind` y persiste
  /// el `device_token` plaintext en secure storage (Keychain/Keystore).
  /// Solo el owner/admin puede invocar la RPC.
  Future<void> bindDevice({
    required String businessId,
    required String deviceName,
  }) async {
    final client = Supabase.instance.client;
    final response = await client.rpc(
      'fn_device_bind',
      params: {
        'p_business_id': businessId,
        'p_device_name': deviceName,
      },
    );

    if (response is! Map) {
      throw OfflineRosterSyncException(
        'fn_device_bind no devolvió un payload válido',
      );
    }

    final token = response['device_token']?.toString();
    final deviceId = response['device_id']?.toString();
    if (token == null || token.isEmpty || deviceId == null) {
      throw OfflineRosterSyncException(
        'fn_device_bind devolvió token vacío',
      );
    }

    try {
      await _secureStorage.write(key: _kDeviceTokenKey, value: token);
      await _secureStorage.write(key: _kDeviceIdKey, value: deviceId);
      await _secureStorage.write(key: _kDeviceBusinessKey, value: businessId);
    } catch (e) {
      // No pudimos persistir el binding en el keychain (ej. macOS -128/-34018).
      // Lo reportamos con el tipo manejado por los callers en vez de propagar un
      // PlatformException crudo que tronaría el flujo de vinculación.
      throw OfflineRosterSyncException('No se pudo guardar el binding: $e');
    }
  }

  /// Borra el device_token local. NO revoca en el server (para eso usa
  /// `fn_device_revoke`). Útil al hacer factory reset del terminal.
  /// También cancela el ciclo de background sync.
  Future<void> clearDeviceBinding() async {
    stopBackgroundSync();
    await _secureStorage.delete(key: _kDeviceTokenKey);
    await _secureStorage.delete(key: _kDeviceIdKey);
    await _secureStorage.delete(key: _kDeviceBusinessKey);
  }

  /// Lee del secure storage tolerando fallos del keychain (macOS
  /// errSecUserCanceled -128 si se canceló un prompt de ACL, -34018 sin Team,
  /// o keychain bloqueado): devuelve null en vez de propagar el
  /// PlatformException y tronar el arranque/sync. No es destructivo —el ítem
  /// sigue en el keychain— así que una siguiente lectura exitosa se autorepara.
  Future<String?> _safeRead(String key) async {
    try {
      return await _secureStorage.read(key: key);
    } catch (e) {
      debugPrint('[OfflineAuth] read de "$key" falló (keychain): $e');
      return null;
    }
  }

  Future<bool> isDeviceBound() async {
    final token = await _safeRead(_kDeviceTokenKey);
    return token != null && token.isNotEmpty;
  }

  Future<String?> currentBoundBusinessId() async {
    return _safeRead(_kDeviceBusinessKey);
  }

  // ─────────────────────────────────────────────────────────────────────
  // Roster sync
  // ─────────────────────────────────────────────────────────────────────

  /// Sincroniza el roster del business actual. Requiere internet y que el
  /// terminal haya sido bindado previamente. Idempotente: re-llamarla
  /// solo refresca el cache.
  Future<List<OfflineRosterUser>> syncRoster() async {
    final token = await _safeRead(_kDeviceTokenKey);
    if (token == null || token.isEmpty) {
      throw OfflineRosterSyncException('Device no vinculado');
    }

    final client = Supabase.instance.client;
    final response = await client.rpc(
      'fn_sync_roster',
      params: {'p_device_token': token},
    );

    if (response is! Map) {
      throw OfflineRosterSyncException(
        'fn_sync_roster no devolvió un payload válido',
      );
    }

    final businessId = response['business_id']?.toString() ?? '';
    final rawList = response['roster'];
    if (rawList is! List) {
      throw OfflineRosterSyncException(
        'fn_sync_roster devolvió roster no-lista',
      );
    }

    final users = rawList
        .whereType<Map>()
        .map((row) => OfflineRosterUser.fromJson(
              Map<String, dynamic>.from(row),
            ))
        .toList(growable: false);

    // Persistir en SharedPreferences, CIFRADO en reposo: los pin_hash son
    // bcrypt (one-way), pero el roster también lleva PII (nombres, emails,
    // roles) que no debe quedar legible en disco. Ver [SecureBlobCipher].
    final storage = await StorageService.getInstance();
    final serialized = users
        .map((u) => u.toJson())
        .toList(growable: false);
    await storage.write(
      _rosterKey(businessId),
      await SecureBlobCipher.instance.seal(jsonEncode(serialized)),
    );
    await storage.write(
      _rosterSyncedAtKey(businessId),
      DateTime.now().toUtc().toIso8601String(),
    );

    return users;
  }

  /// Carga el roster cacheado para el business. Devuelve `[]` si no hay
  /// cache. No fuerza un sync online.
  Future<List<OfflineRosterUser>> cachedRoster(String businessId) async {
    final storage = await StorageService.getInstance();
    final raw = await storage.read(_rosterKey(businessId));
    if (raw == null || raw.isEmpty) return const [];

    try {
      // Descifra (tolera roster legacy en texto plano: migración perezosa).
      final plain = await SecureBlobCipher.instance.open(raw);
      if (plain == null || plain.isEmpty) return const [];
      final decoded = jsonDecode(plain);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map((row) => OfflineRosterUser.fromJson(
                Map<String, dynamic>.from(row),
              ))
          .toList(growable: false);
    } catch (e) {
      debugPrint('OfflineAuthService: roster cache corrupto: $e');
      return const [];
    }
  }

  /// Última vez que se sincronizó el roster para el business. `null` si
  /// nunca se sincronizó.
  Future<DateTime?> rosterSyncedAt(String businessId) async {
    final storage = await StorageService.getInstance();
    final raw = await storage.read(_rosterSyncedAtKey(businessId));
    if (raw == null || raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }

  /// True si el roster expiró (más de `rosterTtl` desde el último sync).
  /// El cliente puede bloquear operaciones críticas si esto es true.
  Future<bool> isRosterStale(String businessId) async {
    final syncedAt = await rosterSyncedAt(businessId);
    if (syncedAt == null) return true;
    return DateTime.now().toUtc().difference(syncedAt) > rosterTtl;
  }

  // ─────────────────────────────────────────────────────────────────────
  // Verificación de PIN offline
  // ─────────────────────────────────────────────────────────────────────

  /// Valida un PIN contra el roster cacheado del business. Retorna el
  /// usuario que matchea, o `null` si ningún hash coincide, el usuario
  /// está inactivo, o el roster venció (>24h sin sync).
  ///
  /// **Bloqueo por staleness (Fase 2.6)**: cuando el roster está stale,
  /// `verifyPin` retorna null directamente sin probar hashes. El caller
  /// cae a su fallback online; si tampoco hay internet, el login se
  /// bloquea — protección contra dispositivos olvidados con un usuario
  /// despedido aún en el cache.
  ///
  /// bcrypt es lento por diseño: ~50-100ms por verificación con cost=8.
  /// Para un roster de 20 empleados eso son ~1-2s en el peor caso (todos
  /// los hashes diferentes). Aceptable para login. Si el roster crece a
  /// >50 empleados se puede paralelizar con `Future.wait` o un isolate.
  Future<OfflineRosterUser?> verifyPin({
    required String businessId,
    required String pin,
  }) async {
    if (pin.isEmpty) return null;

    if (await isRosterStale(businessId)) {
      debugPrint(
        'OfflineAuthService: roster stale para $businessId, '
        'bloqueando verificación offline.',
      );
      return null;
    }

    final roster = await cachedRoster(businessId);
    for (final user in roster) {
      if (!user.isActive) continue;
      final hash = user.pinHash;
      if (hash == null || hash.isEmpty) continue;

      try {
        if (BCrypt.checkpw(pin, hash)) {
          return user;
        }
      } catch (e) {
        // Hash mal formado: lo saltamos sin abortar la búsqueda completa
        // (un hash corrupto no debería bloquear el login del resto).
        debugPrint(
          'OfflineAuthService: hash inválido para ${user.userId}: $e',
        );
        continue;
      }
    }
    return null;
  }

  // ─────────────────────────────────────────────────────────────────────
  // Background sync (Fase 2.6 — auto-sync al login + cada hora)
  // ─────────────────────────────────────────────────────────────────────

  Timer? _periodicSyncTimer;
  StreamSubscription<bool>? _connectivitySub;
  String? _backgroundSyncBusinessId;

  /// Cuántas veces refrescamos el roster cuando la app está activa con red.
  /// Una hora es un balance razonable entre frescura y carga al server.
  static const Duration _periodicSyncInterval = Duration(hours: 1);

  /// Inicia el ciclo de sync en background para el business dado:
  ///  1. Intenta sync inmediato (si hay red).
  ///  2. Programa un Timer.periodic de 1h mientras la app esté abierta.
  ///  3. Re-sincroniza cada vez que `ConnectivityService` reporta
  ///     reconexión (cuando volvemos online después de un periodo offline).
  ///
  /// Idempotente: re-llamar con el mismo businessId cancela y reprograma.
  /// Si se llama con un businessId distinto, también re-engancha el ciclo
  /// al nuevo negocio.
  Future<void> startBackgroundSync(String businessId) async {
    if (businessId.isEmpty) return;
    if (_backgroundSyncBusinessId == businessId &&
        _periodicSyncTimer?.isActive == true) {
      // Ya hay un ciclo corriendo para este business; solo disparamos un
      // sync inmediato por si quedó pendiente.
      unawaited(_safeSync());
      return;
    }
    stopBackgroundSync();

    _backgroundSyncBusinessId = businessId;

    // Sync inmediato; si falla por red, el listener de connectivity lo
    // reintentará al volver online.
    unawaited(_safeSync());

    _periodicSyncTimer = Timer.periodic(_periodicSyncInterval, (_) async {
      await _safeSync();
    });

    _connectivitySub?.cancel();
    _connectivitySub = ConnectivityService()
        .connectionStream
        .listen((connected) async {
      if (!connected) return;
      await _safeSync();
    });
  }

  /// Cancela el ciclo de sync. Llamar en logout / clearDeviceBinding.
  void stopBackgroundSync() {
    _periodicSyncTimer?.cancel();
    _periodicSyncTimer = null;
    _connectivitySub?.cancel();
    _connectivitySub = null;
    _backgroundSyncBusinessId = null;
  }

  Future<void> _safeSync() async {
    try {
      if (!await isDeviceBound()) return;
      if (!ConnectivityService().isConnected) return;
      await syncRoster();
    } catch (e) {
      debugPrint('OfflineAuthService: background sync falló: $e');
    }
  }
}
