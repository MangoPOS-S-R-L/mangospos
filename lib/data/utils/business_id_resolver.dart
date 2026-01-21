// lib/data/utils/business_id_resolver.dart
import 'package:supabase_flutter/supabase_flutter.dart';

/// Si [candidate] == 'auto', intenta resolver el business_id del usuario actual.
/// Devuelve un UUID o null si no logra resolver.
Future<String?> resolveBusinessIdOrNull(
  SupabaseClient sb,
  String candidate,
) async {
  if (candidate != 'auto') return candidate;

  final user = sb.auth.currentUser;
  final userId = user?.id;
  if (userId == null) return null;

  // 0) Check metadata (FASTEST)
  // Check snake_case (standard)
  var metaBid = user?.userMetadata?['business_id'];
  if (metaBid != null && metaBid is String && metaBid.isNotEmpty) {
    return metaBid;
  }
  // Check camelCase (legacy/fallback)
  metaBid = user?.userMetadata?['businessId'];
  if (metaBid != null && metaBid is String && metaBid.isNotEmpty) {
    return metaBid;
  }

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
  } catch (e) {
    print('Error resolving from memberships: $e');
  }

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
  } catch (e) {
    print('Error resolving from user_businesses: $e');
  }

  // 3) employees (Si es un empleado con login)
  try {
    print('Searching employee for user_id: $userId');
    // Intenta buscar en employees sin filtrar por status para asegurar encontrarlo si existe
    final emp = await sb
        .from('employees')
        .select('business_id, status')
        .eq('user_id', userId)
        // .eq('status', 'active') // <-- Removed strict status check
        .limit(1)
        .maybeSingle();

    print('Employee lookup result: $emp');

    final bid = emp?['business_id'] as String?;
    if (bid != null && bid.isNotEmpty) return bid;
  } catch (e) {
    print('Error resolving from employees: $e');
  }

  return null;
}
