// Provider que lee el status del business activo desde la tabla
// `businesses`. Lo usa PendingApprovalGuard para decidir si bloquea o
// no el shell. Se invalida automáticamente al cambiar de business
// (key = businessId) y `autoDispose` libera la subscripción cuando el
// guard sale del árbol.
//
// Devolvemos el string crudo ('pending' | 'active' | 'inactive') para
// no acoplar a un enum local — la fuente de verdad es la BD.
// Migration: 20260527_0005_businesses_status_pending.sql.

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

//
// Un fallo devuelve null (= deja pasar), igual que ya hacía la rama `error`
// del guard. No se deja que el provider lance: Riverpod reintenta solo un
// provider que falla (~10 veces con espera creciente) y mientras reintenta el
// estado es `loading`, así que el guard tapaba TODO el POS con "Preparando tu
// cuenta…" ~40 s al reiniciar la app sin internet.
final businessStatusProvider =
    FutureProvider.autoDispose.family<String?, String>((ref, businessId) async {
  try {
    final res = await Supabase.instance.client
        .from('businesses')
        .select('status')
        .eq('id', businessId)
        .maybeSingle()
        .timeout(const Duration(seconds: 6));
    if (res == null) return null;
    return res['status'] as String?;
  } catch (e) {
    debugPrint('[PendingApproval] estado del negocio no disponible: $e');
    return null;
  }
});
