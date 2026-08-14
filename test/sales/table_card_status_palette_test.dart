import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:intl/intl.dart';
import 'package:mangopos/core/theme/app_colors.dart';
import 'package:mangopos/core/utils/app_time.dart';
import 'package:mangopos/data/models/table_status.dart' as data;
import 'package:mangopos/domain/models/ventas_table.dart';
import 'package:mangopos/presentation/sales/view/theme/table_status_style.dart';
import 'package:mangopos/presentation/sales/widgets/table_card.dart';

/// Los 4 estados de la card de mesa. La tabla del diseño es la fuente:
///
///  Estado      | Barra y texto | Fondo    | Borde
///  ------------|---------------|----------|--------------------
///  Disponible  | #22C55E       | #F4FCF7  | rgba(34,197,94,.3)
///  Ocupado     | #F59E0B       | #FFFBF4  | rgba(245,158,11,.3)
///  Por Cobrar  | #3B82F6       | #F6FAFF  | rgba(59,130,246,.3)
///  Reservado   | #8B5CF6       | #FAF7FF  | rgba(139,92,246,.3)
void main() {
  group('paleta por estado', () {
    void expectPalette(
      TableStatus status, {
      required int accent,
      required int surface,
    }) {
      final p = tableStatusPalette(status);
      expect(p.accent.toARGB32(), accent, reason: '$status · barra y texto');
      expect(p.surface.toARGB32(), surface, reason: '$status · fondo');
      // El borde es el acento al 30%.
      expect(p.border.toARGB32() & 0x00FFFFFF, accent & 0x00FFFFFF,
          reason: '$status · borde = acento');
      expect((p.border.a * 100).round(), 30, reason: '$status · borde al 30%');
    }

    test('Disponible · verde sobre #F4FCF7', () {
      expectPalette(
        TableStatus.disponible,
        accent: 0xFF22C55E,
        surface: 0xFFF4FCF7,
      );
    });

    test('Ocupado · ámbar sobre #FFFBF4', () {
      expectPalette(
        TableStatus.ocupado,
        accent: 0xFFF59E0B,
        surface: 0xFFFFFBF4,
      );
    });

    test('Por Cobrar · azul sobre #F6FAFF', () {
      expectPalette(
        TableStatus.pagando,
        accent: 0xFF3B82F6,
        surface: 0xFFF6FAFF,
      );
    });

    test('Reservado · violeta sobre #FAF7FF', () {
      expectPalette(
        TableStatus.reservado,
        accent: 0xFF8B5CF6,
        surface: 0xFFFAF7FF,
      );
    });
  });

  group('etiquetas', () {
    test('cada estado se lee con el nombre del diseño', () {
      expect(TableStatus.disponible.label, 'Disponible');
      expect(TableStatus.ocupado.label, 'Ocupado');
      expect(TableStatus.pagando.label, 'Por Cobrar');
      expect(TableStatus.reservado.label, 'Reservado');
    });
  });

  group('la hora', () {
    test('es la de apertura, no los minutos que lleva abierta', () {
      final vt = ventasTableFromStatus(
        data.TableStatus(
          tableId: 't',
          zoneId: 'z',
          code: 'M2',
          sessionId: 's1',
          ordersCount: 1,
          itemsCount: 3,
          minutesOpen: 95,
          openedAt: DateTime(2026, 8, 13, 20, 15),
        ),
      );

      expect(vt.time, contains('08:15'));
      expect(vt.time, isNot('01:35')); // lo que se mostraba antes
    });

    test('sin opened_at la reconstruye desde los minutos abiertos', () {
      final vt = ventasTableFromStatus(
        data.TableStatus(
          tableId: 't',
          zoneId: 'z',
          code: 'M2',
          sessionId: 's1',
          ordersCount: 1,
          itemsCount: 3,
          minutesOpen: 30,
        ),
      );

      final esperado = DateFormat(
        'hh:mm a',
      ).format(AppTime.nowAst().subtract(const Duration(minutes: 30)));
      expect(vt.time, esperado);
    });
  });

  group('bandas del diseño', () {
    Future<void> pumpTable(WidgetTester tester, VentasTable table) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(width: 280, child: TableCard(table: table)),
              ),
            ),
          ),
        ),
      );
    }

    final divisor = find.byWidgetPredicate(
      (w) => w is Container && w.color == AppColors.cardDivider,
    );

    testWidgets('con sesión · contexto en UNA línea separada por ·', (
      tester,
    ) async {
      await pumpTable(
        tester,
        const VentasTable(
          id: 't',
          code: 'M2',
          status: TableStatus.ocupado,
          zone: 'z',
          guests: 4,
          time: '00:45',
          waiterName: 'Luis Gómez',
        ),
      );

      expect(find.text('4 · 00:45 · Luis Gómez'), findsOneWidget);
      expect(divisor, findsOneWidget);
    });

    testWidgets('disponible · sin separador y con el prompt', (tester) async {
      await pumpTable(
        tester,
        const VentasTable(
          id: 't',
          code: 'M1',
          status: TableStatus.disponible,
          zone: 'z',
        ),
      );

      expect(find.text('Toca para asignar'), findsOneWidget);
      expect(divisor, findsNothing);
    });
  });

  group('la card pinta el estado', () {
    Future<void> pump(WidgetTester tester, TableStatus status) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 280,
                  child: TableCard(
                    table: VentasTable(
                      id: 't1',
                      code: 'M1',
                      status: status,
                      zone: 'z1',
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    for (final status in TableStatus.values) {
      testWidgets('$status · fondo y borde salen de la paleta', (tester) async {
        await pump(tester, status);

        final palette = tableStatusPalette(status);
        final card = tester
            .widgetList<AnimatedContainer>(find.byType(AnimatedContainer))
            .firstWhere((c) => c.decoration is BoxDecoration);
        final decoration = card.decoration as BoxDecoration;

        expect(decoration.color, palette.surface);

        // La barra lateral sigue siendo el BorderSide izquierdo de 6px de
        // siempre — lo único que cambia es su color.
        final bar = (decoration.border as Border).left;
        expect(bar.color, palette.accent);
        expect(bar.width, 6);

        // El borde de 1px del estado se pinta por delante.
        final front = card.foregroundDecoration as BoxDecoration;
        expect((front.border as Border).top.color, palette.border);
        expect((front.border as Border).top.width, 1);

        expect(tester.takeException(), isNull);
      });
    }
  });
}
