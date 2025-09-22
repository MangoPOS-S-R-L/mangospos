// lib/data/utils/business_id_resolver.dart
import 'package:supabase_flutter/supabase_flutter.dart';

/// Si [candidate] == 'auto', intenta resolver el business_id del usuario actual.
/// Devuelve un UUID o null si no logra resolver.
Future<String?> resolveBusinessIdOrNull(
  SupabaseClient sb,
  String candidate,
) async {
  if (candidate != 'auto') return candidate;

  final userId = sb.auth.currentUser?.id;
  if (userId == null) return null;

  // 1) memberships
  try {
    final m = await sb
        .from('memberships')
        .select('business_id')
        .eq('user_id', userId)
        .order('created_at')
        .limit(1)
        .maybeSingle();
    final bid = m?['business_id'] as String?;
    if (bid != null && bid.isNotEmpty) return bid;
  } catch (_) {}

  // 2) user_businesses
  try {
    final ub = await sb
        .from('user_businesses')
        .select('business_id')
        .eq('user_id', userId)
        .order('created_at')
        .limit(1)
        .maybeSingle();
    final bid = ub?['business_id'] as String?;
    if (bid != null && bid.isNotEmpty) return bid;
  } catch (_) {}

  return null;
}
