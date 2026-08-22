// Presupuesto de la tira de chips de la tarjeta de bodega.
//
// La tarjeta reserva un alto para los chips de estado ("1 bajo mínimo",
// "2 por recibir") para que las tarjetas de una misma fila queden parejas.
// La trampa está en reservarlo con una caja RÍGIDA: en una tablet con la
// escala de texto del sistema arriba, la etiqueta crece, no entra y Flutter
// pinta las franjas amarillas de desborde.
//
// Estas pruebas montan el chip REAL (`WarehouseFlag`, que por eso vive en
// `widgets/` y no dentro de la pantalla) con la escala al doble y con una
// etiqueta larga en poco ancho.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/theme/app_colors.dart';
import 'package:mangopos/presentation/inventory/view/widgets/warehouse_visuals.dart';

Widget _host({required double width, required double scale}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(scale)),
    child: Scaffold(
      body: Center(
        child: SizedBox(
          width: width,
          // Igual que la tarjeta: alto MÍNIMO, no fijo.
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: kWarehouseFlagMinHeight,
            ),
            child: Row(
              children: const [
                Flexible(
                  child: WarehouseFlag(
                    icon: Icons.warning_amber_rounded,
                    label: '3 bajo mínimo',
                    color: AppColors.warning,
                  ),
                ),
                SizedBox(width: 6),
                Flexible(
                  child: WarehouseFlag(
                    icon: Icons.schedule,
                    label: 'Sin contar 47 días',
                    color: AppColors.mutedForeground,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('dos chips no desbordan en una tarjeta angosta', (tester) async {
    await tester.pumpWidget(_host(width: 260, scale: 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('con la escala de texto al doble tampoco desborda', (
    tester,
  ) async {
    await tester.pumpWidget(_host(width: 260, scale: 2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('el chip crece de alto en vez de recortar el texto', (
    tester,
  ) async {
    await tester.pumpWidget(_host(width: 320, scale: 1));
    final normal = tester
        .getSize(find.byType(WarehouseFlag).first)
        .height;
    expect(normal, greaterThanOrEqualTo(kWarehouseFlagMinHeight));

    await tester.pumpWidget(_host(width: 320, scale: 2));
    final scaled = tester.getSize(find.byType(WarehouseFlag).first).height;
    expect(
      scaled,
      greaterThan(normal),
      reason: 'con la caja rígida el alto no cambiaba y el texto se recortaba',
    );
    expect(tester.takeException(), isNull);
  });
}
