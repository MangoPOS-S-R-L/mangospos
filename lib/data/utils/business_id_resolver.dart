// lib/data/utils/business_id_resolver.dart
import 'package:mangopos/core/business/business_resolver.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<String?> resolveBusinessIdOrNull(
  SupabaseClient sb,
  String candidate,
) async {
  if (candidate != 'auto') return candidate;

  try {
    return await BusinessResolver.ensure('auto');
  } catch (_) {}

  final user = sb.auth.currentUser;
  final userId = user?.id;
  if (userId == null) return null;

  var metaBid = user?.userMetadata?['business_id'];
  if (metaBid != null && metaBid is String && metaBid.isNotEmpty) {
    return metaBid;
  }
  metaBid = user?.userMetadata?['businessId'];
  if (metaBid != null && metaBid is String && metaBid.isNotEmpty) {
    return metaBid;
  }

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

  try {
    final emp = await sb
        .from('employees')
        .select('business_id, status')
        .eq('user_id', userId)
        .limit(1)
        .maybeSingle();

    final bid = emp?['business_id'] as String?;
    if (bid != null && bid.isNotEmpty) return bid;
  } catch (_) {}

  return null;
}
