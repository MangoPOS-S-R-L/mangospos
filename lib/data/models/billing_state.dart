// PRD-Azul-Subscriptions §5.5 — Estado de billing de una suscripción.
//
// Por decisión del usuario (2026-05-26) extendimos `memberships` con columnas
// billing en vez de crear una tabla aparte. Esta clase mapea ese subconjunto
// de columnas — junto con joins de plan + último charge — en un objeto único
// que la UI consume directamente.

import 'billing_charge.dart';
import 'billing_plan.dart';

enum BillingStatus {
  trial,
  active,
  pastDue,
  suspended,
  cancelled,
  unknown;

  static BillingStatus fromWire(String? s) {
    switch (s) {
      case 'trial':
        return BillingStatus.trial;
      case 'active':
        return BillingStatus.active;
      case 'past_due':
        return BillingStatus.pastDue;
      case 'suspended':
        return BillingStatus.suspended;
      case 'cancelled':
        return BillingStatus.cancelled;
      default:
        return BillingStatus.unknown;
    }
  }

  /// Etiqueta legible para UI.
  String get label {
    switch (this) {
      case BillingStatus.trial:
        return 'Período de prueba';
      case BillingStatus.active:
        return 'Activa';
      case BillingStatus.pastDue:
        return 'Pago pendiente';
      case BillingStatus.suspended:
        return 'Suspendida';
      case BillingStatus.cancelled:
        return 'Cancelada';
      case BillingStatus.unknown:
        return '—';
    }
  }

  /// Color semántico (la UI lo mapea a su theme).
  /// info | success | warning | danger
  String get severity {
    switch (this) {
      case BillingStatus.trial:
        return 'info';
      case BillingStatus.active:
        return 'success';
      case BillingStatus.pastDue:
        return 'warning';
      case BillingStatus.suspended:
        return 'danger';
      case BillingStatus.cancelled:
        return 'danger';
      case BillingStatus.unknown:
        return 'info';
    }
  }
}

class BillingState {
  final String membershipId;
  final String businessId;
  final String userId;
  final BillingPlan? plan;
  final BillingStatus billingStatus;
  final bool isBillingAnchor;
  final DateTime? trialEndsAt;
  final DateTime? currentPeriodStart;
  final DateTime? currentPeriodEnd;
  final DateTime? nextBillingDate;
  final DateTime? consentGrantedAt;
  final int currentAttemptNumber;
  final DateTime? suspendedAt;
  final DateTime? cancelledAt;
  final String? cancellationReason;
  final BillingCharge? lastSuccessfulCharge;
  final BillingCharge? lastFailedCharge;
  final DateTime createdAt;

  /// Precio especial acordado con el cliente (centavos), el plan para el que
  /// se acordó y el último día en que aplica. Ver migración
  /// 20260915_0006_subscription_price_override.sql.
  final int? priceOverrideCents;
  final String? priceOverridePlanId;
  final DateTime? priceOverrideEndsOn;

  const BillingState({
    required this.membershipId,
    required this.businessId,
    required this.userId,
    required this.plan,
    required this.billingStatus,
    required this.isBillingAnchor,
    required this.trialEndsAt,
    required this.currentPeriodStart,
    required this.currentPeriodEnd,
    required this.nextBillingDate,
    required this.consentGrantedAt,
    required this.currentAttemptNumber,
    required this.suspendedAt,
    required this.cancelledAt,
    required this.cancellationReason,
    required this.lastSuccessfulCharge,
    required this.lastFailedCharge,
    required this.createdAt,
    this.priceOverrideCents,
    this.priceOverridePlanId,
    this.priceOverrideEndsOn,
  });

  /// Días restantes del trial (negativo si ya pasó).
  int? get trialDaysRemaining {
    final ends = trialEndsAt;
    if (ends == null) return null;
    final diff = ends.difference(DateTime.now()).inDays;
    return diff;
  }

  /// Días hasta el próximo cobro (negativo si está atrasado).
  int? get daysUntilNextBilling {
    final next = nextBillingDate;
    if (next == null) return null;
    final today = DateTime.now();
    return next.difference(DateTime(today.year, today.month, today.day)).inDays;
  }

  bool get isSuspended => billingStatus == BillingStatus.suspended;
  bool get hasAccess =>
      !isSuspended && billingStatus != BillingStatus.cancelled;

  /// Estado en el que un cobro manual ("Pagar ahora") tiene sentido — hay un
  /// período por cobrar y no está suspendida ni cancelada.
  bool get canAttemptCharge =>
      billingStatus == BillingStatus.trial ||
      billingStatus == BillingStatus.active ||
      billingStatus == BillingStatus.pastDue;

  /// Horas hasta el próximo cobro (negativo si ya está vencido). Null sin fecha.
  int? get hoursUntilNextBilling {
    final next = nextBillingDate;
    if (next == null) return null;
    return next.difference(DateTime.now()).inHours;
  }

  /// El botón "Pagar ahora" se habilita SOLO dentro de las 48 h previas a la
  /// fecha de cobro (o si ya está vencida). El cobro automático (cron) no pasa
  /// por este gate.
  bool get isWithinPayWindow {
    final h = hoursUntilNextBilling;
    return h != null && h <= 48;
  }

  /// Precio especial vigente en [on] (por defecto, la fecha del próximo cobro),
  /// ya acotado al precio de lista. `null` si no hay uno que aplique.
  ///
  /// Réplica de `subscription_price_override_cents` SOLO para mostrar. Lo que
  /// se cobra lo decide el servidor: si esta regla y la SQL divergieran, la
  /// pantalla quedaría mal pero el cobro no.
  int? priceOverrideCentsOn([DateTime? on]) {
    final cents = priceOverrideCents;
    final p = plan;
    if (cents == null || p == null) return null;
    // Amarrado al plan: si cambió de plan, el precio especial ya no corre.
    if (priceOverridePlanId != p.id) return null;

    DateTime day(DateTime d) => DateTime(d.year, d.month, d.day);
    final reference = day(on ?? nextBillingDate ?? DateTime.now());
    final ends = priceOverrideEndsOn;
    // Inclusive: si vence el mismo día del cobro, ese cobro todavía aplica.
    if (ends != null && day(ends).isBefore(reference)) return null;

    // Nunca por encima de la lista.
    return cents < p.priceCentsMonthly ? cents : p.priceCentsMonthly;
  }

  bool get hasSpecialPrice => priceOverrideCentsOn() != null;

  /// Monto mensual que se le cobra: precio especial vigente o el de lista.
  int? get effectivePriceCents =>
      priceOverrideCentsOn() ?? plan?.priceCentsMonthly;

  /// [effectivePriceCents] formateado ("RD$ 3,000.00").
  String? get formattedEffectivePrice {
    final cents = effectivePriceCents;
    if (cents == null) return null;
    return BillingPlan.formatCents(cents, plan?.currencyCode ?? 'DOP');
  }

  /// Crea desde una row de memberships joineada con plans + opcionales charges.
  /// El SELECT del repo debe traer:
  ///   id, user_id, business_id, plan_id, is_billing_anchor, billing_status,
  ///   trial_ends_at, current_period_start, current_period_end, next_billing_date,
  ///   consent_granted_at, current_attempt_number, suspended_at, cancelled_at,
  ///   cancellation_reason, created_at,
  ///   price_override_cents, price_override_plan_id, price_override_ends_on,
  ///   plan:plans(*), last_successful_charge:azul_charges_public!last_successful_charge_id(*),
  ///   last_failed_charge:azul_charges_public!last_failed_charge_id(*)
  factory BillingState.fromJson(Map<String, dynamic> json) {
    return BillingState(
      membershipId: json['id'] as String,
      userId: json['user_id'] as String,
      businessId: json['business_id'] as String,
      plan: json['plan'] != null
          ? BillingPlan.fromJson(json['plan'] as Map<String, dynamic>)
          : null,
      billingStatus: BillingStatus.fromWire(json['billing_status'] as String?),
      isBillingAnchor: (json['is_billing_anchor'] as bool?) ?? false,
      trialEndsAt: _parseTs(json['trial_ends_at']),
      currentPeriodStart: _parseDate(json['current_period_start']),
      currentPeriodEnd: _parseDate(json['current_period_end']),
      nextBillingDate: _parseDate(json['next_billing_date']),
      consentGrantedAt: _parseTs(json['consent_granted_at']),
      currentAttemptNumber:
          (json['current_attempt_number'] as num?)?.toInt() ?? 0,
      suspendedAt: _parseTs(json['suspended_at']),
      cancelledAt: _parseTs(json['cancelled_at']),
      cancellationReason: json['cancellation_reason'] as String?,
      lastSuccessfulCharge: json['last_successful_charge'] != null
          ? BillingCharge.fromJson(
              json['last_successful_charge'] as Map<String, dynamic>,
            )
          : null,
      lastFailedCharge: json['last_failed_charge'] != null
          ? BillingCharge.fromJson(
              json['last_failed_charge'] as Map<String, dynamic>,
            )
          : null,
      createdAt: DateTime.parse(json['created_at'] as String),
      priceOverrideCents: (json['price_override_cents'] as num?)?.toInt(),
      priceOverridePlanId: json['price_override_plan_id'] as String?,
      priceOverrideEndsOn: _parseDate(json['price_override_ends_on']),
    );
  }

  static DateTime? _parseTs(Object? v) {
    if (v == null) return null;
    return DateTime.tryParse(v.toString());
  }

  static DateTime? _parseDate(Object? v) {
    if (v == null) return null;
    return DateTime.tryParse(v.toString());
  }
}
