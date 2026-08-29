// Repositorio del bloqueo del POS por falta de pago.
//
// Fuente de verdad: RPC `get_my_business_access(business_id)` (migración
// 20260825_0001). Este repo NO decide nada — solo trae el veredicto del
// servidor, lo cachea, y decide qué hacer cuando no hay servidor.
//
// POLÍTICA OFFLINE (decisión de producto 2026-08-25):
//   1. Con conexión → el estado fresco manda y se guarda snapshot.
//   2. Sin conexión y CON snapshot → vale el último estado conocido. Si el
//      snapshot es más viejo que `offline_max_days`, se bloquea por falta de
//      verificación (si no, desconectar el WiFi sería la vía de escape).
//   3. Sin conexión y SIN snapshot → NO se bloquea. Nunca le cortamos el POS
//      a alguien de quien no sabemos nada; un cajero no puede quedar varado
//      por un fallo nuestro.
//
// El snapshot va por `sealDurable`: cifrado cuando el Keychain está
// disponible, texto plano cuando no. Perder el snapshot es peor que guardarlo
// sin cifrar — un snapshot ilegible degrada al caso 3 (no bloquea).

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/security/secure_blob_cipher.dart';
import '../models/account_access_state.dart';

final accountAccessRepositoryProvider = Provider<AccountAccessRepository>(
  (ref) => AccountAccessRepository(Supabase.instance.client),
);

class AccountAccessRepository {
  final SupabaseClient _client;

  AccountAccessRepository(this._client);

  static const String _cachePrefix = 'mp_access_state_v1_';

  String _cacheKey(String businessId) => '$_cachePrefix$businessId';

  // ---------------------------------------------------------------------------
  // Lectura
  // ---------------------------------------------------------------------------

  /// Estado fresco desde el servidor. Lanza si no hay red o el RPC falla.
  Future<AccountAccessState?> fetchFromServer(String businessId) async {
    final res = await _client.rpc(
      'get_my_business_access',
      params: {'p_business_id': businessId},
    );
    if (res == null) return null;
    if (res is! Map) return null;
    return AccountAccessState.fromRpc(Map<String, dynamic>.from(res));
  }

  /// Estado a usar: intenta el servidor y cae al snapshot local si falla.
  ///
  /// Nunca lanza: un fallo de red no puede tumbar el arranque del shell.
  Future<AccountAccessState> resolve(String businessId) async {
    try {
      final fresh = await fetchFromServer(businessId);
      if (fresh != null) {
        await _saveSnapshot(fresh);
        return fresh;
      }
      // El negocio no existe o no tiene estado — no restringimos.
      await clearSnapshot(businessId);
      return AccountAccessState.unrestricted(businessId);
    } catch (e) {
      debugPrint('[AccountAccess] RPC falló ($e), uso snapshot local.');
      return await resolveOffline(businessId);
    }
  }

  /// Resuelve solo con lo que hay en el dispositivo. Público para poder
  /// ejercitarlo en tests y para el arranque en frío sin red.
  Future<AccountAccessState> resolveOffline(String businessId) async {
    final cached = await readSnapshot(businessId);
    if (cached == null) {
      // Caso 3: no sabemos nada → no bloqueamos.
      return AccountAccessState.unrestricted(businessId);
    }
    if (cached.isStale) {
      return cached.toStale();
    }
    return cached;
  }

  // ---------------------------------------------------------------------------
  // Snapshot local
  // ---------------------------------------------------------------------------

  Future<AccountAccessState?> readSnapshot(String businessId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_cacheKey(businessId));
      if (raw == null || raw.isEmpty) return null;
      final plain = await SecureBlobCipher.instance.open(raw);
      if (plain == null || plain.isEmpty) return null;
      return AccountAccessState.fromCacheJson(plain);
    } catch (e) {
      debugPrint('[AccountAccess] snapshot ilegible: $e');
      return null;
    }
  }

  Future<void> _saveSnapshot(AccountAccessState state) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final sealed =
          await SecureBlobCipher.instance.sealDurable(state.toCacheJson());
      await prefs.setString(_cacheKey(state.businessId), sealed);
    } catch (e) {
      debugPrint('[AccountAccess] no se pudo guardar snapshot: $e');
    }
  }

  Future<void> clearSnapshot(String businessId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_cacheKey(businessId));
    } catch (_) {
      // best effort
    }
  }

  // ---------------------------------------------------------------------------
  // Observación continua
  // ---------------------------------------------------------------------------

  /// Cada cuánto volver a preguntar. Un negocio sano y sin enforcement no
  /// necesita que lo miren cada 3 minutos: son cientos de dispositivos
  /// preguntando por algo que no cambia. Cuando hay algo en juego se aprieta
  /// el paso, porque el dueño puede estar pagando ahora mismo y espera que el
  /// POS se destrabe solo.
  static Duration pollIntervalFor(AccountAccessState? state) {
    if (state == null) return const Duration(minutes: 3);
    if (!state.enforced && state.level == AccessLevel.ok) {
      return const Duration(minutes: 30);
    }
    if (state.level == AccessLevel.ok) return const Duration(minutes: 10);
    return const Duration(minutes: 2);
  }

  /// Emite el estado al arrancar y lo refresca cuando cambia algo relevante.
  ///
  /// Dos disparadores, a propósito:
  ///   * Realtime sobre `memberships` — el POS SÍ puede leer su propia
  ///     membresía, así que la suspensión automática del cron de Azul llega
  ///     al instante.
  ///   * Poll adaptativo ([pollIntervalFor]) — `business_access_control` solo
  ///     la ven los operadores (RLS), así que Realtime no sirve para los
  ///     cortes manuales del panel. El poll los recoge sin tener que abrirle
  ///     esa tabla al tenant solo para escuchar cambios.
  ///
  /// El estado siempre lo produce el RPC: los disparadores solo dicen "vuelve
  /// a preguntar".
  Stream<AccountAccessState> watch(String businessId) {
    final controller = StreamController<AccountAccessState>();
    StreamSubscription<List<Map<String, dynamic>>>? membershipSub;
    Timer? timer;
    var busy = false;

    Future<void> push() async {
      if (busy || controller.isClosed) return;
      busy = true;
      AccountAccessState? seen;
      try {
        seen = await resolve(businessId);
        if (!controller.isClosed) controller.add(seen);
      } finally {
        busy = false;
        // Se reprograma SIEMPRE, incluso si algo salió mal: si la cadena de
        // polls se corta, el POS se queda con un estado congelado para
        // siempre — que es justo lo que este módulo no puede permitirse.
        if (!controller.isClosed) {
          timer?.cancel();
          timer = Timer(pollIntervalFor(seen), push);
        }
      }
    }

    controller.onListen = () {
      push();
      try {
        membershipSub = _client
            .from('memberships')
            .stream(primaryKey: ['id'])
            .eq('business_id', businessId)
            .listen(
              (_) => push(),
              onError: (Object e) =>
                  debugPrint('[AccountAccess] realtime memberships: $e'),
            );
      } catch (e) {
        debugPrint('[AccountAccess] no se pudo abrir realtime: $e');
      }
    };

    controller.onCancel = () async {
      timer?.cancel();
      await membershipSub?.cancel();
      await controller.close();
    };

    return controller.stream;
  }
}
