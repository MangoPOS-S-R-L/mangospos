// Golden tests del motor de impuestos puro (`tax_engine.dart`).
//
// Capturan el comportamiento esperado del sistema **después** del PRD 1
// (Stop-the-Bleeding). Si alguno de estos tests empieza a fallar, no debe
// "ajustarse el test" sin entender la regresión: estos números son la fuente
// de verdad fiscal del sistema.
//
// No tocan Supabase ni provider tree — son puros sobre la API pública del
// motor en `lib/core/tax/tax_engine.dart`.

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/tax/tax_engine.dart';

void main() {
  group('PRD 1 — Comportamiento congelado del motor de impuestos', () {
    // ─────────────────────────────────────────────────────────────────────
    // B1: Producto inclusive con sólo ITBIS 18% (sin propina) en zone.
    // ─────────────────────────────────────────────────────────────────────
    test('B1: 750 inclusive, ITBIS 18%, zone, sin propina', () {
      // fullTaxPct = 18, effectiveTaxPct = 18, serviceFeePct = 0
      final r = calculateItemTax(
        grossAmount: 750,
        taxMode: 'inclusive',
        effectiveTaxPct: 18,
        fullTaxPct: 18,
        serviceFeePct: 0,
        isTakeout: false,
      );
      expect(r.baseAmount, closeTo(635.59, 0.01));
      expect(r.taxAmount, closeTo(114.41, 0.01));
      expect(r.serviceFee, 0.0);
      expect(r.total, closeTo(750.00, 0.01));
    });

    // ─────────────────────────────────────────────────────────────────────
    // B2: Producto inclusive con ITBIS 18% + Propina 10% en zone.
    // El precio 750 ya incluye AMBOS impuestos.
    // ─────────────────────────────────────────────────────────────────────
    test('B2: 750 inclusive, ITBIS 18% + propina 10%, zone', () {
      // fullTaxPct = 28 (todos los activos), effectiveTaxPct = 18, sf = 10
      final r = calculateItemTax(
        grossAmount: 750,
        taxMode: 'inclusive',
        effectiveTaxPct: 18,
        fullTaxPct: 28,
        serviceFeePct: 10,
        isTakeout: false,
      );
      expect(r.baseAmount, closeTo(585.94, 0.01));
      expect(r.taxAmount, closeTo(105.47, 0.01));
      expect(r.serviceFee, closeTo(58.59, 0.01));
      expect(r.total, closeTo(750.00, 0.01));
    });

    // ─────────────────────────────────────────────────────────────────────
    // B3: Mismo producto en quick (sin propina activa para ese origin).
    // serviceFeePct llega en 0 porque el resolver origin la apaga.
    // ─────────────────────────────────────────────────────────────────────
    test('B3: 750 inclusive, ITBIS 18%, quick (no propina)', () {
      final r = calculateItemTax(
        grossAmount: 750,
        taxMode: 'inclusive',
        effectiveTaxPct: 18,
        fullTaxPct: 28, // el precio se compuso con 18+10
        serviceFeePct: 0, // pero quick NO aplica propina
        isTakeout: false,
      );
      // En modo inclusive el total NO cambia (sigue siendo 750):
      // lo que cambia es que la propina pasa a base. La propina es 0
      // y la base sube respecto a B2.
      expect(r.serviceFee, 0.0);
      expect(r.taxAmount, closeTo(105.47, 0.01));
      expect(r.total, closeTo(750.00, 0.01));
      // base de B3 (sin propina, fullTaxPct=28): 750 - 105.47 = 644.53
      expect(r.baseAmount, closeTo(644.53, 0.01));
    });

    // ─────────────────────────────────────────────────────────────────────
    // B4: Sin impuestos configurados — ningún default mágico.
    // Antes del PRD 1 esto devolvía 18%/10% por hardcode.
    // ─────────────────────────────────────────────────────────────────────
    test('B4: Sin impuestos configurados, 750 inclusive', () {
      final r = calculateItemTax(
        grossAmount: 750,
        taxMode: 'inclusive',
        effectiveTaxPct: 0,
        fullTaxPct: 0,
        serviceFeePct: 0,
        isTakeout: false,
      );
      expect(r.baseAmount, closeTo(750.00, 0.01));
      expect(r.taxAmount, 0.0);
      expect(r.serviceFee, 0.0);
      expect(r.total, closeTo(750.00, 0.01));
    });

    // ─────────────────────────────────────────────────────────────────────
    // B5: Takeout siempre apaga propina aunque el origin la habilite.
    // ─────────────────────────────────────────────────────────────────────
    test('B5: Takeout no cobra propina aunque zone la habilite', () {
      final r = calculateItemTax(
        grossAmount: 750,
        taxMode: 'inclusive',
        effectiveTaxPct: 18,
        fullTaxPct: 28,
        serviceFeePct: 10,
        isTakeout: true, // takeout
      );
      expect(r.serviceFee, 0.0);
      expect(r.taxAmount, greaterThan(0));
    });

    // ─────────────────────────────────────────────────────────────────────
    // B6: Exclusive simple — impuestos se suman al base.
    // ─────────────────────────────────────────────────────────────────────
    test('B6: 100 exclusive, ITBIS 18% sin propina', () {
      final r = calculateItemTax(
        grossAmount: 100,
        taxMode: 'exclusive',
        effectiveTaxPct: 18,
        fullTaxPct: 18,
        serviceFeePct: 0,
        isTakeout: false,
      );
      expect(r.baseAmount, closeTo(100.00, 0.01));
      expect(r.taxAmount, closeTo(18.00, 0.01));
      expect(r.serviceFee, 0.0);
      expect(r.total, closeTo(118.00, 0.01));
    });
  });

  group('PRD 1 — TaxDef.effectiveIsServiceFee endurecido', () {
    test('Sólo el flag is_service_fee=true cuenta', () {
      final t = TaxDef(name: 'Cualquier nombre', rate: 10, isServiceFee: true);
      expect(t.effectiveIsServiceFee, true);
    });

    test('Tax llamado "Propina" con rate 10% pero sin flag NO es propina', () {
      // Antes del PRD 1, la heurística por nombre+tasa devolvía true.
      final t = TaxDef(name: 'Propina', rate: 10);
      expect(t.effectiveIsServiceFee, false);
    });

    test('Tax llamado "Servicio" con rate 10% pero sin flag NO es propina', () {
      final t = TaxDef(name: 'Servicio 10%', rate: 10);
      expect(t.effectiveIsServiceFee, false);
    });

    test('Tax con flag pero nombre random es propina', () {
      final t = TaxDef(name: 'XYZ', rate: 12, isServiceFee: true);
      expect(t.effectiveIsServiceFee, true);
    });
  });

  group('PRD 1 — resolveTaxRates respeta apply_on_<origin>', () {
    test('zone: ITBIS aplica, propina aplica', () {
      final taxes = [
        TaxDef(name: 'ITBIS', rate: 18),
        TaxDef(name: 'Propina', rate: 10, isServiceFee: true),
      ];
      final r = resolveTaxRates(taxes, SaleOrigin.zone);
      expect(r.effectiveTaxPct, 18);
      expect(r.serviceFeePct, 10);
      expect(r.serviceFeeActive, true);
      expect(r.fullTaxPct, 28);
    });

    test('quick: ITBIS aplica, propina apagada por flag', () {
      final taxes = [
        TaxDef(name: 'ITBIS', rate: 18),
        TaxDef(
          name: 'Propina',
          rate: 10,
          isServiceFee: true,
          applyOnQuick: false, // explícito: no aplica
        ),
      ];
      final r = resolveTaxRates(taxes, SaleOrigin.quick);
      expect(r.effectiveTaxPct, 18);
      expect(r.serviceFeeActive, false);
      expect(r.serviceFeePct, 0);
      // fullTaxPct igualmente acumula 28 — refleja cómo se compuso el precio.
      expect(r.fullTaxPct, 28);
    });

    test('Sin impuestos activos: todo en cero', () {
      final r = resolveTaxRates(const [], SaleOrigin.zone);
      expect(r.effectiveTaxPct, 0);
      expect(r.serviceFeePct, 0);
      expect(r.serviceFeeActive, false);
      expect(r.fullTaxPct, 0);
    });
  });
}
