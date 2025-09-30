// lib/core/business/business_resolver.dart
import 'package:supabase_flutter/supabase_flutter.dart';

class BusinessResolver {
  static final _client = Supabase.instance.client;

  static String? _cached; // cache por sesión

  /// Si [businessId] == 'auto', resuelve el UUID activo del usuario.
  /// Si viene un UUID real, lo devuelve tal cual.
  static Future<String> ensure(String businessId) async {
    if (businessId != 'auto') return businessId;
    if (_cached != null) return _cached!;

    final uid = _client.auth.currentUser?.id;
    if (uid == null) throw Exception('Sesión no iniciada');

    // 1) user_businesses
    final ub = await _client
        .from('user_businesses')
        .select('business_id')
        .eq('user_id', uid)
        .order('created_at', ascending: false)
        .limit(1)
        .maybeSingle();
    if (ub != null && ub['business_id'] != null) {
      _cached = ub['business_id'] as String;
      return _cached!;
    }

    // 2) memberships
    final mem = await _client
        .from('memberships')
        .select('business_id')
        .eq('user_id', uid)
        .order('created_at', ascending: false)
        .limit(1)
        .maybeSingle();
    if (mem != null && mem['business_id'] != null) {
      _cached = mem['business_id'] as String;
      return _cached!;
    }

    // 3) owner directo (fallback)
    final own = await _client
        .from('businesses')
        .select('id')
        .eq('owner_id', uid)
        .order('created_at', ascending: false)
        .limit(1)
        .maybeSingle();
    if (own != null && own['id'] != null) {
      _cached = own['id'] as String;
      return _cached!;
    }

    throw Exception('No tienes un negocio asignado');
  }

  /// Por si quieres recalentar/forzar refresco al hacer login/cambio de negocio.
  static void resetCache() => _cached = null;
}
