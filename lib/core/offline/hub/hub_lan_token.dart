import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../data/repositories/pos_settings_repository.dart';

/// Token compartido compilado en el binario, igual para TODOS los negocios.
///
/// Se conserva solo para el rollout: mientras haya cajas con builds viejos en
/// la LAN, el Hub tiene que seguir aceptándolas o el local se parte en dos.
/// Cuando toda la flota esté actualizada, quitar este valor de la lista de
/// tokens aceptados en el agente y de aquí.
const String kLegacyHubLanToken = 'MANGOPOS_SECURE_TOKEN_123';

/// Resuelve el token LAN del negocio: el secreto por-negocio de
/// `business_settings.lan_token` (migración 20260907_0010), con caída a
/// [kLegacyHubLanToken].
///
/// Por qué existe: el agente y el cliente del Hub compartían una constante
/// compilada, la misma para todos los locales del país. Quien la extraiga del
/// binario —cualquiera— podía hablarle al Hub de cualquier negocio: leer el
/// salón y las órdenes, y sobre todo INYECTAR ops en el op-log, que el uplink
/// después sube a Supabase como ventas reales.
///
/// El token por-negocio viaja dentro de la fila de `business_settings`, que el
/// [BusinessSettingsOfflineCache] ya guarda completa, así que está disponible
/// sin red — que es exactamente cuando el Hub se usa.
///
/// **Sobre dónde queda guardado:** en claro, junto al resto de la config. No es
/// una credencial de Supabase ni da acceso a datos fuera del local: solo
/// autoriza llamadas dentro de la LAN. Quien tenga acceso al sistema de
/// archivos de una caja ya tiene un problema mayor que este token. Y cifrarlo
/// tendría el costo de que, si se pierde la clave del keychain, las cajas
/// dejarían de hablarle al Hub justo cuando no hay red para recuperarse.
class HubLanTokenService {
  /// [readToken] es la única dependencia real: leer el token de un negocio. Se
  /// inyecta como función (y no el repositorio entero) para que los tests no
  /// tengan que falsear una clase grande.
  HubLanTokenService({Future<String> Function(String businessId)? readToken})
    : _readToken = readToken;

  static final HubLanTokenService instance = HubLanTokenService();

  final Future<String> Function(String businessId)? _readToken;

  Future<String> _read(String businessId) async {
    final injected = _readToken;
    if (injected != null) return injected(businessId);
    return PosSettingsRepository(
      Supabase.instance.client,
    ).getLanToken(businessId);
  }

  /// Cache en memoria por negocio: esto se consulta en cada llamada al Hub y
  /// no tiene sentido tocar disco cada vez.
  final Map<String, String> _cache = <String, String>{};

  /// Token a usar con el Hub de [businessId]. Nunca devuelve vacío: si no hay
  /// token por-negocio, cae al legacy para no dejar al local incomunicado.
  Future<String> tokenFor(String businessId) async {
    if (businessId.isEmpty) return kLegacyHubLanToken;

    final cached = _cache[businessId];
    if (cached != null && cached.isNotEmpty) return cached;

    try {
      final token = await _read(businessId);
      if (token.isNotEmpty) {
        _cache[businessId] = token;
        return token;
      }
      debugPrint(
        '[HubLanToken] $businessId sin lan_token (¿migración 20260907_0010 '
        'sin aplicar?). Usando el token legacy compartido.',
      );
    } catch (e) {
      debugPrint('[HubLanToken] no se pudo resolver el token: $e');
    }
    return kLegacyHubLanToken;
  }

  /// ¿Es [candidate] un token válido para [businessId]?
  ///
  /// Acepta también el legacy a propósito, por el rollout. Cuando toda la
  /// flota esté al día, quitar esa rama convierte esto en autenticación real.
  Future<bool> isValid(String businessId, String candidate) async {
    if (candidate.isEmpty) return false;
    if (candidate == kLegacyHubLanToken) return true;
    final expected = await tokenFor(businessId);
    return candidate == expected;
  }

  /// Olvida lo cacheado (rotación del token, o cambio de negocio activo).
  void invalidate([String? businessId]) {
    if (businessId == null) {
      _cache.clear();
    } else {
      _cache.remove(businessId);
    }
  }
}
