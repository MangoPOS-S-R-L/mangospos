// Snapshot inmutable de la pantalla "Mi cuenta" del propietario.
//
// Se compone de datos de varias tablas (auth.users, profiles, businesses,
// user_businesses, employees) — el [OwnerProfileRepository] los une.
//
// Vive en data/models junto al resto de modelos de UI consumidos por las
// vistas. No lleva métodos de persistencia; eso vive en el repo.

import 'package:flutter/foundation.dart';

@immutable
class OwnerProfile {
  /// `auth.users.id` del owner.
  final String userId;

  /// `employees.id` — materializado on-demand la primera vez.
  final String employeeId;

  final String businessId;
  final String businessName;

  /// Nombre completo tal como vive en `profiles.full_name`.
  final String fullName;

  /// Partes que también persistimos en `employees` (para que el resto del
  /// staff vea al owner en la pantalla de Usuarios).
  final String firstName;
  final String lastName;

  final String email;
  final String phone;

  /// PIN en texto plano. El trigger BD lo hashea a `pin_hash` cuando lo
  /// guardamos; acá lo mostramos al owner como referencia.
  final String pin;

  /// Siempre `'owner'` por construcción. Lo dejamos explícito por si en el
  /// futuro queremos reutilizar este perfil para otros roles.
  final String role;

  final DateTime? registeredAt;
  final DateTime? lastSignInAt;

  const OwnerProfile({
    required this.userId,
    required this.employeeId,
    required this.businessId,
    required this.businessName,
    required this.fullName,
    required this.firstName,
    required this.lastName,
    required this.email,
    required this.phone,
    required this.pin,
    required this.role,
    this.registeredAt,
    this.lastSignInAt,
  });

  OwnerProfile copyWith({
    String? fullName,
    String? firstName,
    String? lastName,
    String? pin,
  }) {
    return OwnerProfile(
      userId: userId,
      employeeId: employeeId,
      businessId: businessId,
      businessName: businessName,
      fullName: fullName ?? this.fullName,
      firstName: firstName ?? this.firstName,
      lastName: lastName ?? this.lastName,
      email: email,
      phone: phone,
      pin: pin ?? this.pin,
      role: role,
      registeredAt: registeredAt,
      lastSignInAt: lastSignInAt,
    );
  }
}
