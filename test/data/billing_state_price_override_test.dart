// Precio especial de la suscripción, tal como lo ve el cliente.
//
// La regla vive en SQL (subscription_price_override_cents) y el cobro la usa
// desde ahí. Esta réplica solo pinta la pantalla, pero si diverge el cliente
// ve un monto y le cobran otro — por eso se prueba contra los mismos casos.

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/data/models/billing_plan.dart';
import 'package:mangopos/data/models/billing_state.dart';
import 'package:mangopos/data/repositories/billing_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Map<String, dynamic> _row({
  int? overrideCents,
  String? overridePlanId,
  String? endsOn,
  String planId = 'plan-pro',
  int listCents = 479900,
  String nextBilling = '2026-10-01',
}) {
  return {
    'id': 'm1',
    'user_id': 'u1',
    'business_id': 'b1',
    'plan_id': planId,
    'is_billing_anchor': true,
    'billing_status': 'active',
    'next_billing_date': nextBilling,
    'current_attempt_number': 0,
    'created_at': '2026-01-01T00:00:00Z',
    'plan': {
      'id': planId,
      'code': 'pro',
      'name': 'Pro',
      'price_cents_monthly': listCents,
      'currency_code': 'DOP',
    },
    'price_override_cents': overrideCents,
    'price_override_plan_id': overridePlanId,
    'price_override_ends_on': endsOn,
  };
}

void main() {
  group('precio especial del cliente', () {
    test('sin precio especial: paga la lista', () {
      final s = BillingState.fromJson(_row());
      expect(s.hasSpecialPrice, isFalse);
      expect(s.effectivePriceCents, 479900);
      expect(s.formattedEffectivePrice, r'RD$ 4,799.00');
    });

    test('vigente para su plan: paga el precio especial', () {
      final s = BillingState.fromJson(
        _row(overrideCents: 300000, overridePlanId: 'plan-pro'),
      );
      expect(s.hasSpecialPrice, isTrue);
      expect(s.effectivePriceCents, 300000);
      expect(s.formattedEffectivePrice, r'RD$ 3,000.00');
    });

    test('acordado para OTRO plan: no aplica', () {
      final s = BillingState.fromJson(
        _row(overrideCents: 300000, overridePlanId: 'plan-basic'),
      );
      expect(s.hasSpecialPrice, isFalse);
      expect(s.effectivePriceCents, 479900);
    });

    test('vence el día antes del cobro: ese cobro va a lista', () {
      final s = BillingState.fromJson(
        _row(
          overrideCents: 300000,
          overridePlanId: 'plan-pro',
          endsOn: '2026-09-30',
        ),
      );
      expect(s.hasSpecialPrice, isFalse);
      expect(s.effectivePriceCents, 479900);
    });

    test('vence el mismo día del cobro: todavía aplica (inclusive)', () {
      final s = BillingState.fromJson(
        _row(
          overrideCents: 300000,
          overridePlanId: 'plan-pro',
          endsOn: '2026-10-01',
        ),
      );
      expect(s.effectivePriceCents, 300000);
    });

    test('la lista bajó por debajo del acordado: paga la lista', () {
      final s = BillingState.fromJson(
        _row(
          overrideCents: 300000,
          overridePlanId: 'plan-pro',
          listCents: 250000,
        ),
      );
      expect(s.effectivePriceCents, 250000);
    });

    test('formatCents mantiene el formato del precio de lista', () {
      expect(BillingPlan.formatCents(300050, 'DOP'), r'RD$ 3,000.50');
      expect(BillingPlan.formatCents(150000, 'USD'), 'USD 1,500.00');
    });
  });

  group('preview de cambio de plan', () {
    final repo = BillingRepository(SupabaseClient('http://localhost', 'anon'));
    final pro = BillingPlan.fromJson({
      'id': 'plan-pro',
      'code': 'pro',
      'name': 'Pro',
      'price_cents_monthly': 479900,
    });
    final basic = BillingPlan.fromJson({
      'id': 'plan-basic',
      'code': 'basic',
      'name': 'Basic',
      'price_cents_monthly': 150000,
    });

    test('el crédito del plan actual usa lo que el cliente paga de verdad', () {
      // 30 días, quedan 16 (del 15 al 30).
      final today = DateTime(2026, 9, 15);
      final lista = repo.previewProration(
        currentPlan: pro,
        newPlan: basic,
        today: today,
      );
      final especial = repo.previewProration(
        currentPlan: pro,
        newPlan: basic,
        today: today,
        currentPriceCents: 300000,
      );

      // Crédito proporcional: 479900*16/30 vs 300000*16/30.
      expect(lista.adjustmentCents, 150000 * 16 ~/ 30 - 479900 * 16 ~/ 30);
      expect(especial.adjustmentCents, 150000 * 16 ~/ 30 - 300000 * 16 ~/ 30);
      expect(especial.adjustmentCents, greaterThan(lista.adjustmentCents));
    });
  });
}
