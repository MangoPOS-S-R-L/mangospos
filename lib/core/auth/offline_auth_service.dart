import 'dart:async';
import 'dart:convert';

import 'package:bcrypt/bcrypt.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../network/connectivity_service.dart';
import '../offline/business_settings_offline_cache.dart';
import '../offline/hub/hub_client.dart';
import '../offline/hub/hub_config.dart';
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
    this.firstName,
    this.lastName,
  });

  final String userId;
  final String? employeeId;
  final String name;
  final String? email;
  final String? pinHash;
  final String role;
  final List<String> permissions;
  final bool isActive;
  final String? firstName;
  final String? lastName;

  factory OfflineRosterUser.fromJson(Map<String, dynamic> json) {
    final rawPerms = json['permissions'];
    final permissions = rawPerms is List
        ? rawPerms
              .map((p) => p?.toString() ?? '')
              .where((p) => p.isNotEmpty)
              .toList()
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
      firstName: json['first_name']?.toString(),
      lastName: json['last_name']?.toString(),
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
    'first_name': firstName,
    'last_name': lastName,
  };
}

/// Excepción cuando el roster no se puede sincronizar.
class OfflineRosterSyncException implements Exception {
  OfflineRosterSyncException(this.message);
  final String message;
  @override
  String toString() => 'OfflineRosterSyncException: $message';
}

/// Downloads business PIN hashes through the authenticated session or LAN Hub,
/// keeps an encrypted snapshot and verifies PINs without WAN. Manual binding
/// is supported for legacy servers, but is not required by the new RPC.
class OfflineAuthService {
  OfflineAuthService._();

  @visibleForTesting
  OfflineAuthService.forTesting({
    required Future<Map<String, dynamic>> Function(String) cloudRoster,
    required Future<Map<String, dynamic>?> Function(String) lanRoster,
    required bool Function() isOnline,
  }) : _cloudRoster = cloudRoster,
       _lanRoster = lanRoster,
       _isOnline = isOnline;

  Future<Map<String, dynamic>> Function(String)? _cloudRoster;
  Future<Map<String, dynamic>?> Function(String)? _lanRoster;
  bool Function()? _isOnline;
  final Map<String, Future<List<OfflineRosterUser>>> _syncing = {};
  final Map<String, DateTime> _lastPinRefresh = {};

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
      params: {'p_business_id': businessId, 'p_device_name': deviceName},
    );

    if (response is! Map) {
      throw OfflineRosterSyncException(
        'fn_device_bind no devolvió un payload válido',
      );
    }

    final token = response['device_token']?.toString();
    final deviceId = response['device_id']?.toString();
    if (token == null || token.isEmpty || deviceId == null) {
      throw OfflineRosterSyncException('fn_device_bind devolvió token vacío');
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

  /// LAN first, then the authenticated business session. Device binding is
  /// retained only as compatibility with servers missing the new RPC.
  Future<List<OfflineRosterUser>> syncRoster({String? businessId}) async {
    final storage = await StorageService.getInstance();
    final bid =
        businessId ??
        _backgroundSyncBusinessId ??
        await storage.read(StorageKeys.activeBusinessId) ??
        await currentBoundBusinessId();
    if (bid == null || bid.isEmpty) {
      throw OfflineRosterSyncException('No hay un negocio activo.');
    }
    final pending = _syncing[bid];
    if (pending != null) return pending;
    final future = _syncBusinessRoster(bid);
    _syncing[bid] = future;
    try {
      return await future;
    } finally {
      _syncing.remove(bid);
    }
  }

  Future<Map<String, dynamic>?> _downloadLanRoster(String businessId) async {
    final injected = _lanRoster;
    if (injected != null) return injected(businessId);
    final config = HubConfigService();
    if (await config.getDeviceRole(businessId) == HubDeviceRole.hub) {
      return null;
    }
    final settings = await BusinessSettingsOfflineCache().loadRow(businessId);
    final configured = await config.getHubUrl(businessId);
    if (settings?['network_mode'] != 'hub' && configured == null) return null;
    final hub = HubClient();
    try {
      final url = await hub.findReachableHub(
        businessId: businessId,
        configuredUrl: configured,
      );
      if (url == null) return null;
      return await hub.getRoster(url, businessId: businessId);
    } finally {
      hub.dispose();
    }
  }

  Future<Map<String, dynamic>> _downloadCloudRoster(String businessId) async {
    final injected = _cloudRoster;
    if (injected != null) return injected(businessId);
    final client = Supabase.instance.client;
    if (client.auth.currentSession != null) {
      try {
        final response = await client
            .rpc(
              'fn_sync_business_roster',
              params: {'p_business_id': businessId},
            )
            .timeout(const Duration(seconds: 8));
        if (response is! Map) {
          throw OfflineRosterSyncException('Respuesta de permisos inválida.');
        }
        return Map<String, dynamic>.from(response);
      } on PostgrestException catch (e) {
        // A denied session must not bypass authorization with a device token.
        if (e.code != 'PGRST202' && e.code != '42883') rethrow;
      }
    }
    final token = await _safeRead(_kDeviceTokenKey);
    if (token == null ||
        token.isEmpty ||
        await currentBoundBusinessId() != businessId) {
      throw OfflineRosterSyncException(
        'Actualiza el servidor para sincronizar PIN sin vinculación.',
      );
    }
    final response = await client
        .rpc('fn_sync_roster', params: {'p_device_token': token})
        .timeout(const Duration(seconds: 8));
    if (response is! Map) {
      throw OfflineRosterSyncException('Respuesta de permisos inválida.');
    }
    return Map<String, dynamic>.from(response);
  }

  Future<List<OfflineRosterUser>> _syncBusinessRoster(String businessId) async {
    try {
      final lan = await _downloadLanRoster(businessId);
      if (lan != null) return await _storeRoster(businessId, lan);
    } catch (e) {
      debugPrint('[OfflineAuth] No se pudo actualizar por intranet: $e');
    }
    if (!(_isOnline?.call() ?? ConnectivityService().isConnected)) {
      throw OfflineRosterSyncException(
        'No hay permisos actualizados en la intranet.',
      );
    }
    return _storeRoster(businessId, await _downloadCloudRoster(businessId));
  }

  Future<List<OfflineRosterUser>> _storeRoster(
    String businessId,
    Map<String, dynamic> response,
  ) async {
    if (response['business_id'] != businessId) {
      throw OfflineRosterSyncException(
        'Los permisos pertenecen a otro negocio.',
      );
    }
    final syncedAt = DateTime.tryParse(response['synced_at']?.toString() ?? '');
    final now = DateTime.now().toUtc();
    if (syncedAt == null ||
        now.difference(syncedAt) > rosterTtl ||
        syncedAt.isAfter(now.add(const Duration(minutes: 5)))) {
      throw OfflineRosterSyncException(
        'Los permisos recibidos están vencidos.',
      );
    }
    final rawList = response['roster'];
    if (rawList is! List || rawList.any((row) => row is! Map)) {
      throw OfflineRosterSyncException(
        'fn_sync_roster devolvió roster no-lista',
      );
    }

    final users = rawList
        .whereType<Map>()
        .map(
          (row) => OfflineRosterUser.fromJson(Map<String, dynamic>.from(row)),
        )
        .toList(growable: false);

    final existing = await rosterSyncedAt(businessId);
    if (existing != null && existing.isAfter(syncedAt)) {
      return cachedRoster(businessId);
    }
    // One encrypted write keeps the roster and its original freshness atomic.
    // A LAN copy must never renew the cloud timestamp of revoked permissions.
    final storage = await StorageService.getInstance();
    final serialized = users.map((u) => u.toJson()).toList(growable: false);
    final saved = await storage.write(
      _rosterKey(businessId),
      await SecureBlobCipher.instance.seal(
        jsonEncode({
          'business_id': businessId,
          'synced_at': syncedAt.toUtc().toIso8601String(),
          'roster': serialized,
        }),
      ),
    );
    if (!saved) {
      throw OfflineRosterSyncException('No se pudieron guardar los PIN.');
    }
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
      if (decoded is Map && decoded['business_id'] != businessId) return const [];
      final rows = decoded is Map ? decoded['roster'] : decoded;
      if (rows is! List) return const [];
      return rows
          .whereType<Map>()
          .map(
            (row) => OfflineRosterUser.fromJson(Map<String, dynamic>.from(row)),
          )
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
    final snapshot = await cachedRosterPayload(businessId);
    if (snapshot != null) {
      return DateTime.tryParse(snapshot['synced_at']?.toString() ?? '');
    }
    final raw = await storage.read(_rosterSyncedAtKey(businessId));
    if (raw == null || raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }

  /// Export only the cached snapshot; serving LAN requests never needs WAN.
  Future<Map<String, dynamic>?> cachedRosterPayload(String businessId) async {
    final storage = await StorageService.getInstance();
    final raw = await storage.read(_rosterKey(businessId));
    if (raw == null) return null;
    try {
      final plain = await SecureBlobCipher.instance.open(raw);
      if (plain == null) return null;
      final decoded = jsonDecode(plain);
      if (decoded is Map) {
        if (decoded['business_id'] != businessId ||
            decoded['roster'] is! List) {
          return null;
        }
        return Map<String, dynamic>.from(decoded);
      }
      if (decoded is! List) return null;
      final syncedAt = await storage.read(_rosterSyncedAtKey(businessId));
      return {
        'business_id': businessId,
        'synced_at': syncedAt,
        'roster': decoded,
      };
    } catch (_) {
      return null;
    }
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
  /// Expired permissions trigger a bounded refresh through LAN/cloud. If no
  /// fresh snapshot is available, hashes are not checked and access is denied.
  ///
  /// Bcrypt runs in an isolate on native platforms to keep the UI responsive.
  Future<OfflineRosterUser?> verifyPin({
    required String businessId,
    required String pin,
  }) async {
    final normalized = pin.trim();
    if (normalized.isEmpty || businessId.isEmpty) return null;
    if (await isRosterStale(businessId)) {
      await _refreshForPin(businessId);
      if (await isRosterStale(businessId)) return null;
    }
    Future<OfflineRosterUser?> match() async {
      final roster = await cachedRoster(businessId);
      final index = await compute(_matchRosterPin, (
        pin: normalized,
        users: roster.map((u) => u.toJson()).toList(),
      ));
      return index == null ? null : roster[index];
    }

    final local = await match();
    if (local != null) return local;
    // A recently changed PIN should not wait for the periodic refresh.
    if (await _refreshForPin(businessId)) return match();
    return null;
  }

  Future<bool> _refreshForPin(String businessId) async {
    final now = DateTime.now();
    final last = _lastPinRefresh[businessId];
    if (last != null && now.difference(last) < const Duration(seconds: 15)) {
      return false;
    }
    _lastPinRefresh[businessId] = now;
    try {
      await syncRoster(businessId: businessId);
      return true;
    } catch (_) {
      return false;
    }
  }

  // ─────────────────────────────────────────────────────────────────────
  // Background sync: login, business changes, connectivity changes and timer.
  // ─────────────────────────────────────────────────────────────────────

  Timer? _periodicSyncTimer;
  StreamSubscription<bool>? _connectivitySub;
  String? _backgroundSyncBusinessId;

  /// Bounds propagation delay for PIN and permission changes.
  static const Duration _periodicSyncInterval = Duration(minutes: 1);

  /// Starts one timer per active business. WAN loss also triggers a refresh:
  /// the LAN can still be available. Concurrent downloads are deduplicated.
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
    _connectivitySub = ConnectivityService().connectionStream.listen((
      connected,
    ) async {
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
      final businessId = _backgroundSyncBusinessId;
      if (businessId == null) return;
      await syncRoster(businessId: businessId);
    } catch (e) {
      debugPrint('OfflineAuthService: background sync falló: $e');
    }
  }
}

int? _matchRosterPin(({String pin, List<Map<String, dynamic>> users}) input) {
  for (var i = 0; i < input.users.length; i++) {
    final user = input.users[i];
    final hash = user['pin_hash'] as String?;
    if (user['is_active'] != true || hash == null || hash.isEmpty) continue;
    try {
      if (BCrypt.checkpw(input.pin, hash)) return i;
    } catch (_) {
      // A malformed hash must not disable the other employees' PINs.
    }
  }
  return null;
}
