// Modelo de factura MODERNA (`template: 'modern'`), estilo Square.
//
// Lo que estas pruebas fijan, en orden de importancia:
//
//  1. NO PIERDE DATOS FISCALES. El modelo cambia la presentación, no el
//     contenido: NCF/e-NCF, tipo de comprobante, RNC del cliente, desglose
//     de impuestos y TOTAL tienen que seguir estando. Este es el contrato
//     que no se puede romper — una factura bonita sin NCF es una multa.
//
//  2. AJUSTA EL INTERLINEADO Y NO LA FUENTE. `ESC 3 n` recorta el aire
//     sobrante del 1/6" de fábrica. La fuente B (`ESC M 1`) se probó y se
//     revirtió: son 9x17 puntos contra 12x24 y en papel real se lee peor.
//     El ahorro de este modelo viene del layout, no de achicar la letra.
//
//  3. VUELVE A LA MÉTRICA DE FÁBRICA ANTES DEL CORTE. Con el interlineado
//     ajustado las líneas de avance previas a `GS V` miden menos y la
//     cuchilla llega a morder el pie del ticket (mismo bug que ya nos comió
//     la MESA en las comandas).
//
//  4. RESPETA EL ANCHO DE PAPEL: 48 columnas a 80mm, 32 a 58mm.

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/printing/star/esc_pos_raster_encoder.dart';
import 'package:mangopos/core/printing/star/star_print_adapter.dart';
import 'package:mangopos/data/models/business_profile.dart';
import 'package:mangopos/data/models/printing.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/services/printing/esc_pos_generator.dart';
import 'package:mangopos/services/printing/modern_invoice_layout.dart';
import 'package:mangopos/services/printing/print_ticket_service.dart';

Order _order() => Order(
  id: 'order-1234',
  sessionId: 'session-1',
  status: 'paid',
  subtotal: 1000,
  discounts: 0,
  serviceFee: 0,
  tax: 180,
  total: 1180,
  createdAt: DateTime(2026, 1, 1, 12, 0),
);

OrderItem _item({
  String name = 'Sandwich de pernil con queso y vegetales',
  double quantity = 2,
  bool isTakeout = false,
  String notes = '',
}) => OrderItem(
  id: 'item-1',
  orderId: 'order-1234',
  productName: name,
  quantity: quantity,
  unitPrice: 500,
  subtotal: 1000,
  discounts: 0,
  tax: 180,
  total: 1180,
  isTakeout: isTakeout,
  status: 'completed',
  taxMode: 'exclusive',
  taxRate: 18,
  notes: notes,
  createdAt: DateTime(2026, 1, 1, 12, 0),
  modifiers: const [
    OrderItemModifier(
      id: 'mod-1',
      itemId: 'item-1',
      name: 'Extra queso cheddar derretido',
      qty: 1,
      price: 50,
    ),
  ],
);

Payment _payment() => Payment(
  id: 'payment-1',
  businessId: 'biz-1',
  orderId: 'order-1234',
  paymentMethodId: 'cash',
  paymentMethodCode: 'cash',
  paymentMethodName: 'EFECTIVO',
  amount: 1200,
  changeAmount: 20,
  status: 'completed',
  createdAt: DateTime(2026, 1, 1, 12, 5),
);

PrintTicket _modernInvoice({
  int paperWidth = 80,
  List<OrderItem>? items,
  String? fiscalNcf = 'B0200000001',
  String? fiscalType = 'B02',
  bool isElectronicCf = false,
  String title = '*** FACTURA ***',
  List<int>? logoBytes,
}) => PrintTicketService.generateInvoice(
  order: _order(),
  items: items ?? [_item(notes: 'Sin cebolla')],
  payments: [_payment()],
  tableName: 'TERRAZA 12',
  waiterName: 'Juana',
  businessName: 'Restaurante La Esquina del Sabor',
  businessAddress: 'Calle Duarte #45, Santo Domingo Este',
  businessRnc: '130123456',
  fiscalNcf: fiscalNcf,
  fiscalType: fiscalType,
  isElectronicCf: isElectronicCf,
  customerName: 'Juan Perez',
  customerTaxId: '40212345678',
  title: title,
  template: 'modern',
  taxBreakdown: const [(label: 'ITBIS (18%)', amount: 180)],
  paperWidth: paperWidth,
  logoBytes: logoBytes,
  // El bloque `logo` viene apagado de fábrica: sin encenderlo, pasar bytes
  // de logo no imprime nada y la prueba no reproduciría el caso real.
  headerBlocks: logoBytes == null
      ? null
      : [
          const TicketBlock(key: 'logo', enabled: true),
          ...TicketBlocks.defaultHeader.where((b) => b.key != 'logo'),
        ],
);

/// Un logo diminuto emitido como `GS v 0`, igual que `raster_image_esc_pos`.
const _logoBytes = <int>[
  0x1B, 0x61, 0x01, //
  0x1D, 0x76, 0x30, 0x00, 0x01, 0x00, 0x01, 0x00, 0xFF,
  0x1B, 0x61, 0x00,
];

PrinterConfig _escPosPrinter() => PrinterConfig(
  id: 'p1',
  businessId: 'b1',
  name: 'POS-80 Caja',
  type: 'network',
  isActive: true,
  paperWidth: 80,
  connectionConfig: const {},
  createdAt: DateTime(2026, 1, 1),
);

PrintTicket _modernPrecheck({String title = 'PRECUENTA'}) =>
    PrintTicketService.generatePrecheck(
      order: _order(),
      items: [_item(notes: 'Sin cebolla')],
      tableName: 'TERRAZA 12',
      waiterName: 'Juana',
      customerName: 'Juan Perez',
      businessName: 'Restaurante La Esquina del Sabor',
      businessAddress: 'Calle Duarte #45, Santo Domingo Este',
      businessRnc: '130123456',
      title: title,
      template: 'modern',
      taxBreakdown: const [(label: 'ITBIS (18%)', amount: 180)],
    );

int _widestLine(String? rawText) => (rawText ?? '')
    .split('\n')
    .map((line) => line.trimRight().length)
    .fold<int>(0, (max, len) => len > max ? len : max);

/// ¿Aparece la secuencia [needle] dentro del stream de bytes?
bool _hasBytes(List<int> haystack, List<int> needle) {
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    var match = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        match = false;
        break;
      }
    }
    if (match) return true;
  }
  return false;
}

void main() {
  group('Datos fiscales', () {
    test('conserva NCF, tipo de comprobante, RNC del cliente e impuestos', () {
      final text = _modernInvoice().rawText ?? '';

      expect(text, contains('B0200000001'));
      expect(text, contains('NCF'));
      expect(text, contains('40212345678'));
      expect(text, contains('ITBIS (18%)'));
      expect(text, contains('TOTAL'));
      // Metadatos de la orden: siguen todos, agrupados en una línea.
      expect(text, contains('ORDER-12'));
      expect(text, contains('TERRAZA 12'));
      expect(text, contains('Juana'));
    });

    test('imprime EXACTAMENTE los mismos importes que el modelo estándar', () {
      // El modelo moderno solo cambia el dibujo: la resolución de totales,
      // el recompute de impuestos y la base por línea son el mismo código.
      // Si algún día alguien forkea esa matemática, esta prueba lo caza.
      final args = {
        'order': _order(),
        'items': [_item(notes: 'Sin cebolla')],
        'payments': [_payment()],
      };

      // Ordenados: el moderno imprime el total de la línea primero y el
      // unitario debajo (el estándar, al revés). Lo que tiene que coincidir
      // son las CIFRAS, no su orden de aparición.
      List<String> moneyOf(String template) {
        final ticket = PrintTicketService.generateInvoice(
          order: args['order'] as Order,
          items: args['items'] as List<OrderItem>,
          payments: args['payments'] as List<Payment>,
          tableName: 'TERRAZA 12',
          businessName: 'Restaurante La Esquina del Sabor',
          fiscalNcf: 'B0200000001',
          fiscalType: 'B02',
          template: template,
          taxBreakdown: const [(label: 'ITBIS (18%)', amount: 180)],
        );
        return RegExp(
            r'RD\$[\d,]+\.\d{2}',
          ).allMatches(ticket.rawText ?? '').map((m) => m.group(0)!).toList()
          ..sort();
      }

      expect(moneyOf('modern'), moneyOf('standard'));
    });

    test('e-CF usa la etiqueta e-NCF y el nombre DGII del comprobante', () {
      final text =
          _modernInvoice(
            fiscalNcf: 'E310000000123',
            fiscalType: 'E31',
            isElectronicCf: true,
          ).rawText ??
          '';

      expect(text, contains('e-NCF E310000000123'));
      expect(text, contains('Subtotal Gravado'));
      expect(text, contains('Total ITBIS'));
    });

    test('REIMPRESION no se pierde detrás del nombre del comprobante', () {
      final text = _modernInvoice(title: '*** REIMPRESION ***').rawText ?? '';

      expect(text, contains('REIMPRESION'));
      expect(text, isNot(contains('***')));
    });
  });

  group('Sale de verdad como imagen', () {
    // El modelo moderno solo se ve como se diseñó si se rasteriza. Este grupo
    // cubre la CADENA COMPLETA — plantilla → `preferRaster` → adaptador —
    // porque el eslabón que falló en campo no fue ninguno de los extremos.

    test('la plantilla moderna pide raster y el estándar no', () {
      expect(_modernInvoice().preferRaster, isTrue);
      expect(
        PrintTicketService.generateInvoice(
          order: _order(),
          items: [_item()],
          payments: [_payment()],
          tableName: 'TERRAZA 12',
          businessName: 'Restaurante La Esquina del Sabor',
        ).preferRaster,
        isFalse,
      );
    });

    test('con logo TAMBIÉN se rasteriza', () async {
      // El bug de campo: el logo va como `GS v 0` en el byte 15, el guard
      // "esto ya viene rasterizado" lo confundía con un trabajo raster y el
      // adaptador devolvía el ESC/POS intacto. Resultado en papel: la fuente
      // del firmware, justo en los negocios que tienen logo.
      final ticket = _modernInvoice(logoBytes: _logoBytes);

      final bytes = await StarPrintAdapter.adapt(
        printer: _escPosPrinter(),
        escPosData: ticket.escPosCommands,
        preferRaster: ticket.preferRaster,
      );

      expect(
        bytes,
        isNot(equals(ticket.escPosCommands)),
        reason: 'el adaptador tiene que convertirlo, no devolverlo tal cual',
      );
      expect(EscPosRasterEncoder.looksLikeEscPosRaster(bytes), isTrue);
      // Y no queda texto suelto: si quedara, lo dibujaría el firmware.
      expect(
        bytes.where((b) => b >= 0x41 && b <= 0x5A).length,
        lessThan(ticket.escPosCommands.length ~/ 20),
        reason: 'un ticket rasterizado no lleva las letras del ticket',
      );
    });

    test('un segundo paso por el adaptador ya no lo toca', () async {
      // La cola offline puede rebotar el mismo job.
      final ticket = _modernInvoice(logoBytes: _logoBytes);
      final once = await StarPrintAdapter.adapt(
        printer: _escPosPrinter(),
        escPosData: ticket.escPosCommands,
        preferRaster: true,
      );
      final twice = await StarPrintAdapter.adapt(
        printer: _escPosPrinter(),
        escPosData: once,
        preferRaster: true,
      );
      expect(twice, equals(once));
    });
  });

  group('Pre-cuenta moderna', () {
    // La pre-cuenta se rige por el MISMO ajuste que la factura. Si el negocio
    // elige "Moderna" y solo cambia la factura, el cliente ve dos diseños
    // distintos con cinco minutos de diferencia — que es justo lo que pasaba.

    test('sale con el mismo acabado que la factura', () {
      final precuenta = _modernPrecheck();
      expect(precuenta.preferRaster, isTrue);

      Set<int> interlineados(List<int> bytes) {
        final vistos = <int>{};
        for (var i = 0; i + 2 < bytes.length; i++) {
          if (bytes[i] == 0x1B && bytes[i + 1] == 0x33) vistos.add(bytes[i + 2]);
        }
        return vistos;
      }

      expect(
        interlineados(precuenta.escPosCommands),
        interlineados(_modernInvoice().escPosCommands),
      );
      // Y nunca la fuente B, igual que la factura.
      expect(_hasBytes(precuenta.escPosCommands, [0x1B, 0x4D, 0x01]), isFalse);
    });

    test('no pierde nada de lo que una pre-cuenta tiene que decir', () {
      final text = _modernPrecheck().rawText ?? '';

      // El disclaimer: sin él, un cliente puede tomarla por su factura.
      expect(text.toLowerCase(), contains('solo una precuenta'));
      // Los renglones para llenar a mano los datos fiscales.
      expect(text, contains('RNC/Cédula'));
      expect(text, contains('Razón social'));
      // Los importes y el detalle.
      expect(text, contains('TOTAL'));
      expect(text, contains('ITBIS (18%)'));
      expect(text, contains('TERRAZA 12'));
      // Y NUNCA un comprobante fiscal: todavía no existe.
      expect(text, isNot(contains('NCF')));
    });

    test('el título no grita', () {
      // La pre-cuenta de una cuenta dividida llega como
      // "PRECUENTA - CUENTA 1"; el modelo moderno no usa mayúsculas.
      final text = _modernPrecheck(title: 'PRECUENTA - CUENTA 1').rawText ?? '';
      expect(text, contains('Precuenta - Cuenta 1'));
      expect(text, isNot(contains('PRECUENTA')));
      expect(text, contains('Gracias por su preferencia'));
    });

    test('el modelo estándar de pre-cuenta no cambia', () {
      final bytes = PrintTicketService.generatePrecheck(
        order: _order(),
        items: [_item()],
        tableName: 'TERRAZA 12',
        businessName: 'Restaurante La Esquina del Sabor',
      );
      expect(bytes.preferRaster, isFalse);
      expect(_hasBytes(bytes.escPosCommands, [0x1B, 0x33]), isFalse);
      expect(bytes.rawText, contains('AVISO: ESTE DOCUMENTO ES SOLO'));
    });
  });

  group('Comandos de firmware', () {
    test('ajusta el interlineado sin cambiar de fuente', () {
      final bytes = _modernInvoice().escPosCommands;

      // ESC 3 n — interlineado del cuerpo. Por ENCIMA del 1/6" de fábrica
      // (~34) a propósito: este modelo separa los bloques con espacio en vez
      // de con reglas `====`, así que el espacio tiene que verse.
      expect(
        _hasBytes(bytes, [0x1B, 0x33, ModernInvoiceLayout.bodyLineSpacing]),
        isTrue,
      );
      expect(
        ModernInvoiceLayout.bodyLineSpacing,
        greaterThan(EscPosGenerator.tightLineSpacing),
        reason: 'a 32 el dueño lo rechazó: "los datos se ven muy pegados"',
      );

      // UN SOLO RITMO: los únicos interlineados del ticket son el del cuerpo
      // y el de las líneas en doble altura. Cualquier tercer valor sería un
      // renglón de aire metido a mano, y es justo lo que rompía la uniformidad
      // — el ticket tenía el doble de espacio alrededor de las reglas que
      // entre dos líneas de texto.
      final interlineados = <int>{};
      for (var i = 0; i + 2 < bytes.length; i++) {
        if (bytes[i] == 0x1B && bytes[i + 1] == 0x33) {
          interlineados.add(bytes[i + 2]);
        }
      }
      expect(interlineados, {
        ModernInvoiceLayout.bodyLineSpacing,
        ModernInvoiceLayout.bigLineSpacing,
      });

      // NUNCA fuente B (ESC M 1). Se probó y el dueño la rechazó al verla
      // impresa: 9x17 puntos contra 12x24 se lee peor en papel real. Es una
      // palanca de densidad, no de calidad. Si alguien la reintroduce
      // "para que quepa más", este test lo caza.
      expect(
        _hasBytes(bytes, [0x1B, 0x4D, 0x01]),
        isFalse,
        reason: 'la fuente B empeora la legibilidad en papel',
      );
    });

    test('el modelo estándar NO cambia fuente ni interlineado', () {
      final bytes = PrintTicketService.generateInvoice(
        order: _order(),
        items: [_item()],
        payments: [_payment()],
        tableName: 'TERRAZA 12',
        businessName: 'Restaurante La Esquina del Sabor',
      ).escPosCommands;

      expect(_hasBytes(bytes, [0x1B, 0x4D, 0x01]), isFalse);
      expect(_hasBytes(bytes, [0x1B, 0x33]), isFalse);
    });

    test('el modelo COMPACTO usa el mismo interlineado', () {
      // Su descripción en Ajustes siempre prometió "espaciado mínimo", pero
      // el código solo quitaba renglones en blanco: el aire de fábrica
      // seguía intacto.
      for (final template in ['compact', 'simple']) {
        final bytes = PrintTicketService.generateInvoice(
          order: _order(),
          items: [_item()],
          payments: [_payment()],
          tableName: 'TERRAZA 12',
          businessName: 'Restaurante La Esquina del Sabor',
          template: template,
        ).escPosCommands;

        expect(
          _hasBytes(bytes, [0x1B, 0x33, EscPosGenerator.tightLineSpacing]),
          isTrue,
          reason: '$template debe apretar el interlineado',
        );
        // Y las líneas en doble altura (título, TOTAL) suben el avance, o se
        // solapan con la siguiente: el glifo mide 48 puntos y el cuerpo 32.
        expect(
          _hasBytes(bytes, [
            0x1B,
            0x33,
            EscPosGenerator.doubleHeightLineSpacing,
          ]),
          isTrue,
          reason: '$template: el TOTAL en 2x necesita más avance',
        );
      }
    });

    test('el compacto vuelve a la métrica de fábrica antes de cortar', () {
      // Con el cuerpo apretado, los renglones de avance previos al corte
      // miden menos y la cuchilla llega a morder el pie del ticket.
      final bytes = PrintTicketService.generateInvoice(
        order: _order(),
        items: [_item()],
        payments: [_payment()],
        tableName: 'TERRAZA 12',
        businessName: 'Restaurante La Esquina del Sabor',
        template: 'compact',
      ).escPosCommands;

      final cutIndex = bytes.length - 3;
      expect(bytes.sublist(cutIndex, cutIndex + 2), [0x1D, 0x56]);

      final tail = bytes.sublist(0, cutIndex);
      final resetIndex = _lastIndexOfSequence(tail, [0x1B, 0x32]);
      expect(
        resetIndex,
        greaterThan(-1),
        reason: 'falta ESC 2 antes del corte',
      );
      expect(
        tail.sublist(resetIndex + 2).where((b) => b != 0x0A),
        isEmpty,
        reason: 'tras restaurar el interlineado solo puede haber avance',
      );
    });

    test('restaura la métrica de fábrica antes del corte', () {
      final bytes = _modernInvoice().escPosCommands;

      // El corte es GS V; lo último antes de los avances finales tiene que
      // ser ESC 2 (interlineado default) para que la cuchilla no muerda.
      final cutIndex = bytes.length - 3;
      expect(bytes.sublist(cutIndex, cutIndex + 2), [0x1D, 0x56]);

      final tail = bytes.sublist(0, cutIndex);
      final resetIndex = _lastIndexOfSequence(tail, [0x1B, 0x32]);
      expect(
        resetIndex,
        greaterThan(-1),
        reason: 'falta ESC 2 antes del corte',
      );

      // Y entre ese reset y el corte solo puede haber avances de papel.
      final between = tail.sublist(resetIndex + 2);
      expect(
        between.where((b) => b != 0x0A && b != 0x1B && b != 0x4D && b != 0x00),
        isEmpty,
        reason: 'se imprimió contenido después de restaurar el interlineado',
      );
      expect(
        between.where((b) => b == 0x0A).length,
        greaterThanOrEqualTo(EscPosGenerator.safeCutFeedLines),
      );
    });
  });

  group('Ancho de papel', () {
    test('a 80mm respeta las 48 columnas de la fuente A', () {
      final ticket = _modernInvoice();

      expect(_widestLine(ticket.rawText), lessThanOrEqualTo(48));
      // Sin reglas dobles: el modelo moderno usa un solo tipo de separador.
      expect(ticket.rawText, isNot(contains('====')));
    });

    test('a 58mm ninguna línea pasa de 32 columnas', () {
      final ticket = _modernInvoice(paperWidth: 58);

      expect(_widestLine(ticket.rawText), lessThanOrEqualTo(32));
    });

    test('el nombre largo del producto se envuelve, no se trunca', () {
      // A 48 columnas este nombre no entra en la línea del monto, así que
      // pasa a una segunda. Lo que NO puede pasar es perder palabras: el
      // `textRow` del generador trunca a lo bruto y dejaría
      // "Sandwich de pernil con que".
      final text =
          _modernInvoice(
            items: [_item(name: 'Sandwich de pernil con queso y vegetales')],
          ).rawText ??
          '';

      for (final word in 'Sandwich de pernil con queso y vegetales'.split(
        ' ',
      )) {
        expect(text, contains(word), reason: 'se perdió "$word"');
      }
    });
  });

  group('Detalle de ítems', () {
    test('muestra precio unitario solo cuando la cantidad no es 1', () {
      final multi = _modernInvoice(items: [_item(quantity: 2)]).rawText ?? '';
      final single = _modernInvoice(items: [_item(quantity: 1)]).rawText ?? '';

      expect(multi, contains('c/u'));
      expect(single, isNot(contains('c/u')));
    });

    test('modificadores, nota y para-llevar siguen saliendo', () {
      final text =
          _modernInvoice(
            items: [_item(isTakeout: true, notes: 'Sin cebolla')],
          ).rawText ??
          '';

      expect(text, contains('Extra queso cheddar derretido'));
      expect(text, contains('Nota: Sin cebolla'));
      expect(text, contains('Para llevar'));
    });
  });
}

/// Última posición donde aparece [needle] dentro de [haystack]; -1 si no está.
int _lastIndexOfSequence(List<int> haystack, List<int> needle) {
  for (var i = haystack.length - needle.length; i >= 0; i--) {
    var match = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        match = false;
        break;
      }
    }
    if (match) return i;
  }
  return -1;
}
