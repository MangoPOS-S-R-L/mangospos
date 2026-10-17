import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/data/models/order_item_tax_line.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/data/utils/order_pricing_utils.dart';
import 'package:mangopos/presentation/sales/logic/payment_fresh_total.dart';
import 'package:mangopos/presentation/sales/viewmodel/payment_split_viewmodel.dart';
import 'package:mangopos/services/printing/print_ticket_service.dart';

Order _order({
  double subtotal = 0,
  double tax = 0,
  double serviceFee = 0,
  double deliveryFee = 0,
}) => Order(
  id: 'order-1',
  sessionId: 'session-1',
  status: 'open',
  subtotal: subtotal,
  tax: tax,
  serviceFee: serviceFee,
  deliveryFee: deliveryFee,
  discounts: 0,
  total: 9999, // El encabezado obsoleto no reemplaza los productos frescos.
  createdAt: DateTime(2026, 10, 16),
);

OrderItem _item({
  String id = 'item-1',
  String? checkId,
  double quantity = 1,
  required double price,
  required double subtotal,
  required double tax,
  double discount = 0,
  String taxMode = 'inclusive',
  double taxRate = 28,
  double? originalTaxRate,
  bool takeout = false,
  List<OrderItemModifier> modifiers = const [],
  List<OrderItemTaxLine> taxLines = const [],
}) => OrderItem(
  id: id,
  orderId: 'order-1',
  checkId: checkId,
  productName: 'Producto $id',
  quantity: quantity,
  unitPrice: price,
  subtotal: subtotal,
  tax: tax,
  discounts: discount,
  total: subtotal + tax - discount,
  status: 'ready',
  isTakeout: takeout,
  taxMode: taxMode,
  taxRate: taxRate,
  originalTaxRate: originalTaxRate,
  modifiers: modifiers,
  taxLines: taxLines,
  createdAt: DateTime(2026, 10, 16),
);

OrderItemModifier _modifier(double price, {double quantity = 1}) =>
    OrderItemModifier(
      id: 'modifier-1',
      itemId: 'item-1',
      name: 'Seleccion',
      qty: quantity,
      price: price,
    );

typedef _PricingCase = ({
  String name,
  Order order,
  List<OrderItem> items,
  double expected,
  String origin,
});

List<_PricingCase> _cases() => [
  // Regresión de los importes reportados. La composición de RD$1770 es
  // sintética: aún no se han obtenido los productos reales de esa venta.
  (
    name: 'MedioTiempoBar mismos productos de precuenta 1770',
    order: _order(),
    items: [
      _item(id: 'drinks', quantity: 2, price: 425, subtotal: 664.06, tax: 185.94),
      _item(id: 'other-products', price: 920, subtotal: 718.75, tax: 201.25),
    ],
    expected: 1770,
    origin: 'table',
  ),
  (
    name: 'MedioTiempoBar 2195 requiere un producto adicional de 425',
    order: _order(),
    items: [
      _item(id: 'drinks', quantity: 2, price: 425, subtotal: 664.06, tax: 185.94),
      _item(id: 'other-products', price: 920, subtotal: 718.75, tax: 201.25),
      _item(id: 'additional-drink', price: 425, subtotal: 332.03, tax: 92.97),
    ],
    expected: 2195,
    origin: 'table',
  ),
  (
    name: 'precio definido por modificador',
    order: _order(),
    items: [
      _item(price: 0, subtotal: 195.31, tax: 54.69, modifiers: [_modifier(250)]),
    ],
    expected: 250,
    origin: 'table',
  ),
  (
    name: 'tres margaritas con seleccion de precio',
    order: _order(),
    items: [
      _item(
        quantity: 3,
        price: 0,
        subtotal: 1054.69,
        tax: 295.31,
        modifiers: [_modifier(450)],
      ),
    ],
    expected: 1350,
    origin: 'table',
  ),
  (
    name: 'extras por unidad en precio exclusive',
    order: _order(),
    items: [
      _item(
        quantity: 2,
        price: 100,
        subtotal: 256,
        tax: 71.68,
        taxMode: 'exclusive',
        modifiers: [_modifier(14, quantity: 2)],
      ),
    ],
    expected: 327.68,
    origin: 'quick',
  ),
  (
    name: 'oferta dos por uno inclusive',
    order: _order(),
    items: [_item(quantity: 2, price: 400, subtotal: 625, tax: 175, discount: 400)],
    expected: 400,
    origin: 'table',
  ),
  (
    name: 'descuento exclusive restado una vez',
    order: _order(),
    items: [
      _item(
        price: 295,
        subtotal: 295,
        tax: 82.60,
        discount: 75.52,
        taxMode: 'exclusive',
      ),
    ],
    expected: 302.08,
    origin: 'manual',
  ),
  (
    name: 'ley legacy ya incluida en precio inclusive',
    order: _order(subtotal: 390.63, tax: 70.31, serviceFee: 39.06),
    items: [
      _item(
        price: 500,
        subtotal: 390.63,
        tax: 70.31,
        taxRate: 18,
        originalTaxRate: 28,
      ),
    ],
    expected: 500,
    origin: 'table',
  ),
  (
    name: 'ley legacy adicional a precio exclusive',
    order: _order(subtotal: 100, tax: 18, serviceFee: 10),
    items: [_item(price: 100, subtotal: 100, tax: 18, taxMode: 'exclusive', taxRate: 18)],
    expected: 128,
    origin: 'table',
  ),
  (
    name: 'para llevar con solo ITBIS aplicable',
    order: _order(),
    items: [
      _item(
        price: 500,
        subtotal: 390.63,
        tax: 70.31,
        taxRate: 18,
        originalTaxRate: 28,
        takeout: true,
        taxLines: [
          OrderItemTaxLine(
            id: 'line-1',
            orderItemId: 'item-1',
            taxId: 'itbis',
            taxName: 'ITBIS',
            taxRate: 18,
            amount: 70.31,
            createdAt: DateTime(2026, 10, 16),
          ),
        ],
      ),
    ],
    expected: 500,
    origin: 'delivery',
  ),
  (
    name: 'mitades con centavos de redondeo',
    order: _order(),
    items: [
      for (final id in ['half-1', 'half-2'])
        _item(id: id, quantity: 0.5, price: 300, subtotal: 117.19, tax: 32.82),
    ],
    expected: 300,
    origin: 'table',
  ),
  (
    name: 'productos inclusive y exclusive mezclados',
    order: _order(),
    items: [
      _item(price: 500, subtotal: 390.63, tax: 109.37),
      _item(
        id: 'exclusive',
        price: 100,
        subtotal: 100,
        tax: 18,
        taxMode: 'exclusive',
        taxRate: 18,
      ),
    ],
    expected: 618,
    origin: 'quick',
  ),
  (
    name: 'descuento y cargo exento de envio',
    order: _order(deliveryFee: 100),
    items: [_item(price: 500, subtotal: 390.63, tax: 109.37, discount: 100)],
    expected: 500,
    origin: 'delivery',
  ),
  (
    name: 'producto exento sin ley fantasma',
    order: _order(),
    items: [_item(price: 100, subtotal: 100, tax: 0, taxRate: 0)],
    expected: 100,
    origin: 'table',
  ),
];

double _printedTotal(String text) {
  final match = RegExp(
    r'^\s*TOTAL(?::|\s).*?RD\$\s*([\d,]+\.\d{2})\s*$',
    multiLine: true,
  ).firstMatch(text);
  expect(match, isNotNull, reason: text);
  return double.parse(match!.group(1)!.replaceAll(',', ''));
}

void _expectSameTotal({
  required Order order,
  required List<OrderItem> items,
  required double expected,
  required String template,
  required String discountMode,
  required String origin,
  Order? paymentOrder,
  List<OrderCheck> checks = const [],
  String? checkId,
}) {
  final paymentTotal = freshPaymentScopeTotal(
    expectedOrderId: order.id,
    order: paymentOrder ?? order,
    items: items,
    checks: checks,
    checkId: checkId,
    forcedOrigin: origin,
  );
  expect(paymentTotal, expected);
  final state = PaymentSplitState(totalAmount: paymentTotal!);
  expect(state.remaining, expected);

  final breakdown = buildOrderTaxBreakdown(order, items, forcedOrigin: origin);
  final precheck = PrintTicketService.generatePrecheck(
    order: order,
    items: items,
    tableName: 'A2',
    template: template,
    discountDisplayMode: discountMode,
    taxBreakdown: breakdown,
  );
  final invoice = PrintTicketService.generateInvoice(
    order: order,
    items: items,
    payments: const [],
    tableName: 'A2',
    template: template,
    discountDisplayMode: discountMode,
    taxBreakdown: breakdown,
  );
  expect(_printedTotal(precheck.rawText ?? ''), expected);
  expect(_printedTotal(invoice.rawText ?? ''), expected);
}

void main() {
  for (final scenario in _cases()) {
    for (final template in ['standard', 'compact', 'simple', 'modern']) {
      for (final discountMode in ['pre_discount', 'post_discount']) {
        test('${scenario.name}: $template $discountMode conserva total al cobrar', () {
          _expectSameTotal(
            order: scenario.order,
            items: scenario.items,
            expected: scenario.expected,
            template: template,
            discountMode: discountMode,
            origin: scenario.origin,
          );
        });
      }
    }
  }

  for (final template in ['standard', 'compact', 'simple', 'modern']) {
    for (final discountMode in ['pre_discount', 'post_discount']) {
      test('subcuenta $template $discountMode no vuelve a cobrar envio de la orden', () {
        final source = _order(deliveryFee: 100);
        final selectedItems = [
          _item(checkId: 'check-1', price: 500, subtotal: 390.63, tax: 109.37),
        ];
        // La selección de alcance entrega a pantalla e impresión la misma
        // orden acotada. El cargo pertenece al comprobante de la mesa entera.
        _expectSameTotal(
          order: source.copyWith(deliveryFee: 0),
          paymentOrder: source,
          items: selectedItems,
          expected: 500,
          template: template,
          discountMode: discountMode,
          origin: 'delivery',
          checkId: 'check-1',
          checks: const [
            OrderCheck(
              id: 'check-1',
              orderId: 'order-1',
              label: 'C1',
              position: 2,
              isClosed: false,
              subtotal: 390.63,
              tax: 109.37,
              serviceFee: 0,
              discounts: 0,
              total: 500,
            ),
          ],
        );
      });
    }
  }
}
