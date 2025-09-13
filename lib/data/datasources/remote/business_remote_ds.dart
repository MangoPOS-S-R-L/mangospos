// lib/data/datasources/remote/business_remote_ds.dart
import 'package:supabase_flutter/supabase_flutter.dart';

/// DataSource para operaciones de Negocio (businesses + memberships)
class BusinessRemoteDS {
  SupabaseClient get _sb => Supabase.instance.client;

  /// Crea un negocio y devuelve el `businessId`.
  ///
  /// - Genera el `business_code` en el servidor con una función simple (SQL)
  ///   o aquí mismo (ver [_genCode] si prefieres calcularlo en cliente).
  /// - Usa `select('id')` para obtener el id creado (requiere RLS/insert con retorno).
  Future<String> createBusiness({
    required String name,
    required String email,
    required String address,
    String? country,
    bool active = true,
  }) async {
    // Si tu tabla genera el ID automáticamente (uuid default), no envíes "id".
    final inserted = await _sb
        .from('businesses')
        .insert({
          'name': name,
          'email': email,
          'direccion': address,
          'country': country,
          'activo': active,
          'business_code': _genCode(), // comenta si lo generas en DB
        })
        .select('id')
        .single();

    return inserted['id'] as String;
  }

  /// Crea la membresía del usuario en el negocio (por defecto como owner).
  Future<void> addMembership({
    required String userId,
    required String businessId,
    String role = 'owner',
    String status = 'active',
  }) async {
    await _sb.from('memberships').insert({
      'user_id': userId,
      'business_id': businessId,
      'role': role,
      'status': status,
    });
  }

  /// Obtiene un negocio por ID.
  Future<Map<String, dynamic>?> getBusinessById(String businessId) async {
    final row = await _sb
        .from('businesses')
        .select()
        .eq('id', businessId)
        .maybeSingle();
    return row;
  }

  /// Lista los negocios a los que pertenece un usuario (via memberships).
  Future<List<Map<String, dynamic>>> getUserBusinesses(String userId) async {
    // Join mediante RPC o vista; aquí usamos un subquery simple.
    final memberships = await _sb
        .from('memberships')
        .select('business_id')
        .eq('user_id', userId);

    if (memberships.isEmpty) return [];

    final ids = (memberships as List)
        .map<String>((m) => m['business_id'] as String)
        .toList();

    final rows = await _sb
        .from('businesses')
        .select()
        .inFilter('id', ids);

    return (rows as List).cast<Map<String, dynamic>>();
  }

  /// Actualiza datos básicos del negocio.
  Future<void> updateBusiness({
    required String businessId,
    String? name,
    String? email,
    String? address,
    String? country,
    bool? active,
  }) async {
    final data = <String, dynamic>{};
    if (name != null) data['name'] = name;
    if (email != null) data['email'] = email;
    if (address != null) data['direccion'] = address;
    if (country != null) data['country'] = country;
    if (active != null) data['activo'] = active;

    if (data.isEmpty) return;

    await _sb.from('businesses').update(data).eq('id', businessId);
  }

  // ---------- Helpers ----------

  /// Genera un código corto tipo "NEGXXXXXX".
  /// Si prefieres generarlo en la base (recomendado), elimina este método
  /// y crea una columna con default = función SQL.
  String _genCode() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final ts = DateTime.now().millisecondsSinceEpoch % 100000;
    final buf = StringBuffer('NEG');
    for (var i = 0; i < 6; i++) {
      buf.write(chars[(ts + i * 13) % chars.length]);
    }
    return buf.toString();
  }
}
