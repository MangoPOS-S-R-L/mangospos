// Fase 3 Proveedores — las reglas que se pueden equivocar.
//
// Tres son de negocio, no de pantalla, y las tres producirían números que
// parecen correctos:
//
//   1. **El plazo.** `payment_terms` es texto libre. Deducir «30 días» de
//      «50% anticipo» o de «2/10 neto 30» genera un VENCIMIENTO FALSO, que
//      es peor que no tener ninguno: alguien paga tarde confiando en una
//      fecha inventada.
//   2. **El cumplimiento.** Un proveedor nuevo, sin órdenes cerradas, tiene
//      que dar «sin datos» — nunca 0%, que lo acusa de incumplir.
//   3. **La variación de precio.** Se compara contra la última compra a un
//      precio DISTINTO. Comparar contra la línea anterior a secas devuelve
//      0% cada vez que se repite una compra al mismo precio, y el alza
//      desaparece.
//
// El armado es puro, así que se prueba sin Supabase ni widgets.

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/presentation/inventory/state/inventory_state.dart';
import 'package:mangopos/presentation/inventory/state/supplier_overview_state.dart';

InventorySupplierDetail _supplier(
  String id, {
  String? name,
  String rnc = '',
  String paymentTerms = '',
  String paymentTermsType = '',
  int? paymentTermsDays,
  String paymentTermsFrom = '',
  bool isActive = true,
  double? minOrderAmount,
  int? leadTimeDays,
}) => InventorySupplierDetail(
  id: id,
  name: name ?? id,
  rnc: rnc,
  contactName: '',
  phone: '',
  email: '',
  address: '',
  paymentTerms: paymentTerms,
  notes: '',
  isActive: isActive,
  createdAt: null,
  paymentTermsType: paymentTermsType,
  paymentTermsDays: paymentTermsDays,
  paymentTermsFrom: paymentTermsFrom,
  minOrderAmount: minOrderAmount,
  leadTimeDays: leadTimeDays,
);

SupplierOrderRow _order(
  String supplierId, {
  String status = 'received',
  double total = 1000,
  DateTime? createdAt,
  DateTime? receivedDate,
}) => SupplierOrderRow(
  supplierId: supplierId,
  status: status,
  total: total,
  createdAt: createdAt,
  receivedDate: receivedDate,
);

SupplierPayableRow _payable(
  String supplierId, {
  double balance = 1000,
  DateTime? dueDate,
  String status = 'pending',
}) => SupplierPayableRow(
  supplierId: supplierId,
  balance: balance,
  originalAmount: balance,
  dueDate: dueDate,
  status: status,
);

void main() {
  group('SupplierTerms — qué se puede afirmar del texto libre', () {
    test('un número solo es un plazo defendible', () {
      final terms = SupplierTerms.fromSupplier(
        _supplier('s', paymentTerms: '30 dias'),
      );
      expect(terms.type, SupplierTermsType.credito);
      expect(terms.days, 30);
      expect(
        terms.structured,
        isFalse,
        reason: 'salió del texto, no de una columna: hay que confirmarlo',
      );
      expect(terms.label, 'Crédito 30 días');
    });

    test('un porcentaje NO es un plazo', () {
      final terms = SupplierTerms.fromSupplier(
        _supplier('s', paymentTerms: '50% anticipo'),
      );
      expect(terms.type, SupplierTermsType.anticipo);
      expect(terms.days, isNull);
      expect(
        terms.hasDueDate,
        isFalse,
        reason: 'de un anticipo no sale ninguna fecha',
      );
    });

    test('dos números son ambiguos: no se elige ninguno', () {
      final terms = SupplierTerms.fromSupplier(
        _supplier('s', paymentTerms: '2/10 neto 30'),
      );
      expect(terms.type, isNull);
      expect(terms.days, isNull);
      expect(
        terms.label,
        '2/10 neto 30',
        reason: 'se muestra literal en vez de inventar un plazo',
      );
      expect(terms.hasDueDate, isFalse);
    });

    test('«15 dias fin de mes» tampoco: fin de mes no es "a 15 días"', () {
      // Un solo número, pero el texto dice cuándo cuenta. `PaymentTerms` lo
      // acepta como 15 y esta pantalla no lo contradice — lo importante es
      // que quede marcado como NO confirmado.
      final terms = SupplierTerms.fromSupplier(
        _supplier('s', paymentTerms: '15 dias fin de mes'),
      );
      expect(terms.structured, isFalse);
    });

    test('contado escrito a mano se reconoce y no genera deuda', () {
      final terms = SupplierTerms.fromSupplier(
        _supplier('s', paymentTerms: 'Contado'),
      );
      expect(terms.type, SupplierTermsType.contado);
      expect(terms.hasDueDate, isFalse);
      expect(terms.label, 'Contado');
    });

    test('la columna manda sobre el texto', () {
      final terms = SupplierTerms.fromSupplier(
        _supplier(
          's',
          paymentTerms: 'a veces 15 a veces 30',
          paymentTermsType: 'credito',
          paymentTermsDays: 45,
          paymentTermsFrom: 'receipt',
        ),
      );
      expect(terms.days, 45);
      expect(terms.base, SupplierTermsBase.receipt);
      expect(terms.structured, isTrue);
      expect(terms.hasDueDate, isTrue);
    });

    test('un 0 en payment_terms_days sin tipo NO es contado', () {
      // Esa columna nació con `default 0 not null` en 20260811_0001: leerlo
      // como contado marcaría de contado a todo el catálogo viejo.
      final terms = SupplierTerms.fromSupplier(
        _supplier('s', paymentTermsDays: 0),
      );
      expect(terms.type, isNull);
      expect(terms.label, 'Sin definir');
    });

    test('el vencimiento sale del plazo, y sólo con plazo', () {
      final credit = SupplierTerms.fromSupplier(
        _supplier('s', paymentTermsType: 'credito', paymentTermsDays: 30),
      );
      expect(
        credit.dueDateFrom(DateTime(2026, 8, 12)),
        DateTime(2026, 9, 11),
      );

      final unknown = SupplierTerms.fromSupplier(
        _supplier('s', paymentTerms: 'contra entrega parcial'),
      );
      expect(unknown.dueDateFrom(DateTime(2026, 8, 12)), isNull);
    });
  });

  group('SuppliersOverview.build', () {
    final today = DateTime(2026, 8, 19);

    test('los borradores y las canceladas no son compras', () {
      final overview = SuppliersOverview.build(
        suppliers: [_supplier('a')],
        orders: [
          _order('a', status: 'received', total: 1000),
          _order('a', status: 'draft', total: 9000),
          _order('a', status: 'cancelled', total: 9000),
          _order('a', status: 'sent', total: 500),
        ],
        now: today,
      );
      final a = overview.suppliers.single;
      expect(a.spend, 1500, reason: 'recibida + enviada; borrador y anulada no');
      expect(a.orders, 2);
    });

    test('sin órdenes cerradas el cumplimiento es desconocido, no 0%', () {
      final overview = SuppliersOverview.build(
        suppliers: [_supplier('nuevo')],
        orders: [_order('nuevo', status: 'sent')],
        now: today,
      );
      expect(overview.suppliers.single.fulfillmentPct, isNull);
    });

    test('el cumplimiento cuenta recibidas sobre órdenes ya resueltas', () {
      final overview = SuppliersOverview.build(
        suppliers: [_supplier('a')],
        orders: [
          for (var i = 0; i < 17; i++) _order('a', status: 'received'),
          _order('a', status: 'partial'),
          // Una enviada todavía no dice nada del proveedor: no entra al
          // denominador ni lo castiga.
          _order('a', status: 'sent'),
        ],
        now: today,
      );
      final a = overview.suppliers.single;
      expect(a.ordersClosed, 18);
      expect(a.ordersReceived, 17);
      expect(a.fulfillmentPct, closeTo(94.4, 0.1));
    });

    test('una recepción anterior a la orden no promedia el tiempo de entrega', () {
      final overview = SuppliersOverview.build(
        suppliers: [_supplier('a')],
        orders: [
          _order(
            'a',
            createdAt: DateTime(2026, 8, 1),
            receivedDate: DateTime(2026, 8, 4),
          ),
          // Dato mal cargado: recibida ANTES de crearse.
          _order(
            'a',
            createdAt: DateTime(2026, 8, 10),
            receivedDate: DateTime(2026, 8, 2),
          ),
        ],
        now: today,
      );
      expect(overview.suppliers.single.avgLeadDays, 3);
    });

    test('sólo la deuda abierta cuenta, y el vencimiento próximo manda', () {
      final overview = SuppliersOverview.build(
        suppliers: [_supplier('a')],
        payables: [
          _payable('a', balance: 12400, dueDate: DateTime(2026, 9, 11)),
          _payable('a', balance: 5100, dueDate: DateTime(2026, 8, 27)),
          _payable('a', balance: 8000, status: 'paid'),
          _payable('a', balance: 0),
        ],
        now: today,
      );
      final a = overview.suppliers.single;
      expect(a.payable, 17500);
      expect(a.payableCount, 2);
      expect(a.nextDueDate, DateTime(2026, 8, 27));
      expect(a.daysToNextDue(now: today), 8);
      expect(a.overdueCount, 0);
    });

    test('una factura pasada de fecha cuenta como vencida', () {
      final overview = SuppliersOverview.build(
        suppliers: [_supplier('a')],
        payables: [_payable('a', dueDate: DateTime(2026, 8, 1))],
        now: today,
      );
      final a = overview.suppliers.single;
      expect(a.overdueCount, 1);
      expect(a.daysToNextDue(now: today), -18);
    });

    test('el orden es: activos primero, después por volumen', () {
      final overview = SuppliersOverview.build(
        suppliers: [
          _supplier('chico', name: 'Pescadería'),
          _supplier('grande', name: 'Ferretti'),
          _supplier('muerto', name: 'Suplidora', isActive: false),
        ],
        orders: [
          _order('chico', total: 36400),
          _order('grande', total: 214600),
          // Un inactivo con mucho volumen igual baja al final.
          _order('muerto', total: 999999),
        ],
        now: today,
      );
      expect(
        overview.suppliers.map((s) => s.id).toList(),
        ['grande', 'chico', 'muerto'],
      );
      expect(overview.activeCount, 2);
      expect(overview.inactiveCount, 1);
    });

    test('los contadores de lo que falta sólo miran a los activos', () {
      final overview = SuppliersOverview.build(
        suppliers: [
          _supplier('sinRnc'),
          _supplier('conRnc', rnc: '130-45872-1', paymentTerms: '30 dias'),
          _supplier('inactivoSinRnc', isActive: false),
        ],
      );
      expect(overview.withoutRncCount, 1);
      expect(overview.withoutTermsCount, 1);
    });

    test('el proveedor preferido de algún insumo queda marcado', () {
      final overview = SuppliersOverview.build(
        suppliers: [_supplier('a'), _supplier('b')],
        preferredCounts: const {'a': 3},
        supplies: const {
          'a': ['Harina', 'Aceite', 'Servilletas'],
        },
      );
      expect(overview.byId('a')!.isPreferred, isTrue);
      expect(overview.byId('a')!.suppliesCount, 3);
      expect(overview.byId('b')!.isPreferred, isFalse);
    });

    test('las iniciales salen del nombre, no del id', () {
      expect(
        SuppliersOverview.build(
          suppliers: [_supplier('x', name: 'Distribuidora Ferretti')],
        ).suppliers.single.initials,
        'DF',
      );
      expect(
        SuppliersOverview.build(
          suppliers: [_supplier('x', name: 'Ferretti')],
        ).suppliers.single.initials,
        'FE',
      );
    });
  });

  group('SupplierDetail.build — la historia del precio', () {
    SupplierOverview base() =>
        SuppliersOverview.build(suppliers: [_supplier('a')]).suppliers.single;

    test('la variación compara contra el último precio DISTINTO', () {
      // Cuatro compras: 3100, 3100, 3100, 2850. Comparar contra la línea
      // anterior devolvería 0% y el alza del 8.8% desaparecería.
      final detail = SupplierDetail.build(
        overview: base(),
        lines: [
          SupplierPurchaseLine(
            itemId: 'aceite',
            unitCost: 3100,
            at: DateTime(2026, 8, 16),
          ),
          SupplierPurchaseLine(
            itemId: 'aceite',
            unitCost: 3100,
            at: DateTime(2026, 8, 2),
          ),
          SupplierPurchaseLine(
            itemId: 'aceite',
            unitCost: 3100,
            at: DateTime(2026, 7, 20),
          ),
          SupplierPurchaseLine(
            itemId: 'aceite',
            unitCost: 2850,
            at: DateTime(2026, 7, 1),
          ),
        ],
      );
      final aceite = detail.items.single;
      expect(aceite.lastPaidPrice, 3100);
      expect(aceite.previousPaidPrice, 2850);
      expect(aceite.variationPct, closeTo(8.77, 0.01));
      expect(aceite.isSharpRise, isTrue);
    });

    test('con una sola compra no hay tendencia que mostrar', () {
      final detail = SupplierDetail.build(
        overview: base(),
        lines: [
          SupplierPurchaseLine(
            itemId: 'harina',
            unitCost: 32.5,
            at: DateTime(2026, 8, 7),
          ),
        ],
      );
      expect(detail.items.single.variationPct, isNull);
      expect(detail.items.single.isSharpRise, isFalse);
    });

    test('una baja de precio no es un alza', () {
      final detail = SupplierDetail.build(
        overview: base(),
        lines: [
          SupplierPurchaseLine(
            itemId: 'servilletas',
            unitCost: 425,
            at: DateTime(2026, 8, 1),
          ),
          SupplierPurchaseLine(
            itemId: 'servilletas',
            unitCost: 435,
            at: DateTime(2026, 7, 1),
          ),
        ],
      );
      final s = detail.items.single;
      expect(s.variationPct, closeTo(-2.3, 0.01));
      expect(s.isSharpRise, isFalse);
    });

    test('lo que se compra sin declarar aparece igual, y marcado', () {
      final detail = SupplierDetail.build(
        overview: base(),
        declared: const [
          SupplierItemLink(
            itemId: 'harina',
            itemName: 'Harina de trigo',
            supplierCode: 'FER-HAR-50',
            linked: true,
          ),
        ],
        lines: [
          SupplierPurchaseLine(
            itemId: 'aceite',
            unitCost: 3100,
            at: DateTime(2026, 8, 16),
          ),
        ],
        catalog: {
          'aceite': InventoryItemSummary(
            id: 'aceite',
            sku: 'INS-0058',
            name: 'Aceite de oliva',
            description: '',
            unit: 'L',
            cost: 0,
            minStock: 0,
            maxStock: null,
            isActive: true,
            stock: 0,
          ),
        },
      );
      expect(detail.items.length, 2);
      expect(detail.implicitItemsCount, 1);
      final aceite = detail.items.firstWhere((i) => i.itemId == 'aceite');
      expect(aceite.itemName, 'Aceite de oliva');
      expect(aceite.linked, isFalse);
      expect(aceite.isImplicitOnly, isTrue);
      final harina = detail.items.firstWhere((i) => i.itemId == 'harina');
      expect(harina.isImplicitOnly, isFalse, reason: 'declarado y sin compras');
    });

    test('el precio de lista sirve cuando todavía no se le compró', () {
      final detail = SupplierDetail.build(
        overview: base(),
        declared: const [
          SupplierItemLink(
            itemId: 'salmon',
            itemName: 'Salmón',
            listPrice: 890,
            linked: true,
          ),
        ],
      );
      expect(detail.items.single.price, 890);
      expect(detail.items.single.lastPaidPrice, isNull);
    });

    test('las deudas sin fecha van al final, no adelante', () {
      final detail = SupplierDetail.build(
        overview: base(),
        payables: [
          _payable('a', balance: 1, dueDate: null),
          _payable('a', balance: 2, dueDate: DateTime(2026, 9, 11)),
          _payable('a', balance: 3, dueDate: DateTime(2026, 8, 27)),
          _payable('a', balance: 4, status: 'cancelled'),
        ],
      );
      expect(
        detail.payables.map((p) => p.balance).toList(),
        [3, 2, 1],
        reason: 'por vencimiento; la cancelada no entra y la sin fecha va última',
      );
    });

    test('lo que subió de precio se ordena primero', () {
      final detail = SupplierDetail.build(
        overview: base(),
        lines: [
          SupplierPurchaseLine(
            itemId: 'reciente',
            unitCost: 100,
            at: DateTime(2026, 8, 18),
          ),
          SupplierPurchaseLine(
            itemId: 'caro',
            unitCost: 200,
            at: DateTime(2026, 8, 10),
          ),
          SupplierPurchaseLine(
            itemId: 'caro',
            unitCost: 150,
            at: DateTime(2026, 7, 10),
          ),
        ],
      );
      expect(
        detail.items.first.itemId,
        'caro',
        reason: 'el alza es lo único accionable, va arriba de lo más reciente',
      );
      expect(detail.sharpRises.length, 1);
    });
  });
}
