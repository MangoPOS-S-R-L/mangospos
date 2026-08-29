// Estado de acceso al POS — bloqueo por falta de pago.
//
// Espejo Dart del jsonb que devuelve el RPC `get_my_business_access`
// (migración 20260825_0001). El servidor es la ÚNICA fuente de verdad: acá no
// se recalcula nada, solo se interpreta y se le da forma para la UI.
//
// El modelo es escalonado a propósito (decisión de producto 2026-08-25):
//   ok      → sin fricción
//   warning → hay algo por resolver, todavía hay tiempo → banner ámbar
//   grace   → ya venció, corre la gracia → banner rojo con regresiva
//   locked  → pantalla completa, solo pagar o contactar soporte
//
// `enforced` viene del kill switch (global o por negocio). Si es false el POS
// NO bloquea aunque el estado calculado sea 'locked' — sirve para pilotear la
// feature negocio por negocio sin arriesgar a todo el parque.

import 'dart:convert';

enum AccessLevel {
  ok,
  warning,
  grace,
  locked;

  static AccessLevel fromWire(String? s) {
    switch (s) {
      case 'warning':
        return AccessLevel.warning;
      case 'grace':
        return AccessLevel.grace;
      case 'locked':
        return AccessLevel.locked;
      default:
        return AccessLevel.ok;
    }
  }

  String get wire => name;
}

/// Por qué el negocio está en ese estado. Determina el texto que ve el dueño.
enum AccessReason {
  none,
  manualLock,
  accountInactive,
  subscriptionSuspended,
  subscriptionCancelled,
  scheduledCutoff,
  paymentOverdue,
  trialExpired,
  extensionGranted,

  /// No lo devuelve el servidor: lo produce el POS cuando lleva demasiados
  /// días sin poder verificar el estado contra el servidor.
  verificationStale;

  static AccessReason fromWire(String? s) {
    switch (s) {
      case 'manual_lock':
        return AccessReason.manualLock;
      case 'account_inactive':
        return AccessReason.accountInactive;
      case 'subscription_suspended':
        return AccessReason.subscriptionSuspended;
      case 'subscription_cancelled':
        return AccessReason.subscriptionCancelled;
      case 'scheduled_cutoff':
        return AccessReason.scheduledCutoff;
      case 'payment_overdue':
        return AccessReason.paymentOverdue;
      case 'trial_expired':
        return AccessReason.trialExpired;
      case 'extension_granted':
        return AccessReason.extensionGranted;
      case 'verification_stale':
        return AccessReason.verificationStale;
      default:
        return AccessReason.none;
    }
  }

  String get wire {
    switch (this) {
      case AccessReason.none:
        return 'none';
      case AccessReason.manualLock:
        return 'manual_lock';
      case AccessReason.accountInactive:
        return 'account_inactive';
      case AccessReason.subscriptionSuspended:
        return 'subscription_suspended';
      case AccessReason.subscriptionCancelled:
        return 'subscription_cancelled';
      case AccessReason.scheduledCutoff:
        return 'scheduled_cutoff';
      case AccessReason.paymentOverdue:
        return 'payment_overdue';
      case AccessReason.trialExpired:
        return 'trial_expired';
      case AccessReason.extensionGranted:
        return 'extension_granted';
      case AccessReason.verificationStale:
        return 'verification_stale';
    }
  }

  /// Título de la pantalla/banner. Redactado para el dueño del negocio, no
  /// para el operador: nunca menciona tablas ni estados internos.
  String get title {
    switch (this) {
      case AccessReason.manualLock:
      case AccessReason.accountInactive:
        return 'Tu cuenta está bloqueada';
      case AccessReason.subscriptionSuspended:
        return 'Tu suscripción está suspendida';
      case AccessReason.subscriptionCancelled:
        return 'Tu suscripción fue cancelada';
      case AccessReason.scheduledCutoff:
        return 'Tu servicio será suspendido';
      case AccessReason.paymentOverdue:
        return 'Tienes un pago pendiente';
      case AccessReason.trialExpired:
        return 'Tu período de prueba terminó';
      case AccessReason.extensionGranted:
        return 'Tienes una prórroga activa';
      case AccessReason.verificationStale:
        return 'No podemos verificar tu suscripción';
      case AccessReason.none:
        return 'Suscripción';
    }
  }

  /// Explicación por defecto. El operador puede reemplazarla con un mensaje
  /// propio desde el panel (`customer_message`).
  String get defaultBody {
    switch (this) {
      case AccessReason.manualLock:
      case AccessReason.accountInactive:
        return 'El acceso al sistema fue suspendido por el equipo de MangoPOS. '
            'Comunícate con nosotros para reactivarlo.';
      case AccessReason.subscriptionSuspended:
        return 'No pudimos cobrar tu mensualidad después de varios intentos. '
            'Actualiza tu método de pago para reactivar el servicio.';
      case AccessReason.subscriptionCancelled:
        return 'Tu suscripción fue cancelada. Comunícate con nosotros si '
            'quieres volver a activarla.';
      case AccessReason.scheduledCutoff:
        return 'Registra tu pago antes de la fecha indicada para no perder '
            'el acceso al sistema.';
      case AccessReason.paymentOverdue:
        return 'No pudimos cobrar tu mensualidad. Actualiza tu método de pago '
            'o paga ahora para mantener el servicio activo.';
      case AccessReason.trialExpired:
        return 'Registra un método de pago para seguir usando MangoPOS.';
      case AccessReason.extensionGranted:
        return 'Te dimos tiempo adicional para regularizar tu pago. Al vencer, '
            'el sistema se bloqueará.';
      case AccessReason.verificationStale:
        return 'Este equipo lleva varios días sin conectarse. Conéctalo a '
            'internet para verificar tu suscripción y seguir operando.';
      case AccessReason.none:
        return '';
    }
  }
}

class AccountAccessState {
  final String businessId;
  final AccessLevel level;
  final AccessReason reason;

  /// Si es false el POS no debe bloquear ni avisar (kill switch apagado).
  final bool enforced;

  final DateTime? lockedAt;

  /// Cuándo se vence el plazo: fin de gracia, fecha de corte programado o
  /// vencimiento de la prórroga, según el motivo.
  final DateTime? graceEndsAt;

  final DateTime? scheduledLockAt;
  final DateTime? overrideUntil;

  /// Mensaje escrito por el operador en el panel. Reemplaza al texto por
  /// defecto del motivo cuando está presente.
  final String? customerMessage;

  final String? contactName;
  final String? contactPhone;
  final String? contactEmail;

  /// Días que el POS puede operar sin verificar contra el servidor antes de
  /// bloquear. 0 = nunca bloquear por falta de verificación.
  final int offlineMaxDays;

  final String? planName;
  final int? amountCents;
  final String? currencyCode;
  final DateTime? nextBillingDate;
  final String? billingStatus;

  /// Reloj del SERVIDOR al calcular el estado. Null en un estado sintético.
  final DateTime? checkedAt;

  /// Reloj del DISPOSITIVO al guardar el snapshot. Es el que se usa para medir
  /// antigüedad offline (el del servidor no avanza sin conexión).
  final DateTime cachedAt;

  /// true si este estado salió del caché local y no de una llamada fresca.
  final bool fromCache;

  const AccountAccessState({
    required this.businessId,
    required this.level,
    required this.reason,
    required this.enforced,
    required this.cachedAt,
    this.lockedAt,
    this.graceEndsAt,
    this.scheduledLockAt,
    this.overrideUntil,
    this.customerMessage,
    this.contactName,
    this.contactPhone,
    this.contactEmail,
    this.offlineMaxDays = 7,
    this.planName,
    this.amountCents,
    this.currencyCode,
    this.nextBillingDate,
    this.billingStatus,
    this.checkedAt,
    this.fromCache = false,
  });

  /// Estado neutro: no bloquea ni avisa. Se usa cuando no hay negocio activo,
  /// cuando el RPC falla sin snapshot previo, o cuando el negocio no existe.
  factory AccountAccessState.unrestricted(String businessId) {
    return AccountAccessState(
      businessId: businessId,
      level: AccessLevel.ok,
      reason: AccessReason.none,
      enforced: false,
      cachedAt: DateTime.now(),
    );
  }

  /// ¿Debe bloquear la pantalla completa?
  bool get blocksApp => enforced && level == AccessLevel.locked;

  /// ¿Debe mostrar banner (sin bloquear)?
  bool get showsBanner =>
      enforced && (level == AccessLevel.warning || level == AccessLevel.grace);

  bool get isCritical => level == AccessLevel.grace || level == AccessLevel.locked;

  /// Cuerpo a mostrar: el del operador si lo escribió, si no el del motivo.
  String get body {
    final m = customerMessage?.trim();
    if (m != null && m.isNotEmpty) return m;
    return reason.defaultBody;
  }

  String get title => reason.title;

  /// Tiempo restante hasta el vencimiento (gracia/corte/prórroga). Null si no
  /// hay plazo o ya venció.
  Duration? get timeRemaining {
    final ends = graceEndsAt;
    if (ends == null) return null;
    final d = ends.difference(DateTime.now());
    return d.isNegative ? null : d;
  }

  /// Regresiva legible: "3 días", "8 horas", "45 minutos".
  String? get countdownLabel {
    final d = timeRemaining;
    if (d == null) return null;
    if (d.inDays >= 1) {
      return d.inDays == 1 ? '1 día' : '${d.inDays} días';
    }
    if (d.inHours >= 1) {
      return d.inHours == 1 ? '1 hora' : '${d.inHours} horas';
    }
    final mins = d.inMinutes < 1 ? 1 : d.inMinutes;
    return mins == 1 ? '1 minuto' : '$mins minutos';
  }

  /// Antigüedad del dato respecto al reloj del dispositivo.
  Duration get age => DateTime.now().difference(cachedAt);

  /// El snapshot está tan viejo que ya no se puede confiar en él. Solo aplica
  /// con enforcement encendido y `offlineMaxDays > 0`.
  bool get isStale {
    if (!enforced || offlineMaxDays <= 0) return false;
    return age.inDays >= offlineMaxDays;
  }

  /// Deriva el estado bloqueado por falta de verificación, conservando el
  /// contacto y el mensaje para que el dueño sepa a quién llamar.
  AccountAccessState toStale() {
    return copyWith(
      level: AccessLevel.locked,
      reason: AccessReason.verificationStale,
      customerMessage: '',
      fromCache: true,
    );
  }

  AccountAccessState copyWith({
    AccessLevel? level,
    AccessReason? reason,
    bool? enforced,
    String? customerMessage,
    bool? fromCache,
  }) {
    return AccountAccessState(
      businessId: businessId,
      level: level ?? this.level,
      reason: reason ?? this.reason,
      enforced: enforced ?? this.enforced,
      cachedAt: cachedAt,
      lockedAt: lockedAt,
      graceEndsAt: graceEndsAt,
      scheduledLockAt: scheduledLockAt,
      overrideUntil: overrideUntil,
      customerMessage: customerMessage ?? this.customerMessage,
      contactName: contactName,
      contactPhone: contactPhone,
      contactEmail: contactEmail,
      offlineMaxDays: offlineMaxDays,
      planName: planName,
      amountCents: amountCents,
      currencyCode: currencyCode,
      nextBillingDate: nextBillingDate,
      billingStatus: billingStatus,
      checkedAt: checkedAt,
      fromCache: fromCache ?? this.fromCache,
    );
  }

  // ---------------------------------------------------------------------------
  // Serialización
  // ---------------------------------------------------------------------------

  /// Desde el jsonb del RPC. `cachedAt` se estampa con el reloj local porque
  /// la antigüedad offline se mide contra el dispositivo, no contra el servidor.
  factory AccountAccessState.fromRpc(
    Map<String, dynamic> json, {
    DateTime? cachedAt,
    bool fromCache = false,
  }) {
    return AccountAccessState(
      businessId: json['business_id'] as String,
      level: AccessLevel.fromWire(json['state'] as String?),
      reason: AccessReason.fromWire(json['reason'] as String?),
      enforced: (json['enforced'] as bool?) ?? false,
      lockedAt: _ts(json['locked_at']),
      graceEndsAt: _ts(json['grace_ends_at']),
      scheduledLockAt: _ts(json['scheduled_lock_at']),
      overrideUntil: _ts(json['override_until']),
      customerMessage: json['customer_message'] as String?,
      contactName: json['contact_name'] as String?,
      contactPhone: json['contact_phone'] as String?,
      contactEmail: json['contact_email'] as String?,
      offlineMaxDays: (json['offline_max_days'] as num?)?.toInt() ?? 7,
      planName: json['plan_name'] as String?,
      amountCents: (json['amount_cents'] as num?)?.toInt(),
      currencyCode: json['currency_code'] as String?,
      nextBillingDate: _ts(json['next_billing_date']),
      billingStatus: json['billing_status'] as String?,
      checkedAt: _ts(json['checked_at']),
      cachedAt: cachedAt ?? DateTime.now(),
      fromCache: fromCache,
    );
  }

  /// Para el snapshot local. Guardamos el payload del RPC tal cual más la
  /// marca de tiempo local, así el parseo de vuelta reusa [fromRpc].
  String toCacheJson() {
    return jsonEncode({
      'cached_at': cachedAt.toIso8601String(),
      'payload': {
        'business_id': businessId,
        'state': level.wire,
        'reason': reason.wire,
        'enforced': enforced,
        'locked_at': lockedAt?.toIso8601String(),
        'grace_ends_at': graceEndsAt?.toIso8601String(),
        'scheduled_lock_at': scheduledLockAt?.toIso8601String(),
        'override_until': overrideUntil?.toIso8601String(),
        'customer_message': customerMessage,
        'contact_name': contactName,
        'contact_phone': contactPhone,
        'contact_email': contactEmail,
        'offline_max_days': offlineMaxDays,
        'plan_name': planName,
        'amount_cents': amountCents,
        'currency_code': currencyCode,
        'next_billing_date': nextBillingDate?.toIso8601String(),
        'billing_status': billingStatus,
        'checked_at': checkedAt?.toIso8601String(),
      },
    });
  }

  static AccountAccessState? fromCacheJson(String raw) {
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final payload = map['payload'] as Map<String, dynamic>?;
      if (payload == null) return null;
      final cachedAt = _ts(map['cached_at']);
      if (cachedAt == null) return null;
      return AccountAccessState.fromRpc(
        payload,
        cachedAt: cachedAt,
        fromCache: true,
      );
    } catch (_) {
      return null;
    }
  }

  static DateTime? _ts(Object? v) {
    if (v == null) return null;
    return DateTime.tryParse(v.toString())?.toLocal();
  }
}
