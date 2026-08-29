import { assertEquals } from "https://deno.land/std@0.208.0/assert/mod.ts";
import { buildAlanubePayload, FiscalDocument, OrderItem, Sender } from "./ecf-payload.ts";
import { EcfTaxLine, summarizeEcfTaxLines } from "./ecf-tax-lines.ts";

const ITBIS = { include_in_ecf: true, name: "ITBIS", rate: 18 };
const LEY = { include_in_ecf: true, name: "Ley 10%", rate: 10 };

const sender: Sender = {
  rnc: "133328828",
  companyName: "Tropella Coffee SRL",
  tradename: "Tropella Coffee",
  address: "GREGORIO LUPERON, No. B 4, GURABO",
};

function doc(over: Partial<FiscalDocument> = {}): FiscalDocument {
  return {
    id: "fd1",
    business_id: "b1",
    order_id: "o1",
    ncf_type: "E32",
    ncf_number: "E320000000002",
    customer_rnc: null,
    customer_name: "Consumidor Final",
    customer_address: null,
    subtotal: 100,
    discount: 0,
    tax_exempt: 0,
    taxable_amount: 100,
    itbis_amount: 18,
    service_fee: 10,
    tip: 0,
    total: 128,
    is_electronic: true,
    alanube_document_id: null,
    issued_at: "2026-08-29T14:00:00Z",
    idempotency_key: null,
    ...over,
  };
}

// Consumo en local: 2 cafes a RD$59 con ITBIS incluido.
// Base 50 c/u -> subtotal 100, ITBIS 18, Ley 10. El cliente paga 128.
// `order_items.tax_rate` guarda 28 = la tasa TOTAL: es la trampa.
const itemLocal: OrderItem = {
  id: "i1",
  product_id: "p1",
  product_name: "Cafe americano",
  sku: null,
  quantity: 2,
  unit_price: 59,
  tax_rate: 28,
  tax: 28,
  subtotal: 100,
  discounts: 0,
};

const lineasLocal: EcfTaxLine[] = [
  { order_item_id: "i1", tax_rate: 18, amount: 18, taxes: ITBIS },
  { order_item_id: "i1", tax_rate: 10, amount: 10, taxes: LEY },
];

type Line = {
  billingIndicator: number;
  quantityItem: number;
  unitPriceItem: number;
  itemAmount: number;
};

Deno.test("consumo en local: la linea se declara GRAVADA al 18, no exenta", () => {
  const breakdown = summarizeEcfTaxLines([itemLocal], lineasLocal);
  const payload = buildAlanubePayload(doc(), sender, [itemLocal], breakdown);
  const lines = payload.itemDetails as Line[];

  // Antes de arreglarlo esto era 4 (EXENTO) con itbis_amount > 0 en el
  // encabezado: el comprobante se contradecia a si mismo.
  assertEquals(lines[0].billingIndicator, 1);
});

Deno.test("cantidad x precio unitario == monto de linea", () => {
  const breakdown = summarizeEcfTaxLines([itemLocal], lineasLocal);
  const payload = buildAlanubePayload(doc(), sender, [itemLocal], breakdown);
  const l = (payload.itemDetails as Line[])[0];

  // Antes: unitPriceItem venia de unit_price (59, CON impuesto) mientras
  // itemAmount venia de subtotal (100, base) -> 2 x 59 = 118 != 100.
  assertEquals(l.quantityItem, 2);
  assertEquals(l.unitPriceItem, 50);
  assertEquals(l.itemAmount, 100);
  assertEquals(l.quantityItem * l.unitPriceItem, l.itemAmount);
});

Deno.test("la tasa declarada es 18, no 28", () => {
  const breakdown = summarizeEcfTaxLines([itemLocal], lineasLocal);
  const payload = buildAlanubePayload(doc(), sender, [itemLocal], breakdown);
  const totals = payload.totals as Record<string, number>;

  // 28 es una tasa que la DGII no acepta.
  assertEquals(totals.itbisS1, 18);
  assertEquals(totals.itbis1Total, 18);
  assertEquals(totals.totalTaxedAmount, 100);
  assertEquals(totals.totalAmount, 118);
});

Deno.test("para llevar (sin Ley): igual gravado al 18", () => {
  const item = { ...itemLocal, tax_rate: 18, tax: 18 };
  const breakdown = summarizeEcfTaxLines([item], [
    { order_item_id: "i1", tax_rate: 18, amount: 18, taxes: ITBIS },
  ]);
  const payload = buildAlanubePayload(doc(), sender, [item], breakdown);
  assertEquals((payload.itemDetails as Line[])[0].billingIndicator, 1);
  assertEquals((payload.totals as Record<string, number>).itbisS1, 18);
});

Deno.test("orden legacy sin lineas de impuesto: cae a tax_rate como antes", () => {
  const item = { ...itemLocal, tax_rate: 18, subtotal: 100 };
  const payload = buildAlanubePayload(doc(), sender, [item], null);
  assertEquals((payload.itemDetails as Line[])[0].billingIndicator, 1);
});

Deno.test("producto sin impuesto vinculado sale exento", () => {
  const item = { ...itemLocal, tax_rate: 0, tax: 0 };
  const payload = buildAlanubePayload(doc(), sender, [item], null);
  assertEquals((payload.itemDetails as Line[])[0].billingIndicator, 4);
});

Deno.test("orden mixta: cada linea lleva SU indicador", () => {
  const gravado = { ...itemLocal, id: "g", product_name: "Cafe", subtotal: 100 };
  const exento = { ...itemLocal, id: "e", product_name: "Libro", subtotal: 50, tax_rate: 0, tax: 0 };
  const breakdown = summarizeEcfTaxLines([gravado, exento], [
    { order_item_id: "g", tax_rate: 18, amount: 18, taxes: ITBIS },
    { order_item_id: "g", tax_rate: 10, amount: 10, taxes: LEY },
  ]);
  const payload = buildAlanubePayload(
    doc({ taxable_amount: 100, itbis_amount: 18, tax_exempt: 50, total: 178 }),
    sender,
    [gravado, exento],
    breakdown,
  );
  const lines = payload.itemDetails as Line[];
  // 2 productos + la linea no facturable de la Ley del producto gravado.
  assertEquals(lines.length, 3);
  assertEquals(lines[0].billingIndicator, 1);
  assertEquals(lines[1].billingIndicator, 4);
  assertEquals(lines[2].billingIndicator, 0);
  // Cada linea sigue cuadrando cantidad x precio.
  for (const l of lines) {
    assertEquals(l.quantityItem * l.unitPriceItem, l.itemAmount);
  }
});

Deno.test("lineas negativas (unidad gratis de oferta) no se declaran", () => {
  const gratis = { ...itemLocal, id: "free", subtotal: -50, quantity: 1 };
  const breakdown = summarizeEcfTaxLines([itemLocal], lineasLocal);
  const payload = buildAlanubePayload(doc(), sender, [itemLocal, gratis], breakdown);
  const lines = payload.itemDetails as Line[];
  // La linea negativa no se declara; quedan el producto y la Ley no facturable.
  assertEquals(lines.filter((l) => l.billingIndicator !== 0).length, 1);
  assertEquals(lines.filter((l) => l.billingIndicator === 0).length, 1);
});

Deno.test("E32 no manda sequenceDueDate; E31 si", () => {
  const e32 = buildAlanubePayload(doc(), sender, [itemLocal], null);
  assertEquals((e32.idDoc as Record<string, unknown>).sequenceDueDate, undefined);

  const e31 = buildAlanubePayload(
    doc({ ncf_type: "E31", customer_rnc: "131234567", customer_name: "Cliente SRL" }),
    sender,
    [itemLocal],
    null,
  );
  assertEquals(typeof (e31.idDoc as Record<string, unknown>).sequenceDueDate, "string");
});

Deno.test("el emisor va con la razon social y el RNC del negocio", () => {
  const payload = buildAlanubePayload(doc(), sender, [itemLocal], null);
  const s = payload.sender as Record<string, unknown>;
  assertEquals(s.rnc, "133328828");
  assertEquals(s.companyName, "Tropella Coffee SRL");
  assertEquals(s.stampDate, "2026-08-29");
});

// ── Limitacion conocida del redondeo ────────────────────────────────────
// Cuando la cantidad no divide exacto, `cantidad x precio unitario` queda a
// unos centavos del monto de linea, porque el precio se redondea a 2 decimales.
// Sigue siendo MUCHO mejor que antes (mandaba el precio CON impuesto, un
// descuadre del 18%), pero si Alanube o la DGII validan esa aritmetica al
// centavo hay que declarar la diferencia en el campo de descuento de la linea.
// Este test documenta el comportamiento actual para que el dia que reviente no
// sorprenda a nadie.
Deno.test("KNOWN: cantidad que no divide exacto deja centavos de descuadre", () => {
  const item = { ...itemLocal, quantity: 3, subtotal: 100, tax_rate: 18 };
  const payload = buildAlanubePayload(doc(), sender, [item], null);
  const l = (payload.itemDetails as Line[])[0];

  assertEquals(l.unitPriceItem, 33.33);
  assertEquals(l.itemAmount, 100);
  assertEquals(Number((l.quantityItem * l.unitPriceItem).toFixed(2)), 99.99);
});

// ── Porcion exenta: el caso real de Tropella (vende agua exenta) ────────
Deno.test("producto exento entra al total declarado", () => {
  // Cafe RD$250 inclusive (base 211.86 + ITBIS 38.14) + AGUA RD$100, que en
  // RD esta exenta de ITBIS pero lleva Ley 10%.
  const cafe: OrderItem = { ...itemLocal, id: "cafe", product_name: "Capuchino",
    quantity: 1, unit_price: 250, tax_rate: 28, subtotal: 211.86 };
  const agua: OrderItem = { ...itemLocal, id: "agua", product_name: "Agua",
    quantity: 1, unit_price: 100, tax_rate: 10, subtotal: 100 };

  const breakdown = summarizeEcfTaxLines([cafe, agua], [
    { order_item_id: "cafe", tax_rate: 18, amount: 38.14, taxes: ITBIS },
    { order_item_id: "cafe", tax_rate: 10, amount: 21.19, taxes: LEY },
    { order_item_id: "agua", tax_rate: 10, amount: 10, taxes: LEY },
  ]);

  // tax_exempt: 0 a proposito — es lo que SIEMPRE trae la columna.
  const payload = buildAlanubePayload(
    doc({ subtotal: 311.86, taxable_amount: 211.86, itbis_amount: 38.14, tax_exempt: 0, total: 350 }),
    sender,
    [cafe, agua],
    breakdown,
  );

  const lines = payload.itemDetails as Line[];
  const totals = payload.totals as Record<string, number>;

  assertEquals(lines[0].billingIndicator, 1); // cafe gravado
  assertEquals(lines[1].billingIndicator, 4); // agua exenta
  assertEquals(totals.exemptAmount, 100);

  // Lo que hacia rechazable el comprobante: la suma de lineas FACTURABLES
  // tiene que cuadrar con el total declarado. Antes daba 250 con lineas de
  // 311.86. Las no facturables (Ley) van aparte, en payValue.
  const facturables = lines
    .filter((l) => l.billingIndicator !== 0)
    .reduce((a, l) => a + l.itemAmount, 0);
  assertEquals(Number((facturables + totals.itbis1Total).toFixed(2)), totals.totalAmount);
  assertEquals(totals.totalAmount, 350);

  const todas = lines.reduce((a, l) => a + l.itemAmount, 0);
  assertEquals(Number((todas + totals.itbis1Total).toFixed(2)), totals.payValue);
});

Deno.test("todo gravado: no aparece exemptAmount", () => {
  const breakdown = summarizeEcfTaxLines([itemLocal], lineasLocal);
  const payload = buildAlanubePayload(doc(), sender, [itemLocal], breakdown);
  assertEquals((payload.totals as Record<string, unknown>).exemptAmount, undefined);
});

// ── Empresa asociada: la causa del AP1016 ───────────────────────────────
Deno.test("el ULID de la empresa viaja en el CUERPO como company.id", () => {
  // Sin esto, Alanube emite contra la compañia principal de la cuenta
  // (MANGOPOS) y rechaza con AP1016 "Sender RNC not match with company
  // identification", porque el sender lleva el RNC del cliente.
  const payload = buildAlanubePayload(
    doc(), sender, [itemLocal], null, "01M11V7B6J4X6FQ5SRAFPVPATV",
  );
  assertEquals(payload.company, { id: "01M11V7B6J4X6FQ5SRAFPVPATV" });
  // Y el sender sigue siendo el del cliente, no el de la cuenta.
  assertEquals((payload.sender as Record<string, unknown>).rnc, "133328828");
});

Deno.test("sin ULID no se agrega company (emite contra la principal)", () => {
  const payload = buildAlanubePayload(doc(), sender, [itemLocal], null);
  assertEquals(payload.company, undefined);
  assertEquals(buildAlanubePayload(doc(), sender, [itemLocal], null, "").company, undefined);
});

// ── Propina de ley: linea no facturable + valor cobrado ─────────────────
Deno.test("la Ley 10% se declara como linea NO FACTURABLE, no en la base", () => {
  // El ticket real: GOMITAS 23.44 (gravado) + AGUA 45.45 (exenta) + LEY 6.89.
  // El cliente pago 80.00; la DGII debe ver 73.11 de total fiscal y 80.00 cobrado.
  const gomitas: OrderItem = { ...itemLocal, id: "g", product_name: "Gomitas",
    quantity: 1, unit_price: 23.44, tax_rate: 28, subtotal: 23.44 };
  const agua: OrderItem = { ...itemLocal, id: "a", product_name: "Agua",
    quantity: 1, unit_price: 45.45, tax_rate: 10, subtotal: 45.45 };

  const breakdown = summarizeEcfTaxLines([gomitas, agua], [
    { order_item_id: "g", tax_rate: 18, amount: 4.22, taxes: ITBIS },
    { order_item_id: "g", tax_rate: 10, amount: 2.34, taxes: LEY },
    { order_item_id: "a", tax_rate: 10, amount: 4.55, taxes: LEY },
  ])!;

  assertEquals(breakdown.excludedTaxAmount, 6.89);
  assertEquals(breakdown.excludedTaxName, "Ley 10%");

  const payload = buildAlanubePayload(
    doc({ subtotal: 68.89, taxable_amount: 23.44, itbis_amount: 4.22, tax_exempt: 0, total: 80 }),
    sender, [gomitas, agua], breakdown, "01M11V7B6J4X6FQ5SRAFPVPATV",
  );
  const lines = payload.itemDetails as Line[];
  const totals = payload.totals as Record<string, number>;

  // Tres lineas: gravada, exenta y la no facturable.
  assertEquals(lines.length, 3);
  assertEquals(lines[0].billingIndicator, 1); // gomitas
  assertEquals(lines[1].billingIndicator, 4); // agua
  assertEquals(lines[2].billingIndicator, 0); // Ley: NO facturable
  assertEquals(lines[2].itemAmount, 6.89);

  // totalAmount NO se infla: gravado + exento + ITBIS.
  assertEquals(totals.totalAmount, 73.11);
  assertEquals(totals.totalTaxedAmount, 23.44);
  assertEquals(totals.exemptAmount, 45.45);
  assertEquals(totals.itbis1Total, 4.22);

  // Y el valor cobrado cuadra con el ticket.
  assertEquals(totals.nonBillableAmount, 6.89);
  assertEquals(totals.payValue, 80);
});

Deno.test("sin impuestos excluidos no aparece nonBillableAmount ni payValue", () => {
  const breakdown = summarizeEcfTaxLines([itemLocal], [
    { order_item_id: "i1", tax_rate: 18, amount: 18, taxes: ITBIS },
  ]);
  const payload = buildAlanubePayload(doc(), sender, [itemLocal], breakdown);
  const totals = payload.totals as Record<string, unknown>;
  assertEquals(totals.nonBillableAmount, undefined);
  assertEquals(totals.payValue, undefined);
  assertEquals((payload.itemDetails as Line[]).length, 1);
});

Deno.test("venta de puro exento con Ley: ya no cae al camino legacy", () => {
  // Un agua sola: sin ITBIS pero con Ley. Antes devolvia null y se declaraba
  // `doc.total` con la Ley adentro.
  const agua: OrderItem = { ...itemLocal, id: "a", product_name: "Agua",
    quantity: 1, unit_price: 45.45, tax_rate: 10, subtotal: 45.45 };
  const breakdown = summarizeEcfTaxLines([agua], [
    { order_item_id: "a", tax_rate: 10, amount: 4.55, taxes: LEY },
  ])!;

  assertEquals(breakdown.itbisAmount, 0);
  assertEquals(breakdown.excludedTaxAmount, 4.55);

  const payload = buildAlanubePayload(
    doc({ subtotal: 45.45, taxable_amount: 0, itbis_amount: 0, tax_exempt: 0, total: 50 }),
    sender, [agua], breakdown,
  );
  const totals = payload.totals as Record<string, number>;
  assertEquals(totals.totalAmount, 45.45);   // todo exento
  assertEquals(totals.exemptAmount, 45.45);
  assertEquals(totals.totalTaxedAmount, undefined);
  assertEquals(totals.payValue, 50);         // lo que pago el cliente
});
