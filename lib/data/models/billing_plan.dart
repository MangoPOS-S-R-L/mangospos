// PRD-Azul-Subscriptions §5.1 — Plan (catálogo SaaS).
//
// Mapea la tabla `public.plans` creada en la migración
// 20260526_0002_azul_subscriptions_schema.sql.
//
// Esta es la "nueva" tabla de planes — fuente de verdad para cobro Azul.
// NO confundir con `lib/core/config/plans_config.dart` que es la lista
// hardcodeada de marketing/showcase usada por `plan_management_view.dart`.

class BillingPlan {
  final String id;
  final String code;
  final String name;
  final String? description;
  final int priceCentsMonthly;
  final String currencyCode;
  final int trialDays;
  final bool isActive;
  final int displayOrder;
  final List<String> features;

  const BillingPlan({
    required this.id,
    required this.code,
    required this.name,
    required this.description,
    required this.priceCentsMonthly,
    required this.currencyCode,
    required this.trialDays,
    required this.isActive,
    required this.displayOrder,
    required this.features,
  });

  /// Precio formateado en la moneda del plan, sin centavos si son 0.
  /// Ej. priceCentsMonthly=150000, currency=DOP → "RD$ 1,500.00"
  String get formattedPrice {
    final whole = priceCentsMonthly ~/ 100;
    final cents = priceCentsMonthly % 100;
    final wholeStr = whole.toString().replaceAllMapped(
      RegExp(r'(\d)(?=(\d{3})+(?!\d))'),
      (m) => '${m[1]},',
    );
    final symbol = currencyCode == 'DOP' ? r'RD$' : currencyCode;
    return cents == 0 ? '$symbol $wholeStr.00' : '$symbol $wholeStr.${cents.toString().padLeft(2, '0')}';
  }

  factory BillingPlan.fromJson(Map<String, dynamic> json) {
    return BillingPlan(
      id: json['id'] as String,
      code: json['code'] as String,
      name: json['name'] as String,
      description: json['description'] as String?,
      priceCentsMonthly: (json['price_cents_monthly'] as num).toInt(),
      currencyCode: (json['currency_code'] as String?) ?? 'DOP',
      trialDays: (json['trial_days'] as num?)?.toInt() ?? 14,
      isActive: (json['is_active'] as bool?) ?? true,
      displayOrder: (json['display_order'] as num?)?.toInt() ?? 0,
      features: _parseFeatures(json['features']),
    );
  }

  static List<String> _parseFeatures(Object? raw) {
    if (raw is List) {
      return raw.map((e) => e.toString()).toList(growable: false);
    }
    return const [];
  }
}
