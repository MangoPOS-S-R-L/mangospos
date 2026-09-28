import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:supabase_flutter/supabase_flutter.dart';
import '../storage/storage_service.dart';

class BusinessResolver {
  static final _client = Supabase.instance.client;

  static String? _cached;
  static String? _activeBusinessId;

  static void setActiveBusinessId(String? businessId) {
    _activeBusinessId = businessId;
    _cached = businessId;
    if (businessId != null && businessId.isNotEmpty) {
      unawaited(_persist(businessId));
    }
  }

  /// Deja el negocio resuelto EN DISCO, no solo en memoria.
  ///
  /// Por qué importa: el agente en-proceso (`/hub/health`, `/hub/roster`,
  /// `/hub/salon`) corre fuera del árbol de widgets y resuelve el negocio
  /// leyendo ÚNICAMENTE `StorageKeys.activeBusinessId`. Ese key solo lo
  /// escribía la pantalla de "elegir negocio", que un usuario con un solo
  /// negocio nunca ve. Sin esto, un equipo configurado como Hub respondía
  /// `role: 'pos'` —porque leía negocio vacío y ni miraba el rol— y ninguna
  /// tablet lo reconocía como la caja (reportado en tablet 2026-09-28).
  ///
  /// Best-effort: si el disco falla, la resolución en memoria sigue valiendo.
  static Future<void> _persist(String businessId) async {
    if (kIsWeb) return;
    try {
      final storage = await StorageService.getInstance();
      final current = await storage.read(StorageKeys.activeBusinessId);
      if (current == businessId) return;
      await storage.write(StorageKeys.activeBusinessId, businessId);
    } catch (_) {
      // El negocio ya quedó resuelto en memoria; el disco es para el agente.
    }
  }

  /// Recuerda el negocio resuelto (memoria + disco) y lo devuelve.
  static String _remember(String businessId) {
    _cached = businessId;
    _activeBusinessId ??= businessId;
    unawaited(_persist(businessId));
    return businessId;
  }

  static Future<String> ensure(String businessId) async {
    if (businessId != 'auto') return businessId;

    if (_activeBusinessId != null && _activeBusinessId!.isNotEmpty) {
      // También se persiste acá: el negocio pudo haberse fijado en memoria en
      // un arranque anterior a este arreglo, y el agente necesita verlo en
      // disco. `_persist` no escribe si ya coincide.
      return _remember(_activeBusinessId!);
    }

    // En Windows/Native, intentar cargar del storage persistente
    if (!kIsWeb) {
      try {
        final storage = await StorageService.getInstance();
        final storedId = await storage.read(StorageKeys.activeBusinessId);
        if (storedId != null && storedId.isNotEmpty) {
          _activeBusinessId = storedId;
          _cached = storedId;
          return storedId;
        }
      } catch (e) {
        // Silenciosamente ignorar errores de storage y seguir al fallback
      }
    }

    final user = _client.auth.currentUser;

    final metaBusinessId = user?.userMetadata?['business_id']?.toString();
    if (metaBusinessId != null && metaBusinessId.isNotEmpty) {
      return _remember(metaBusinessId);
    }

    final legacyMetaBusinessId = user?.userMetadata?['businessId']?.toString();
    if (legacyMetaBusinessId != null && legacyMetaBusinessId.isNotEmpty) {
      return _remember(legacyMetaBusinessId);
    }

    if (_cached != null) return _cached!;

    final uid = user?.id;
    if (uid == null) throw Exception('Sesión no iniciada');

    final ub = await _client
        .from('user_businesses')
        .select('business_id')
        .eq('user_id', uid)
        .order('created_at', ascending: false)
        .limit(1)
        .maybeSingle();
    if (ub != null && ub['business_id'] != null) {
      return _remember(ub['business_id'] as String);
    }

    final mem = await _client
        .from('memberships')
        .select('business_id')
        .eq('user_id', uid)
        .order('created_at', ascending: false)
        .limit(1)
        .maybeSingle();
    if (mem != null && mem['business_id'] != null) {
      return _remember(mem['business_id'] as String);
    }

    final own = await _client
        .from('businesses')
        .select('id')
        .eq('owner_id', uid)
        .order('created_at', ascending: false)
        .limit(1)
        .maybeSingle();
    if (own != null && own['id'] != null) {
      return _remember(own['id'] as String);
    }

    throw Exception('No tienes un negocio asignado');
  }

  static void resetCache() {
    _cached = null;
    _activeBusinessId = null;
  }
}
