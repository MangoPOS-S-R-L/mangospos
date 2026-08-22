// Presupuesto de los chips de la fila de proveedor.
//
// La fila mete el chip de condiciones y las etiquetas del nombre en columnas
// de ancho FIJO (152 px la de términos). La trampa está en darles un alto
// rígido: en una tablet con la escala de texto del sistema arriba, «Crédito
// 30 días» crece, no entra y Flutter pinta las franjas amarillas de desborde
// justo encima del dato que la pantalla vino a mostrar.
//
// Estas pruebas montan los chips REALES (`SupplierTermsChip`, `SupplierTag`,
// `SupplierFulfillmentBar` — que por eso viven en `widgets/` y no dentro de
// la pantalla) con la escala al doble y con etiquetas largas en poco ancho.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/theme/app_colors.dart';
import 'package:mangopos/presentation/inventory/state/supplier_overview_state.dart';
import 'package:mangopos/presentation/inventory/view/widgets/supplier_visuals.dart';

/// Ancho real de la columna de términos en `suppliers_view.dart`.
const double _kTermsColumn = 152;

Widget _host({required double width, required double scale, required Widget child}) =>
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(scale)),
        child: Scaffold(
          body: Center(child: SizedBox(width: width, child: child)),
        ),
      ),
    );

void main() {
  group('SupplierTermsChip', () {
    testWidgets('el plazo más largo entra en su columna al 100%', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          width: _kTermsColumn,
          scale: 1,
          child: Align(
            alignment: Alignment.centerLeft,
            child: SupplierTermsChip(
              terms: const SupplierTerms(
                type: SupplierTermsType.credito,
                days: 120,
                structured: true,
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Crédito 120 días'), findsOneWidget);
    });

    testWidgets('con la escala del sistema al doble crece, no desborda', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          width: _kTermsColumn,
          scale: 2,
          child: Align(
            alignment: Alignment.centerLeft,
            child: SupplierTermsChip(
              terms: const SupplierTerms(
                type: SupplierTermsType.credito,
                days: 120,
                structured: true,
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      final box = tester.getSize(find.byType(SupplierTermsChip));
      expect(box.width, lessThanOrEqualTo(_kTermsColumn));
      expect(
        box.height,
        greaterThan(kSupplierChipMinHeight),
        reason: 'el alto es mínimo, no fijo: la caja crece con el texto',
      );
    });

    testWidgets('un texto libre larguísimo se recorta, no rompe la fila', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          width: _kTermsColumn,
          scale: 1,
          child: Align(
            alignment: Alignment.centerLeft,
            child: const SupplierTermsChip(
              terms: SupplierTerms(
                freeText:
                    '50% anticipo, 25% contra entrega y el resto a 30 días '
                    'de la fecha de factura',
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(
        tester.getSize(find.byType(SupplierTermsChip)).width,
        lessThanOrEqualTo(_kTermsColumn),
      );
    });

    testWidgets(
      'un plazo deducido del texto se marca distinto de uno configurado',
      (tester) async {
        const deduced = SupplierTerms(
          type: SupplierTermsType.credito,
          days: 30,
          freeText: '30 dias',
        );
        const configured = SupplierTerms(
          type: SupplierTermsType.credito,
          days: 30,
          structured: true,
        );

        await tester.pumpWidget(
          _host(
            width: 320,
            scale: 1,
            child: const Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SupplierTermsChip(terms: deduced),
                SupplierTermsChip(terms: configured),
              ],
            ),
          ),
        );
        expect(tester.takeException(), isNull);
        // El deducido lleva el signo de pregunta; el configurado no.
        expect(find.byIcon(Icons.help_outline), findsOneWidget);
      },
    );
  });

  group('SupplierTag', () {
    testWidgets('las etiquetas del nombre no desbordan una fila estrecha', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          width: 220,
          scale: 2,
          child: Row(
            children: [
              const Flexible(
                child: Text(
                  'Distribuidora Ferretti',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 7),
              const Flexible(
                child: SupplierTag(
                  label: 'PRINCIPAL',
                  color: AppColors.primary,
                ),
              ),
              const SizedBox(width: 7),
              const Flexible(
                child: SupplierTag(
                  label: 'FALTA RNC',
                  color: AppColors.warning,
                ),
              ),
            ],
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('SupplierFulfillmentBar', () {
    test('el color respeta los cortes de 90 y 70', () {
      expect(SupplierFulfillmentBar.colorFor(94), AppColors.success);
      expect(SupplierFulfillmentBar.colorFor(90), AppColors.success);
      expect(SupplierFulfillmentBar.colorFor(72), AppColors.warning);
      expect(SupplierFulfillmentBar.colorFor(69), AppColors.destructive);
      expect(
        SupplierFulfillmentBar.colorFor(null),
        kSupplierInactive,
        reason: 'sin datos no se pinta de rojo a nadie',
      );
    });

    testWidgets('sin datos la barra queda vacía y lo dice', (tester) async {
      await tester.pumpWidget(
        _host(
          width: 132,
          scale: 2,
          child: const SupplierFulfillmentBar(
            pct: null,
            label: 'sin órdenes cerradas',
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      final bar = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(bar.value, 0);
    });
  });
}
