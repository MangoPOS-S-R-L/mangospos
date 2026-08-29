// Clasificacion de impuestos para el e-CF: logica PURA, testeable.
//
// Resuelve el defecto que hacia que la DGII viera EXENTO casi todo el consumo
// en local: `order_items.tax_rate` guarda la tasa TOTAL resuelta (ITBIS 18 +
// Ley 10 = 28), y 28 no cae en ningun rango de ITBIS, asi que
// billingIndicatorFromTaxRate lo mandaba al `return 4` (exento) mientras el
// encabezado declaraba itbis_amount > 0. El comprobante se contradecia solo.
//
// La tasa que decide el indicador tiene que salir de las LINEAS de impuesto
// que entran al e-CF, no del total cobrado al cliente.

export interface EcfTaxRef {
  include_in_ecf: boolean | null;
  name: string | null;
  rate: number | null;
}

export interface EcfTaxLine {
  order_item_id: string;
  tax_rate: number | null;
  amount: number | null;
  // PostgREST devuelve la relacion FK como objeto cuando es many-to-one y como
  // array si la cardinalidad se detecta diferente. Aceptamos ambos.
  taxes: EcfTaxRef | EcfTaxRef[] | null;
}

export interface EcfItem {
  id: string;
  subtotal?: number | null;
}

export interface EcfTaxSummary {
  itbisAmount: number;
  taxableAmount: number;
  effectiveRatePct: number;
  /** Tasa e-CF por item, para el billingIndicator de cada linea. */
  ratePctByItem: Map<string, number>;
  /**
   * Suma de los impuestos que se le cobraron al cliente pero NO entran al e-CF
   * (la Ley 10%). Se declara como linea NO FACTURABLE — `billingIndicator: 0`
   * segun DGII — para que el `payValue` del comprobante cuadre con lo que la
   * persona realmente pago, sin inflar la base gravada ni el ITBIS.
   */
  excludedTaxAmount: number;
  /** Nombre del impuesto excluido de mayor monto, para rotular esa linea. */
  excludedTaxName: string | null;
}

export function unwrapTax(taxes: EcfTaxLine["taxes"]): EcfTaxRef | null {
  if (taxes == null) return null;
  return Array.isArray(taxes) ? (taxes[0] ?? null) : taxes;
}

/**
 * Un impuesto NO entra al e-CF cuando es la propina de ley / cargo de servicio:
 * se le cobra al cliente pero no se declara a la DGII.
 *
 * Señal primaria: `taxes.include_in_ecf = false`, que el negocio controla desde
 * Ajustes -> Impuestos. Fallback transitorio por nombre + tasa 10% para los
 * negocios que todavia no apagaron ese toggle — MISMO criterio que ya aplica el
 * cliente en reports_repository.dart, para que reporte y comprobante no
 * diverjan.
 */
export function isExcludedFromEcf(tax: EcfTaxRef | null): boolean {
  if (!tax) return false;
  if (tax.include_in_ecf === false) return true;

  const rate = Number(tax.rate ?? 0);
  if (Math.abs(rate - 10) >= 0.001) return false;

  const name = (tax.name ?? "").toLowerCase().trim();
  return (
    name.includes("propina") ||
    name.includes("servicio") ||
    name === "ley" ||
    name.includes(" ley") ||
    name.startsWith("ley ")
  );
}

/**
 * Indicador de facturacion DGII por linea:
 *   1 = gravado 18%, 2 = gravado 16%, 3 = gravado 0%, 4 = exento.
 *
 * Acepta la tasa como 18 o como 0.18.
 */
export function billingIndicatorFromTaxRate(
  rate: number | null | undefined,
): 1 | 2 | 3 | 4 {
  if (rate == null || rate === 0) return 4;
  const pct = rate > 1 ? rate : rate * 100;
  if (pct >= 17 && pct <= 19) return 1;
  if (pct >= 15 && pct < 17) return 2;
  return 4;
}

/**
 * Agrega las lineas de impuesto que SI entran al e-CF y devuelve, ademas de los
 * totales, la tasa por item — que es lo que necesita el billingIndicator de
 * cada linea del comprobante.
 *
 * Devuelve null cuando no hay nada declarable (sin lineas, o todas excluidas):
 * el caller cae a los montos del propio fiscal_document.
 */
export function summarizeEcfTaxLines(
  items: EcfItem[],
  rows: EcfTaxLine[],
): EcfTaxSummary | null {
  if (rows.length === 0) return null;

  const taxByItem = new Map<string, number>();
  const rateNum = new Map<string, number>();
  const rateDen = new Map<string, number>();
  const excludedByItem = new Map<string, number>();
  const excludedNameTotals = new Map<string, number>();

  for (const r of rows) {
    // Default `true` cuando el lookup falle: no romper docs legacy sin la
    // columna include_in_ecf.
    const tax = unwrapTax(r.taxes);
    if (isExcludedFromEcf(tax)) {
      const excl = Number(r.amount ?? 0);
      if (excl > 0) {
        excludedByItem.set(
          r.order_item_id,
          (excludedByItem.get(r.order_item_id) ?? 0) + excl,
        );
        const nombre = (tax?.name ?? "").trim();
        if (nombre.length > 0) {
          excludedNameTotals.set(nombre, (excludedNameTotals.get(nombre) ?? 0) + excl);
        }
      }
      continue;
    }

    const amt = Number(r.amount ?? 0);
    if (amt <= 0) continue;
    const rate = Number(r.tax_rate ?? 0);

    taxByItem.set(r.order_item_id, (taxByItem.get(r.order_item_id) ?? 0) + amt);
    rateNum.set(r.order_item_id, (rateNum.get(r.order_item_id) ?? 0) + rate * amt);
    rateDen.set(r.order_item_id, (rateDen.get(r.order_item_id) ?? 0) + amt);
  }

  let itbisAmount = 0;
  let taxableAmount = 0;
  let weightedNum = 0;
  let weightedDen = 0;
  let excludedTaxAmount = 0;
  const ratePctByItem = new Map<string, number>();

  for (const it of items) {
    // Se suma sobre los items recibidos (no sobre las filas sueltas) para no
    // contar impuestos de lineas que el payload no va a declarar.
    excludedTaxAmount += excludedByItem.get(it.id) ?? 0;

    const ecfTax = taxByItem.get(it.id) ?? 0;
    if (ecfTax <= 0) continue;

    itbisAmount += ecfTax;
    taxableAmount += Number(it.subtotal ?? 0);

    const num = rateNum.get(it.id) ?? 0;
    const den = rateDen.get(it.id) ?? 0;
    weightedNum += num;
    weightedDen += den;
    if (den > 0) ratePctByItem.set(it.id, num / den);
  }

  // Se devuelve resumen tambien cuando SOLO hay impuestos excluidos: es el caso
  // de una venta de puro producto exento con Ley 10% (un agua sola). Sin esto
  // caia al camino legacy, que declara `doc.total` con la Ley adentro.
  if (itbisAmount <= 0 && excludedTaxAmount <= 0) return null;

  let excludedTaxName: string | null = null;
  let mayor = 0;
  for (const [nombre, monto] of excludedNameTotals) {
    if (monto > mayor) {
      mayor = monto;
      excludedTaxName = nombre;
    }
  }

  return {
    itbisAmount: Number(itbisAmount.toFixed(2)),
    taxableAmount: Number(taxableAmount.toFixed(2)),
    effectiveRatePct: weightedDen > 0 ? Math.round(weightedNum / weightedDen) : 18,
    ratePctByItem,
    excludedTaxAmount: Number(excludedTaxAmount.toFixed(2)),
    excludedTaxName,
  };
}
