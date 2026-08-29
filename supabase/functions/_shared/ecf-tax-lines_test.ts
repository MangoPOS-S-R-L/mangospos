import { assertEquals } from "https://deno.land/std@0.208.0/assert/mod.ts";
import {
  billingIndicatorFromTaxRate,
  EcfTaxLine,
  isExcludedFromEcf,
  summarizeEcfTaxLines,
} from "./ecf-tax-lines.ts";

const ITBIS = { include_in_ecf: true, name: "ITBIS", rate: 18 };
const LEY_SIN_FLAG = { include_in_ecf: true, name: "Ley 10%", rate: 10 };
const LEY_CON_FLAG = { include_in_ecf: false, name: "Propina Ley", rate: 10 };

// Consumo en local de RD$100: base 100, ITBIS 18, Ley 10.
function lineasLocal(itemId: string, ley = LEY_SIN_FLAG): EcfTaxLine[] {
  return [
    { order_item_id: itemId, tax_rate: 18, amount: 18, taxes: ITBIS },
    { order_item_id: itemId, tax_rate: 10, amount: 10, taxes: ley },
  ];
}

Deno.test("billingIndicator: 18% es gravado, no exento", () => {
  assertEquals(billingIndicatorFromTaxRate(18), 1);
  assertEquals(billingIndicatorFromTaxRate(0.18), 1);
  assertEquals(billingIndicatorFromTaxRate(16), 2);
  assertEquals(billingIndicatorFromTaxRate(0), 4);
  assertEquals(billingIndicatorFromTaxRate(null), 4);
});

Deno.test("billingIndicator: 28 (ITBIS+Ley sumados) cae en exento — el bug", () => {
  // Confirma POR QUE no se puede alimentar con order_items.tax_rate.
  assertEquals(billingIndicatorFromTaxRate(28), 4);
});

// ── Clasificacion ───────────────────────────────────────────────────────
Deno.test("include_in_ecf=false excluye (señal primaria)", () => {
  assertEquals(isExcludedFromEcf(LEY_CON_FLAG), true);
});

Deno.test("fallback por nombre: la Ley 10% se excluye aunque no tenga el flag", () => {
  for (const name of ["Ley 10%", "ley", "Propina de ley", "Cargo por servicio", "LEY"]) {
    assertEquals(isExcludedFromEcf({ include_in_ecf: true, name, rate: 10 }), true, name);
  }
});

Deno.test("el ITBIS 18 nunca se excluye", () => {
  assertEquals(isExcludedFromEcf(ITBIS), false);
});

Deno.test("un impuesto de 10% que NO es propina no se excluye", () => {
  assertEquals(
    isExcludedFromEcf({ include_in_ecf: true, name: "Impuesto selectivo", rate: 10 }),
    false,
  );
});

Deno.test("impuesto nulo no excluye", () => {
  assertEquals(isExcludedFromEcf(null), false);
});

// ── El caso Tropella ────────────────────────────────────────────────────
Deno.test("consumo en local: la linea sale GRAVADA, no exenta", () => {
  const items = [{ id: "i1", subtotal: 100 }];
  const s = summarizeEcfTaxLines(items, lineasLocal("i1"))!;

  // Antes: tax_rate=28 -> indicador 4 (exento). Ahora la tasa sale de las
  // lineas que entran al e-CF: solo el ITBIS.
  assertEquals(billingIndicatorFromTaxRate(s.ratePctByItem.get("i1")!), 1);
  assertEquals(s.itbisAmount, 18);
  assertEquals(s.taxableAmount, 100);
  // Y la tasa declarada es 18, no 28 (que la DGII no acepta).
  assertEquals(s.effectiveRatePct, 18);
});

Deno.test("da igual si la Ley trae el flag o solo el nombre", () => {
  const items = [{ id: "i1", subtotal: 100 }];
  const conFlag = summarizeEcfTaxLines(items, lineasLocal("i1", LEY_CON_FLAG))!;
  const sinFlag = summarizeEcfTaxLines(items, lineasLocal("i1", LEY_SIN_FLAG))!;
  assertEquals(conFlag.itbisAmount, sinFlag.itbisAmount);
  assertEquals(conFlag.effectiveRatePct, sinFlag.effectiveRatePct);
});

Deno.test("para llevar (sin Ley): sigue gravado al 18", () => {
  const items = [{ id: "i1", subtotal: 100 }];
  const s = summarizeEcfTaxLines(items, [
    { order_item_id: "i1", tax_rate: 18, amount: 18, taxes: ITBIS },
  ])!;
  assertEquals(billingIndicatorFromTaxRate(s.ratePctByItem.get("i1")!), 1);
  assertEquals(s.effectiveRatePct, 18);
});

Deno.test("item con SOLO Ley 10%: sin ITBIS, pero la Ley se contabiliza aparte", () => {
  const items = [{ id: "i1", subtotal: 100 }];
  const s = summarizeEcfTaxLines(items, [
    { order_item_id: "i1", tax_rate: 10, amount: 10, taxes: LEY_CON_FLAG },
  ])!;
  // No hay ITBIS que declarar y el item queda fuera del mapa de tasas (sale
  // exento), pero la Ley cobrada SI se reporta: va como linea no facturable.
  assertEquals(s.itbisAmount, 0);
  assertEquals(s.taxableAmount, 0);
  assertEquals(s.ratePctByItem.has("i1"), false);
  assertEquals(s.excludedTaxAmount, 10);
});

Deno.test("orden mixta: producto gravado + producto exento", () => {
  const items = [{ id: "gravado", subtotal: 100 }, { id: "exento", subtotal: 50 }];
  const s = summarizeEcfTaxLines(items, [
    { order_item_id: "gravado", tax_rate: 18, amount: 18, taxes: ITBIS },
  ])!;
  assertEquals(billingIndicatorFromTaxRate(s.ratePctByItem.get("gravado")!), 1);
  assertEquals(s.ratePctByItem.has("exento"), false);
  // taxableAmount solo cuenta el gravado; los 50 restantes van a exemptAmount.
  assertEquals(s.taxableAmount, 100);
  assertEquals(s.itbisAmount, 18);
});

// ── Robustez ────────────────────────────────────────────────────────────
Deno.test("PostgREST puede devolver la relacion como array", () => {
  const items = [{ id: "i1", subtotal: 100 }];
  const s = summarizeEcfTaxLines(items, [
    { order_item_id: "i1", tax_rate: 18, amount: 18, taxes: [ITBIS] },
    { order_item_id: "i1", tax_rate: 10, amount: 10, taxes: [LEY_CON_FLAG] },
  ])!;
  assertEquals(s.effectiveRatePct, 18);
});

Deno.test("sin lineas de impuesto devuelve null", () => {
  assertEquals(summarizeEcfTaxLines([{ id: "i1", subtotal: 100 }], []), null);
});

Deno.test("lineas en cero no cuentan", () => {
  const s = summarizeEcfTaxLines([{ id: "i1", subtotal: 100 }], [
    { order_item_id: "i1", tax_rate: 18, amount: 0, taxes: ITBIS },
  ]);
  assertEquals(s, null);
});

Deno.test("doc legacy sin include_in_ecf: se asume incluido", () => {
  const s = summarizeEcfTaxLines([{ id: "i1", subtotal: 100 }], [
    { order_item_id: "i1", tax_rate: 18, amount: 18, taxes: { include_in_ecf: null, name: "ITBIS", rate: 18 } },
  ])!;
  assertEquals(s.itbisAmount, 18);
});
