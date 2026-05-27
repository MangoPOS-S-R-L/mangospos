// Mi cuenta (perfil del propietario) — getOrCreate + actualizaciones.
//
// Los propietarios viven en `auth.users` + `user_businesses(role='owner')`,
// pero NO siempre tienen registro en `employees` (la tabla que guarda el PIN
// para login offline). Este repo materializa ese registro on-demand cuando
// el owner abre por primera vez "Mi cuenta", sin asustarlo con un wizard.
//
// Datos que arma el [OwnerProfile]:
//   - identidad básica (nombre, email)              ← profiles + auth.users
//   - PIN actual visible (texto plano)              ← employees.pin
//   - rol y nombre del negocio activo               ← user_businesses + businesses
//   - fechas de registro y último login             ← auth.users
//
// Cambios soportados:
//   - PIN: 4 dígitos; el trigger `tr_employees_hash_pin` re-hashea pin_hash.
//   - Nombre completo: actualiza `profiles.full_name` + employees.first/last.

import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/owner_profile.dart';

final ownerProfileRepositoryProvider = Provider<OwnerProfileRepository>(
  (ref) => OwnerProfileRepository(),
);

class OwnerProfileRepository {
  final SupabaseClient _client;

  OwnerProfileRepository({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  /// Carga el perfil del owner. Si todavía no tiene registro en `employees`,
  /// lo crea con un PIN inicial random de 4 dígitos. Idempotente: llamados
  /// sucesivos devuelven el mismo registro.
  Future<OwnerProfile> getOrCreateOwnerProfile({
    required String userId,
    required String businessId,
  }) async {
    // 1. Auth user (email, last_sign_in, created_at)
    final authUser = _client.auth.currentUser;
    final email = authUser?.email ?? '';
    final lastSignInAt = _parseDate(authUser?.lastSignInAt);
    final authCreatedAt = _parseDate(authUser?.createdAt);

    // 2. Profile (full_name) — puede no existir, lo tratamos como opcional.
    final profileRow = await _client
        .from('profiles')
        .select('full_name, created_at')
        .eq('id', userId)
        .maybeSingle();
    final fullName =
        (profileRow?['full_name'] as String?)?.trim() ?? _defaultName(email);
    final profileCreatedAt = _parseDate(profileRow?['created_at'] as String?);
    final registeredAt = profileCreatedAt ?? authCreatedAt;

    // 3. Business name
    final businessRow = await _client
        .from('businesses')
        .select('business_name')
        .eq('id', businessId)
        .maybeSingle();
    final businessName =
        (businessRow?['business_name'] as String?)?.trim() ?? 'Tu negocio';

    // 4. Employee row (PIN). Filtramos por user_id + business_id. Puede no
    //    existir todavía si es la primera visita del owner a Mi cuenta.
    final employeeRow = await _client
        .from('employees')
        .select('id, first_name, last_name, phone, pin')
        .eq('user_id', userId)
        .eq('business_id', businessId)
        .maybeSingle();

    String employeeId;
    String pin;
    String firstName;
    String lastName;
    String phone;
    if (employeeRow == null) {
      // Materializar registro on-demand.
      pin = _generateRandomPin();
      final split = _splitFullName(fullName);
      firstName = split.$1;
      lastName = split.$2;
      phone = '';
      final inserted = await _client
          .from('employees')
          .insert({
            'business_id': businessId,
            'user_id': userId,
            'first_name': firstName,
            'last_name': lastName,
            'email': email,
            'phone': phone,
            'status': 'active',
            'pin': pin,
            'department': 'Administración',
            'position': 'Propietario',
          })
          .select('id')
          .single();
      employeeId = inserted['id'] as String;
    } else {
      employeeId = employeeRow['id'] as String;
      pin = (employeeRow['pin'] as String?)?.trim() ?? '';
      firstName = (employeeRow['first_name'] as String?) ?? '';
      lastName = (employeeRow['last_name'] as String?) ?? '';
      phone = (employeeRow['phone'] as String?) ?? '';
      // Si el employee existe pero no tiene PIN (caso edge: migrado sin valor),
      // generamos uno ahora y lo persistimos. El trigger lo hashea.
      if (pin.isEmpty) {
        pin = _generateRandomPin();
        await _client.from('employees').update({'pin': pin}).eq('id', employeeId);
      }
    }

    return OwnerProfile(
      userId: userId,
      employeeId: employeeId,
      businessId: businessId,
      businessName: businessName,
      fullName: fullName,
      firstName: firstName,
      lastName: lastName,
      email: email,
      phone: phone,
      pin: pin,
      role: 'owner',
      registeredAt: registeredAt,
      lastSignInAt: lastSignInAt,
    );
  }

  /// Actualiza el PIN. Recibe 4 dígitos numéricos exactos. El trigger
  /// `tr_employees_hash_pin` re-genera `pin_hash` automáticamente.
  Future<void> updatePin({
    required String employeeId,
    required String newPin,
  }) async {
    final trimmed = newPin.trim();
    if (!RegExp(r'^\d{4}$').hasMatch(trimmed)) {
      throw ArgumentError('El PIN debe ser exactamente 4 dígitos numéricos.');
    }
    await _client.from('employees').update({'pin': trimmed}).eq('id', employeeId);
  }

  /// Actualiza el nombre completo del owner. Sincroniza ambas fuentes:
  /// `profiles.full_name` (display único en el app) y `employees.first/last`
  /// (lo que ve el resto del staff en pantalla de usuarios).
  Future<void> updateFullName({
    required String userId,
    required String employeeId,
    required String fullName,
  }) async {
    final clean = fullName.trim();
    if (clean.isEmpty) {
      throw ArgumentError('El nombre no puede estar vacío.');
    }
    final split = _splitFullName(clean);
    await Future.wait([
      _client.from('profiles').update({'full_name': clean}).eq('id', userId),
      _client.from('employees').update({
        'first_name': split.$1,
        'last_name': split.$2,
      }).eq('id', employeeId),
    ]);
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  static String _generateRandomPin() {
    // 4 dígitos random uniformes con padding (1000–9999 excluye 0000 que
    // suele estar bloqueado por humanos como "PIN olvidado").
    final n = Random.secure().nextInt(9000) + 1000;
    return n.toString();
  }

  static String _defaultName(String email) {
    if (email.isEmpty) return 'Propietario';
    final at = email.indexOf('@');
    if (at <= 0) return 'Propietario';
    final local = email.substring(0, at);
    return local
        .replaceAll(RegExp(r'[._-]'), ' ')
        .split(' ')
        .where((s) => s.isNotEmpty)
        .map((s) => s[0].toUpperCase() + s.substring(1))
        .join(' ');
  }

  static (String, String) _splitFullName(String full) {
    final parts = full
        .trim()
        .split(RegExp(r'\s+'))
        .where((s) => s.isNotEmpty)
        .toList();
    if (parts.isEmpty) return ('Propietario', '');
    if (parts.length == 1) return (parts.first, '');
    final first = parts.first;
    final last = parts.sublist(1).join(' ');
    return (first, last);
  }

  static DateTime? _parseDate(String? iso) {
    if (iso == null || iso.isEmpty) return null;
    return DateTime.tryParse(iso)?.toLocal();
  }
}
