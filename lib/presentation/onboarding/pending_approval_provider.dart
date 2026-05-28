// Provider que lee el status del business activo desde la tabla
// `businesses`. Lo usa PendingApprovalGuard para decidir si bloquea o
// no el shell. Se invalida automáticamente al cambiar de business
// (key = businessId) y `autoDispose` libera la subscripción cuando el
// guard sale del árbol.
//
// Devolvemos el string crudo ('pending' | 'active' | 'inactive') para
// no acoplar a un enum local — la fuente de verdad es la BD.
// Migration: 20260527_0005_businesses_status_pending.sql.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final businessStatusProvider =
    FutureProvider.autoDispose.family<String?, String>((ref, businessId) async {
  final res = await Supabase.instance.client
      .from('businesses')
      .select('status')
      .eq('id', businessId)
      .maybeSingle();
  if (res == null) return null;
  return res['status'] as String?;
});
