// Construccion del payload e-CF que se le manda a Alanube (y de ahi a la DGII).
// Logica PURA: recibe el documento, el emisor, los items y el desglose de
// impuestos, y devuelve el JSON. Vive aparte de `emit-document` para que el
// contenido exacto de lo que se declara sea verificable con tests — es una
// declaracion fiscal, no un detalle de implementacion.

import { r2, roundAndReconcile } from "./dgii-rounding.ts";
import { billingIndicatorFromTaxRate } from "./ecf-tax-lines.ts";

export interface FiscalDocument {
  id: string;
  business_id: string;
  order_id: string | null;
  ncf_type: string;
  ncf_number: string;
  customer_rnc: string | null;
  customer_name: string;
  customer_address: string | null;
  subtotal: number | null;
  discount: number | null;
  tax_exempt: number | null;
  taxable_amount: number | null;
  itbis_amount: number | null;
  service_fee: number | null;
  tip: number | null;
  total: number | null;
  is_electronic: boolean;
  alanube_document_id: string | null;
  issued_at: string | null;
  idempotency_key: string | null;
  /** Solo en notas de credito/debito: el comprobante que modifican. */
  related_document_id?: string | null;
  modification_code?: number | null;
  modification_reason?: string | null;
}

/**
 * El comprobante que una nota de credito (E34) reversa. La DGII exige
 * referenciarlo: sin este bloque la nota no dice QUE anula.
 */
export interface ModifiedDocumentRef {
  ncf_number: string;
  issued_at: string | null;
}

/** Tipos que llevan `sequenceDueDate` (E32 y las notas NO lo llevan). */
const TYPES_WITH_SEQUENCE_DUE_DATE = ["E31", "E44", "E45"];

/** Notas de credito/debito: llevan informationReference en vez de vencimiento. */
export function isCreditNoteType(ncfType: string): boolean {
  return ncfType === "E34" || ncfType === "B04";
}

export interface Sender {
  rnc: string;
  companyName: string;
  tradename?: string;
  address: string;
  branchOffice?: string;
  mail?: string;
}

export interface OrderItem {
  id: string;
  product_id: string | null;
  product_name: string | null;
  sku: string | null;
  quantity: number;
  unit_price: number;
  tax_rate: number;
  tax: number | null;
  subtotal: number | null;
  discounts: number | null;
}

export interface EcfTaxBreakdown {
  itbisAmount: number;
  taxableAmount: number;
  effectiveRatePct: number;
  /** Tasa e-CF por item: alimenta el billingIndicator de cada linea. */
  ratePctByItem: Map<string, number>;
  /** Impuestos cobrados que NO entran al e-CF (Ley 10%). */
  excludedTaxAmount?: number;
  excludedTaxName?: string | null;
}

/** Dias calendario entre dos fechas YYYY-MM-DD. 0 si alguna no es fecha. */
function daysBetween(fromIso: string, toIso: string): number {
  const from = Date.parse(`${fromIso}T00:00:00Z`);
  const to = Date.parse(`${toIso}T00:00:00Z`);
  if (Number.isNaN(from) || Number.isNaN(to)) return 0;
  return Math.round((to - from) / 86_400_000);
}

/**
 * Cuadra el monto NO facturable (la propina de ley) contra el total que de
 * verdad se le cobro al cliente.
 *
 * Por que hace falta: el desglose se guarda ya redondeado al centavo POR LINEA
 * de impuesto, y esas piezas no siempre reconstruyen el precio de menu. Caso
 * real, e-CF E310000000002 de Tropella: un EXPRESSO DOBLE de RD$125.00 con
 * tasa inclusiva 28% queda como 97.66 + 17.58 + 9.77 = 125.01. El comprobante
 * declaraba `payValue` 800.01 contra 800.00 cobrados, y la DGII cuadra el
 * ValorPagar contra MontoPeriodo (observacion 11153).
 *
 * El residuo se absorbe AQUI a proposito: es la unica linea del comprobante
 * que no se declara como base gravada ni como ITBIS, asi que moverla un
 * centavo no altera nada de lo que la DGII liquida.
 *
 * Solo absorbe residuo de redondeo — a lo sumo un centavo por linea. Una
 * diferencia mayor no es redondeo sino un concepto que el desglose no modela
 * (una propina voluntaria, un descuento suelto); meterla en la propina de ley
 * la declararia mal, asi que se deja el descuadre a la vista.
 */
export function reconcileNonBillable(
  nonBillable: number,
  declaredTotal: number,
  chargedTotal: number,
  lineCount: number,
): number {
  if (nonBillable <= 0 || !(chargedTotal > 0)) return nonBillable;

  const drift = r2(chargedTotal - declaredTotal - nonBillable);
  if (drift === 0) return nonBillable;

  // +1 para el redondeo del propio total, ademas de un centavo por linea.
  const tolerance = r2((lineCount + 1) * 0.01);
  if (Math.abs(drift) > tolerance) return nonBillable;

  const ajustado = r2(nonBillable + drift);
  return ajustado > 0 ? ajustado : nonBillable;
}

export function buildAlanubePayload(
  doc: FiscalDocument,
  sender: Sender,
  items: OrderItem[],
  ecfBreakdown: EcfTaxBreakdown | null,
  /**
   * ULID de la empresa en Alanube. Va en el CUERPO como `company.id` — no en
   * un header ni en la ruta. Es lo que le dice a Alanube que emita por una
   * compañía distinta a la principal de la cuenta. Sin esto, una empresa
   * `associated` (cada cliente de MangoPOS lo es) se emite contra la principal
   * y Alanube devuelve AP1016 "Sender RNC not match with company
   * identification", porque el RNC del sender es el del cliente y el de la
   * compañía resuelta es el de MangoPOS.
   */
  alanubeCompanyId?: string | null,
  /**
   * Fecha de vencimiento de la secuencia e-NCF, tal como la autorizo la DGII
   * (`ncf_sequences.expiration_date`, formato YYYY-MM-DD). NO se inventa: la
   * DGII la valida contra la autorizacion del rango y devuelve el codigo 145
   * ("Fecha de vencimiento de secuencia invalida") si no cuadra. Si no viene,
   * el campo no se manda — `emit-document` bloquea antes la emision de los
   * tipos que la exigen para no quemar un e-NCF en un rechazo seguro.
   */
  sequenceDueDate?: string | null,
  /**
   * Comprobante que la nota de credito anula. Obligatorio para E34: la DGII
   * valida el e-NCF referenciado y Alanube retiene la nota hasta que ese
   * documento llegue a un estado final (AP3012 si fue rechazado).
   */
  modifiedDoc?: ModifiedDocumentRef | null,
): Record<string, unknown> {
  const stampDate = (doc.issued_at ?? new Date().toISOString()).slice(0, 10);
  const isE31OrCreditDoc = doc.ncf_type === "E31";
  const totalAbove250k = Number(doc.total ?? 0) >= 250_000;
  const buyerRequired = isE31OrCreditDoc || (doc.ncf_type === "E32" && totalAbove250k);

  const idDoc: Record<string, unknown> = {
    encf: doc.ncf_number,
    paymentType: 1,
    incomeType: 1,
  };
  // E32 (consumo) va SIN fecha de vencimiento a proposito: la DGII no se la
  // asigna (la autorizacion dice "N/A"), y el esquema de notas de credito
  // tampoco tiene el campo. Donde SI va, tiene que ser LA DE LA AUTORIZACION,
  // no una calculada.
  if (TYPES_WITH_SEQUENCE_DUE_DATE.includes(doc.ncf_type) && sequenceDueDate) {
    idDoc.sequenceDueDate = sequenceDueDate.slice(0, 10);
  }

  // ── Nota de credito ────────────────────────────────────────────────────
  // creditNoteIndicator = 1 cuando la nota sale mas de 30 dias calendario
  // despues del comprobante que anula: pasado ese plazo la DGII no deja
  // rebajar el ITBIS. Se calcula, no se pregunta.
  let informationReference: Record<string, unknown> | undefined;
  if (isCreditNoteType(doc.ncf_type)) {
    const modifiedDate = (modifiedDoc?.issued_at ?? "").slice(0, 10);
    idDoc.creditNoteIndicator = daysBetween(modifiedDate, stampDate) > 30 ? 1 : 0;
    if (modifiedDoc) {
      informationReference = {
        ncfModified: modifiedDoc.ncf_number,
        ncfModificationDate: modifiedDate,
        // 1 = anula el comprobante de referencia. Con este codigo la DGII
        // exige que el total de la nota sea IGUAL al del original.
        modificationCode: doc.modification_code ?? 1,
      };
      const reason = (doc.modification_reason ?? "").trim();
      if (reason) informationReference.modificationReason = reason.slice(0, 250);
    }
  }

  const senderPayload: Record<string, unknown> = {
    rnc: sender.rnc,
    companyName: sender.companyName,
    address: sender.address,
    stampDate,
  };
  if (sender.tradename) senderPayload.tradename = sender.tradename;
  if (sender.branchOffice) senderPayload.branchOffice = sender.branchOffice;
  if (sender.mail) senderPayload.mail = sender.mail;

  let buyer: Record<string, unknown> | undefined;
  if (buyerRequired || doc.customer_rnc || (doc.customer_name && doc.customer_name !== "Consumidor Final")) {
    buyer = { companyName: doc.customer_name || "Consumidor Final" };
    if (doc.customer_rnc) buyer.rnc = doc.customer_rnc;
    if (doc.customer_address) buyer.address = doc.customer_address;
  }

  const amountOf = (it: OrderItem): number =>
    Number(it.subtotal ?? Number(it.quantity ?? 1) * Number(it.unit_price ?? 0));

  // DGII rechaza lineas en cero o negativas (AP10073). Las lineas negativas
  // vienen del modelo de ofertas, que mete la unidad gratis como linea en
  // negativo. Un descuento va en el campo de descuento de la linea, nunca
  // como una linea aparte, asi que aqui simplemente no se declaran.
  const billable = items.filter((it) => amountOf(it) > 0);

  const itbis = ecfBreakdown?.itbisAmount ?? Number(doc.itbis_amount ?? 0);
  const taxable = ecfBreakdown?.taxableAmount ?? Number(doc.taxable_amount ?? 0);
  const itbisRate = Math.round(ecfBreakdown?.effectiveRatePct ?? 18);

  // IndicadorMontoGravado (validacion 176 de la DGII: "el campo del area IdDoc
  // no es valido" cuando falta). Es condicional a que el comprobante lleve
  // ITBIS, y dice si el monto de CADA LINEA ya lo incluye.
  //
  // Va en 0 siempre: `itemAmount` es la base imponible y `unitPriceItem` se
  // deriva de ella, asi que las lineas NUNCA llevan el impuesto adentro (por
  // eso el ITBIS viaja aparte en `totals`). Mandar 1 haria que la DGII
  // recalculara la base sacandole el impuesto a lo que ya es base.
  //
  // E32 queda fuera A PROPOSITO: hoy pasa sin el campo en produccion y no se
  // toca lo que ya funciona; el 176 solo aparecio en E31.
  if (doc.ncf_type !== "E32" && itbis > 0) {
    idDoc.taxAmountIndicator = 0;
  }

  // Las lineas se reconcilian contra su propia suma redondeada, NO contra
  // `taxable`. Cuando todo el pedido esta gravado las dos cifras son la
  // misma (taxable es toFixed(2) de esa suma). Pero si el negocio tiene
  // productos sin impuesto vinculado en menu_item_taxes, `taxable` solo
  // cuenta los gravados y quedaria por debajo de la suma de lineas: forzar
  // el ajuste contra ese numero deformaria montos que estan bien. La
  // diferencia entre ambos es la porcion exenta y va en `exemptAmount`.
  const reconcileTarget = r2(
    billable.reduce((acc, it) => acc + amountOf(it), 0),
  );

  const amounts = roundAndReconcile(billable.map(amountOf), reconcileTarget);

  // La porcion exenta se DERIVA: todo lo facturado que no entro a la base
  // gravada. `fiscal_documents.tax_exempt` existe como columna pero NADIE la
  // escribe nunca (default 0), asi que leerla dejaba los productos exentos
  // fuera del total declarado: un pedido de cafe 211.86 + agua 100 declaraba
  // totalAmount 250 con las lineas sumando 311.86. Sin esto, todo negocio que
  // venda algo exento manda un comprobante que no cuadra consigo mismo.
  // Sin desglose (orden legacy) se cae a la columna, que es lo que habia.
  const exempt = ecfBreakdown != null
    ? Math.max(0, r2(reconcileTarget - taxable))
    : Number(doc.tax_exempt ?? 0);

  const itemDetails: Array<Record<string, unknown>> = billable.length > 0
    ? billable.map((it, idx) => {
        // El indicador sale de la tasa ITBIS que de verdad entra al e-CF, NO de
        // `order_items.tax_rate`: ese guarda la tasa TOTAL cobrada (ITBIS 18 +
        // Ley 10 = 28) y 28 no cae en ningun rango de ITBIS, asi que la linea
        // salia declarada EXENTA mientras el encabezado llevaba itbis_amount.
        // Sin lineas de impuesto (orden legacy) se cae a tax_rate como antes.
        const ecfRate = ecfBreakdown?.ratePctByItem.get(it.id);
        const rateForIndicator = ecfRate ?? it.tax_rate;

        // `itemAmount` es la base imponible (subtotal). El precio unitario
        // tiene que ser coherente con ella: mandar `unit_price` crudo declara
        // el precio CON impuesto cuando tax_mode es inclusive, y entonces
        // cantidad x precio != monto de linea.
        const qty = Number(it.quantity ?? 1);
        const unitPrice = qty > 0 ? r2(amounts[idx] / qty) : r2(amounts[idx]);

        return {
          lineNumber: idx + 1,
          billingIndicator: billingIndicatorFromTaxRate(rateForIndicator),
          itemName: (it.product_name ?? "Producto").slice(0, 80),
          goodServiceIndicator: 1,
          quantityItem: qty,
          unitPriceItem: unitPrice,
          itemAmount: amounts[idx],
        };
      })
    : [{
        lineNumber: 1,
        billingIndicator: billingIndicatorFromTaxRate(0.18),
        itemName: "Venta general",
        goodServiceIndicator: 1,
        quantityItem: 1,
        unitPriceItem: r2(Number(doc.total ?? 0)),
        itemAmount: r2(Number(doc.total ?? 0)),
      }];

  const declaredTotal = ecfBreakdown != null
    ? r2(taxable + itbis + exempt)
    : Number(doc.total ?? 0);

  // La propina de ley se le cobro al cliente pero no forma parte de la base
  // gravada ni del ITBIS. DGII la recibe como linea NO FACTURABLE
  // (`billingIndicator: 0`), que es lo que alimenta `nonBillableAmount`; asi
  // `payValue` (valor cobrado) cuadra con el ticket que se lleva el cliente
  // sin deformar `totalAmount`, que Alanube define como
  // "Monto Gravado Total + Monto exento + Total ITBIS + Impuesto adicional".
  //
  // El monto se cuadra contra `doc.total` — lo que de verdad se cobro — porque
  // sumar las lineas de impuesto YA redondeadas no siempre da esa cifra.
  const nonBillable = reconcileNonBillable(
    r2(Number(ecfBreakdown?.excludedTaxAmount ?? 0)),
    declaredTotal,
    Number(doc.total ?? 0),
    billable.length,
  );
  if (nonBillable > 0) {
    itemDetails.push({
      lineNumber: itemDetails.length + 1,
      billingIndicator: 0,
      itemName: (ecfBreakdown?.excludedTaxName ?? "Propina legal").slice(0, 80),
      goodServiceIndicator: 2, // 2 = Servicio
      quantityItem: 1,
      unitPriceItem: nonBillable,
      itemAmount: nonBillable,
    });
  }

  const totals: Record<string, unknown> = {
    totalAmount: r2(declaredTotal),
  };
  if (nonBillable > 0) {
    totals.nonBillableAmount = nonBillable;
    // MontoPeriodo: Alanube lo define como "suma de Monto Total y Monto no
    // Facturable". Faltaba, y sin el la DGII cuadra el ValorPagar contra el
    // MontoTotal pelado — le sobra la propina y devuelve la observacion 11153
    // ("ValorPagar no coincide con SaldoAnterior + MontoAvancePago +
    // MontoTotal"). Con MontoPeriodo declarado, los tres numeros cierran:
    // 736.22 facturable + 63.78 de Ley = 800.00 cobrado.
    totals.amountPeriod = r2(declaredTotal + nonBillable);
    totals.payValue = r2(declaredTotal + nonBillable);
  }
  if (taxable > 0) {
    totals.totalTaxedAmount = r2(taxable);
    totals.i1AmountTaxed = r2(taxable);
    totals.itbisS1 = itbisRate;
    totals.itbis1Total = r2(itbis);
    totals.itbisTotal = r2(itbis);
  }
  if (exempt > 0) totals.exemptAmount = r2(exempt);

  const payload: Record<string, unknown> = {
    idDoc,
    sender: senderPayload,
    totals,
    itemDetails,
  };
  if (buyer) payload.buyer = buyer;
  if (informationReference) payload.informationReference = informationReference;
  if (alanubeCompanyId) payload.company = { id: alanubeCompanyId };

  return payload;
}
