// lib/core/business/business_resolver.dart
import 'package:supabase_flutter/supabase_flutter.dart';

class BusinessResolver {
  static final _client = Supabase.instance.client;

  static String? _cached;
  static String? _activeBusinessId;

  static void setActiveBusinessId(String? businessId) {
    _activeBusinessId = businessId;
    _cached = businessId;
  }

  static Future<String> ensure(String businessId) async {
    if (businessId != 'auto') return businessId;

    if (_activeBusinessId != null && _activeBusinessId!.isNotEmpty) {
      _cached = _activeBusinessId;
      return _activeBusinessId!;
    }

    final user = _client.auth.currentUser;

    final metaBusinessId = user?.userMetadata?['business_id']?.toString();
    if (metaBusinessId != null && metaBusinessId.isNotEmpty) {
      _cached = metaBusinessId;
      return metaBusinessId;
    }

    final legacyMetaBusinessId = user?.userMetadata?['businessId']?.toString();
    if (legacyMetaBusinessId != null && legacyMetaBusinessId.isNotEmpty) {
      _cached = legacyMetaBusinessId;
      return legacyMetaBusinessId;
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
      _cached = ub['business_id'] as String;
      return _cached!;
    }

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

  static void resetCache() {
    _cached = null;
    _activeBusinessId = null;
  }
}
