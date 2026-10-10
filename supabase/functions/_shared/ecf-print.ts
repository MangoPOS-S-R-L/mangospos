// Datos de la representacion impresa (RI) de un e-CF, segun el "Informe
// Tecnico e-CF" de la DGII (seccion 18): encabezado con el tipo en palabras,
// e-NCF, vencimiento y, en notas, el e-NCF modificado y el codigo de
// modificacion en palabras; emisor; cliente; detalle; totales; y el QR con el
// codigo de seguridad y la fecha de firma debajo.
//
// Se arma de los mismos datos que se firmaron (las columnas del caso y el XML
// firmado), para que la RI diga lo mismo que el e-CF. El panel solo la dibuja.

import { locationName, unitName } from "./dgii-catalogs.ts";
import { CONSUMPTION_SUMMARY_LIMIT, TestSetField } from "./ecf-test-set.ts";

/** Consulta de timbre del ambiente de certificacion (los del QR). */
export const TIMBRE_ECF_URL = "https://ecf.dgii.gov.do/certecf/ConsultaTimbre";
export const TIMBRE_FC_URL = "https://fc.dgii.gov.do/certecf/ConsultaTimbreFC";

export const ECF_TYPE_NAMES: Readonly<Record<string, string>> = {
  "31": "Factura de Crédito Fiscal Electrónica",
  "32": "Factura de Consumo Electrónica",
  "33": "Nota de Débito Electrónica",
  "34": "Nota de Crédito Electrónica",
  "41": "Comprobante Electrónico de Compras",
  "43": "Comprobante Electrónico para Gastos Menores",
  "44": "Comprobante Electrónico para Regímenes Especiales",
  "45": "Comprobante Electrónico Gubernamental",
  "46": "Comprobante Electrónico para Exportaciones",
  "47": "Comprobante Electrónico para Pagos al Exterior",
};

const MODIFICATION_CODES: Readonly<Record<string, string>> = {
  "1": "Anula el NCF modificado",
  "2": "Corrige Texto del Comprobante Fiscal modificado",
  "3": "Corrige montos del NCF modificado",
  "4": "Reemplazo NCF emitido en contingencia",
  "5": "Referencia Factura Consumo Electrónica",
};

export interface PrintItem {
  line: string;
  quantity: string | null;
  /** Indicador de facturacion 4: la RI pone "E" delante de la descripcion. */
  exempt: boolean;
  description: string;
  detail: string | null;
  unit: string | null;
  price: string | null;
  itbis: string | null;
  discount: string | null;
  surcharge: string | null;
  value: string | null;
}

export interface PrintAdjustment {
  description: string;
  kind: "D" | "R" | string;
  percent: string | null;
  amount: string | null;
}

export interface PrintModel {
  type_code: string;
  type_name: string;
  encf: string;
  due_date: string | null;
  modified_encf: string | null;
  modified_date: string | null;
  modification: string | null;
  modification_reason: string | null;
  issuer: {
    trade_name: string | null;
    legal_name: string | null;
    branch: string | null;
    rnc: string;
    address: string | null;
    municipality: string | null;
    province: string | null;
    phone: string | null;
    email: string | null;
    issue_date: string | null;
  };
  buyer: { name: string | null; rnc: string | null; foreign_id: string | null } | null;
  items: PrintItem[];
  adjustments: PrintAdjustment[];
  totals: {
    taxed: string | null;
    exempt: string | null;
    itbis: string | null;
    additional_taxes: string | null;
    itbis_withheld: string | null;
    isr_withheld: string | null;
    total: string | null;
  };
  currency: { code: string; rate: string | null; total: string | null } | null;
  /** Fecha de firma digital (FechaHoraFirma), dd-MM-yyyy HH:mm:ss. */
  signed_at: string;
  security_code: string;
  qr_url: string;
  /** Factura de consumo menor de 250 mil: QR de consulta de consumo. */
  consumer_summary: boolean;
}

function getter(fields: TestSetField[]) {
  const map = new Map(fields.map(([c, v]) => [c.trim().toLowerCase(), v.trim()]));
  return (column: string): string | null => {
    const v = map.get(column.toLowerCase());
    return v === undefined || v.length === 0 ? null : v;
  };
}

function money(n: number): string {
  return (Math.round(n * 100) / 100).toFixed(2);
}

/** ITBIS de una linea, con la tasa de su indicador de facturacion. */
function lineItbis(
  indicator: string | null,
  amount: string | null,
  rates: Record<string, number>,
  pricesIncludeItbis: boolean,
): string | null {
  if (!indicator || !amount || indicator === "4" || indicator === "0") return null;
  const rate = rates[indicator];
  const value = Number(amount);
  if (rate === undefined || !Number.isFinite(value)) return null;
  return money(pricesIncludeItbis ? value - value / (1 + rate / 100) : value * rate / 100);
}

/**
 * URL del QR. Factura de consumo menor de 250 mil: RNC emisor, e-NCF, monto y
 * codigo. Los demas: ademas comprador (si hay), fechas de emision y firma.
 */
export function timbreUrl(p: {
  rncEmisor: string;
  rncComprador: string | null;
  encf: string;
  fechaEmision: string | null;
  montoTotal: string;
  fechaFirma: string;
  codigoSeguridad: string;
  consumerSummary: boolean;
}): string {
  const q = (k: string, v: string) => `${k}=${encodeURIComponent(v)}`;
  if (p.consumerSummary) {
    return `${TIMBRE_FC_URL}?${[
      q("RncEmisor", p.rncEmisor),
      q("ENCF", p.encf),
      q("MontoTotal", p.montoTotal),
      q("CodigoSeguridad", p.codigoSeguridad),
    ].join("&")}`;
  }
  return `${TIMBRE_ECF_URL}?${[
    q("RncEmisor", p.rncEmisor),
    ...(p.rncComprador ? [q("RncComprador", p.rncComprador)] : []),
    q("ENCF", p.encf),
    q("FechaEmision", p.fechaEmision ?? ""),
    q("MontoTotal", p.montoTotal),
    q("FechaFirma", p.fechaFirma),
    q("CodigoSeguridad", p.codigoSeguridad),
  ].join("&")}`;
}

/** Modelo de la RI de un e-CF ya firmado. */
export function buildPrintModel(fields: TestSetField[], signedXml: string): PrintModel {
  const get = getter(fields);
  const type = get("TipoeCF") ?? "";
  const encf = (get("ENCF") ?? get("eNCF") ?? "").toUpperCase();
  const signedAt = /<FechaHoraFirma>([^<]+)<\/FechaHoraFirma>/.exec(signedXml)?.[1]?.trim() ?? "";
  const code = /<SignatureValue>([^<]+)<\/SignatureValue>/.exec(signedXml)?.[1]?.trim().slice(0, 6) ?? "";
  if (!signedAt || code.length < 6) throw new Error(`${encf}: el XML firmado no trae FechaHoraFirma o la firma.`);

  const rates: Record<string, number> = {
    "1": Number(get("ITBIS1") ?? 18),
    "2": Number(get("ITBIS2") ?? 16),
    "3": Number(get("ITBIS3") ?? 0),
  };
  const pricesIncludeItbis = get("IndicadorMontoGravado") === "1";

  const lines = new Set<number>();
  for (const [c] of fields) {
    const m = /^NumeroLinea\[(\d+)\]$/i.exec(c.trim());
    if (m) lines.add(Number(m[1]));
  }
  const items: PrintItem[] = [...lines].sort((a, b) => a - b).map((i) => {
    const indicator = get(`IndicadorFacturacion[${i}]`);
    const value = get(`MontoItem[${i}]`);
    return {
      line: get(`NumeroLinea[${i}]`) ?? String(i),
      quantity: get(`CantidadItem[${i}]`),
      exempt: indicator === "4",
      description: get(`NombreItem[${i}]`) ?? "",
      detail: get(`DescripcionItem[${i}]`),
      unit: unitName(get(`UnidadMedida[${i}]`)),
      price: get(`PrecioUnitarioItem[${i}]`),
      itbis: lineItbis(indicator, value, rates, pricesIncludeItbis),
      discount: get(`DescuentoMonto[${i}]`),
      surcharge: get(`RecargoMonto[${i}]`),
      value,
    };
  });

  const adjustments: PrintAdjustment[] = [];
  for (const [c] of fields) {
    const m = /^NumeroLineaDoR\[(\d+)\]$/i.exec(c.trim());
    if (!m) continue;
    const i = m[1];
    adjustments.push({
      description: get(`DescripcionDescuentooRecargo[${i}]`) ?? "",
      kind: get(`TipoAjuste[${i}]`) ?? "",
      percent: get(`TipoValor[${i}]`) === "%" ? get(`ValorDescuentooRecargo[${i}]`) : null,
      amount: get(`MontoDescuentooRecargo[${i}]`),
    });
  }

  const total = get("MontoTotal") ?? "0.00";
  const consumerSummary = type === "32" && Number(total) < CONSUMPTION_SUMMARY_LIMIT;
  const rncEmisor = get("RNCEmisor") ?? "";
  const rncComprador = get("RNCComprador");
  const buyerName = get("RazonSocialComprador");
  const foreignId = get("IdentificadorExtranjero");
  const currencyCode = get("TipoMoneda");

  return {
    type_code: type,
    type_name: ECF_TYPE_NAMES[type] ?? `e-CF ${type}`,
    encf,
    // La nota de credito y la factura de consumo no llevan vencimiento en la RI.
    due_date: type === "34" || type === "32" ? null : get("FechaVencimientoSecuencia"),
    modified_encf: get("NCFModificado"),
    modified_date: get("FechaNCFModificado"),
    modification: (() => {
      const c = get("CodigoModificacion");
      return c ? MODIFICATION_CODES[c] ?? c : null;
    })(),
    modification_reason: get("RazonModificacion"),
    issuer: {
      trade_name: get("NombreComercial"),
      legal_name: get("RazonSocialEmisor"),
      branch: get("Sucursal"),
      rnc: rncEmisor,
      address: get("DireccionEmisor"),
      municipality: locationName(get("Municipio")),
      province: locationName(get("Provincia")),
      phone: get("TelefonoEmisor[1]"),
      email: get("CorreoEmisor"),
      issue_date: get("FechaEmision"),
    },
    buyer: buyerName || rncComprador || foreignId ? { name: buyerName, rnc: rncComprador, foreign_id: foreignId } : null,
    items,
    adjustments,
    totals: {
      taxed: get("MontoGravadoTotal"),
      exempt: get("MontoExento"),
      itbis: get("TotalITBIS"),
      additional_taxes: get("MontoImpuestoAdicional"),
      itbis_withheld: get("TotalITBISRetenido"),
      isr_withheld: get("TotalISRRetencion"),
      total,
    },
    currency: currencyCode
      ? { code: currencyCode, rate: get("TipoCambio"), total: get("MontoTotalOtraMoneda") }
      : null,
    signed_at: signedAt,
    security_code: code,
    qr_url: timbreUrl({
      rncEmisor,
      rncComprador,
      encf,
      fechaEmision: get("FechaEmision"),
      montoTotal: total,
      fechaFirma: signedAt,
      codigoSeguridad: code,
      consumerSummary,
    }),
    consumer_summary: consumerSummary,
  };
}
