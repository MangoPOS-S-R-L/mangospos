// Preflight de activacion e-CF: logica PURA, sin red ni base de datos, para
// que el chequeo que impide firmar con el certificado de otro contribuyente
// sea verificable con tests.
//
// Lo consume `provision-ecf`, que solo pone el I/O (auth, Alanube, Supabase).

export type CheckLevel = "ok" | "warn" | "fail";

export interface Check {
  key: string;
  level: CheckLevel;
  message: string;
  detail?: unknown;
}

export interface AlanubeCompany {
  id?: string;
  name?: string;
  tradeName?: string;
  identification?: string;
  address?: string;
  province?: string;
  municipality?: string;
  email?: string;
  type?: string;
  certificationStep?: number;
  webhooks?: Record<string, unknown>;
  certificate?: { name?: string; startDate?: string; endDate?: string };
}

export interface SequenceRow {
  ncf_type: string;
  range_start: number;
  range_end: number;
  current_number: number;
  expiration_date: string | null;
  is_active: boolean | null;
}

export interface ItemTaxCounts {
  total: number;
  /** Sin NINGUN impuesto vinculado: casi siempre es un error de configuracion. */
  sinImpuesto: number;
  /** Con impuestos, pero ninguno entra al e-CF (ej. solo Ley 10%): se declaran
   *  EXENTOS. Puede ser correcto — el agua embotellada lo esta en RD. */
  soloExcluidos: number;
}

export interface PreflightInput {
  fiscal: { rnc: string | null; business_legal_name: string | null } | null;
  business: { address: string | null };
  company: AlanubeCompany;
  sequences: SequenceRow[];
  /** null cuando la consulta fallo: se reporta como warn, no como ok. */
  itemTaxes: ItemTaxCounts | null;
  webhookPath: string;
  now?: Date;
}

/** Tipos de e-CF que `emit-document` sabe mandar (getEndpointForNcfType). */
export const EMITTABLE_ECF_TYPES = ["E31", "E32", "E44", "E45"];

/** Solo digitos: el RNC se teclea con guiones o sin ellos segun quien lo meta. */
export function normalizeRnc(v: string | null | undefined): string {
  return (v ?? "").replace(/\D/g, "");
}

/** Mayusculas, sin acentos ni puntuacion, espacios colapsados. */
export function normalizeText(v: string | null | undefined): string {
  return (v ?? "")
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "")
    .toUpperCase()
    .replace(/[^A-Z0-9 ]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

/**
 * El ambiente real sale de ALANUBE_BASE_URL, que es global al stack — no de lo
 * que pida el caller. `business_alanube_settings.environment` hoy no lo lee
 * nadie; al menos que quede escrito lo que de verdad esta pasando.
 */
export function environmentFromBaseUrl(baseUrl: string): "sandbox" | "production" {
  return baseUrl.toLowerCase().includes("sandbox") ? "sandbox" : "production";
}

export function worstLevel(checks: Check[]): CheckLevel {
  if (checks.some((c) => c.level === "fail")) return "fail";
  if (checks.some((c) => c.level === "warn")) return "warn";
  return "ok";
}

/** Alanube devuelve "2027-04-23 21:30:54" (espacio, no ISO). */
function parseAlanubeDate(v: string | null | undefined): Date | null {
  if (!v) return null;
  const d = new Date(v.replace(" ", "T"));
  return Number.isNaN(d.getTime()) ? null : d;
}

export function buildChecks(input: PreflightInput): Check[] {
  const { fiscal, business, company, sequences, itemTaxes, webhookPath } = input;
  const now = input.now ?? new Date();
  const checks: Check[] = [];

  // ── RNC: el unico chequeo que jamas se salta ──────────────────────────
  const rncDb = normalizeRnc(fiscal?.rnc);
  const rncAlanube = normalizeRnc(company.identification);
  if (rncDb.length === 0) {
    checks.push({
      key: "rnc",
      level: "fail",
      message: "El negocio no tiene RNC en Ajustes -> Fiscal. Sin RNC no se puede emitir.",
    });
  } else if (rncAlanube.length === 0) {
    checks.push({
      key: "rnc",
      level: "fail",
      message: "La empresa en Alanube no tiene RNC registrado.",
    });
  } else if (rncDb !== rncAlanube) {
    checks.push({
      key: "rnc",
      level: "fail",
      message:
        `El RNC no coincide: el negocio tiene ${rncDb} y esa empresa de Alanube es ` +
        `${rncAlanube} (${company.name ?? "sin nombre"}). Activar asi firmaria los ` +
        `comprobantes con el certificado de otro contribuyente.`,
      detail: { rnc_negocio: rncDb, rnc_alanube: rncAlanube, empresa: company.name },
    });
  } else {
    checks.push({
      key: "rnc",
      level: "ok",
      message: `RNC ${rncDb} coincide con ${company.name ?? "la empresa en Alanube"}.`,
    });
  }

  // ── Certificado digital: sin el, Alanube no puede firmar ──────────────
  const cert = company.certificate;
  const certEnd = parseAlanubeDate(cert?.endDate);
  if (!cert || !cert.name) {
    checks.push({
      key: "certificate",
      level: "fail",
      message: "La empresa no tiene certificado digital cargado en Alanube.",
    });
  } else if (certEnd && certEnd.getTime() < now.getTime()) {
    checks.push({
      key: "certificate",
      level: "fail",
      message: `El certificado "${cert.name}" vencio el ${cert.endDate}.`,
    });
  } else {
    checks.push({
      key: "certificate",
      level: "ok",
      message: `Certificado "${cert.name}" activo${cert.endDate ? `, vence ${cert.endDate}` : ""}.`,
      detail: { name: cert.name, endDate: cert.endDate },
    });
  }

  // ── Razon social ──────────────────────────────────────────────────────
  const legalDb = normalizeText(fiscal?.business_legal_name);
  const legalAlanube = normalizeText(company.name);
  if (legalDb.length > 0 && legalAlanube.length > 0 && legalDb !== legalAlanube) {
    checks.push({
      key: "legal_name",
      level: "warn",
      message:
        `La razon social difiere: "${fiscal?.business_legal_name}" en el sistema, ` +
        `"${company.name}" en Alanube. Se declara la del sistema.`,
    });
  } else {
    checks.push({ key: "legal_name", level: "ok", message: "Razon social coincide." });
  }

  // ── Direccion ─────────────────────────────────────────────────────────
  // Puede diferir con razon: el domicilio fiscal no tiene por que ser el local
  // donde se opera. Por eso es warn y no fail. Hoy el emisor manda
  // `businesses.address`, que es la de operacion.
  const addrDb = normalizeText(business.address);
  const addrAlanube = normalizeText(company.address);
  if (addrDb.length === 0) {
    checks.push({
      key: "address",
      level: "fail",
      message: "El negocio no tiene direccion. El emisor aborta sin ella.",
    });
  } else if (addrAlanube.length > 0 && addrDb !== addrAlanube) {
    checks.push({
      key: "address",
      level: "warn",
      message:
        `La direccion del sistema ("${business.address}") no es la registrada en ` +
        `Alanube ("${company.address}"). Se declara la del sistema en cada e-CF. Si ` +
        `la de Alanube es el domicilio fiscal, hay que decidir cual va en el comprobante.`,
      detail: { sistema: business.address, alanube: company.address },
    });
  } else {
    checks.push({ key: "address", level: "ok", message: "Direccion coincide." });
  }

  // ── Webhooks: sin ellos ningun doc pasa de `sent` a `accepted` ────────
  const webhooksRaw = JSON.stringify(company.webhooks ?? {});
  if (!webhooksRaw.includes(webhookPath)) {
    checks.push({
      key: "webhooks",
      level: "warn",
      message:
        "Alanube no tiene webhooks apuntando a alanube-webhook. Los comprobantes se " +
        "quedarian en 'sent' sin llegar nunca a 'accepted'.",
    });
  } else {
    checks.push({
      key: "webhooks",
      level: "ok",
      message: "Webhooks configurados hacia alanube-webhook.",
    });
  }

  // ── Secuencias e-NCF ──────────────────────────────────────────────────
  const live = sequences.filter(
    (s) =>
      EMITTABLE_ECF_TYPES.includes(s.ncf_type) &&
      s.is_active === true &&
      Number(s.current_number) < Number(s.range_end),
  );
  if (live.length === 0) {
    checks.push({
      key: "sequences",
      level: "fail",
      message:
        "No hay ninguna secuencia e-NCF activa con numeros disponibles (E31/E32/E44/E45). " +
        "Cargalas desde la autorizacion de la DGII antes de activar.",
    });
  } else {
    // E32 (consumo) va SIN fecha de vencimiento a proposito: la DGII no se la
    // asigna (la autorizacion dice "N/A") y el emisor tampoco manda
    // sequenceDueDate para ese tipo. Solo se avisa por los tipos que si la
    // exigen, donde emit-document bloquea la emision hasta que se cargue.
    const sinVencimiento = live.filter(
      (s) => s.ncf_type !== "E32" && s.expiration_date == null,
    );
    checks.push({
      key: "sequences",
      level: sinVencimiento.length > 0 ? "warn" : "ok",
      message: sinVencimiento.length > 0
        ? `Secuencias activas: ${live.map((s) => s.ncf_type).join(", ")}. Sin fecha de ` +
          `vencimiento: ${sinVencimiento.map((s) => s.ncf_type).join(", ")} — esos tipos ` +
          `NO se pueden emitir (la DGII los rechaza con el codigo 145). Carga la fecha ` +
          `de la autorizacion en Ajustes > Comprobantes fiscales.`
        : `Secuencias activas: ${live.map((s) => s.ncf_type).join(", ")}.`,
      detail: live.map((s) => ({
        ncf_type: s.ncf_type,
        disponibles: Number(s.range_end) - Number(s.current_number),
        expiration_date: s.expiration_date,
      })),
    });
  }

  // ── Secuencia de notas de credito ─────────────────────────────────────
  // Anular una factura electronica ya aceptada solo se puede con una nota de
  // credito E34. Sin secuencia cargada, la anulacion ocurre igual pero la nota
  // queda pendiente y el negocio termina declarando ITBIS que devolvio.
  const creditNoteSeq = sequences.find(
    (s) =>
      s.ncf_type === "E34" &&
      s.is_active === true &&
      Number(s.current_number) < Number(s.range_end),
  );
  checks.push({
    key: "credit_note_sequence",
    level: creditNoteSeq ? "ok" : "warn",
    message: creditNoteSeq
      ? `Secuencia E34 (notas de credito) disponible: ${
        Number(creditNoteSeq.range_end) - Number(creditNoteSeq.current_number)
      } numeros.`
      : "No hay secuencia E34 (nota de credito). Sin ella no se puede anular " +
        "ante la DGII una factura electronica ya aceptada: la anulacion queda " +
        "solo en el POS y la nota, pendiente.",
    detail: creditNoteSeq
      ? { disponibles: Number(creditNoteSeq.range_end) - Number(creditNoteSeq.current_number) }
      : undefined,
  });

  // ── Paso de certificacion segun Alanube ───────────────────────────────
  // Informativo: la semantica del contador es de Alanube, y el negocio puede
  // estar certificado ante la DGII con el contador sin actualizar.
  if (typeof company.certificationStep === "number") {
    checks.push({
      key: "certification_step",
      level: company.certificationStep >= 4 ? "ok" : "warn",
      message:
        `Alanube reporta certificationStep = ${company.certificationStep}. Confirma ` +
        `que la DGII ya autorizo a este contribuyente antes de emitir.`,
      detail: { certificationStep: company.certificationStep },
    });
  }

  // ── Productos sin impuesto vinculado ──────────────────────────────────
  // menu_item_taxes es la UNICA fuente del ITBIS: sin vinculo, el producto va
  // con impuesto 0 al comprobante.
  if (itemTaxes === null) {
    checks.push({
      key: "item_taxes",
      level: "warn",
      message: "No se pudo verificar el vinculo de impuestos de los productos.",
    });
  } else if (itemTaxes.sinImpuesto > 0) {
    checks.push({
      key: "item_taxes",
      level: "warn",
      message:
        `${itemTaxes.sinImpuesto} de ${itemTaxes.total} productos activos no tienen ` +
        `NINGUN impuesto vinculado: irian al e-CF con ITBIS 0.`,
      detail: itemTaxes,
    });
  } else {
    checks.push({
      key: "item_taxes",
      level: "ok",
      message: `Los ${itemTaxes.total} productos activos tienen impuesto vinculado.`,
      detail: itemTaxes,
    });
  }

  // Aparte del error de configuracion: los que SI tienen impuestos pero ninguno
  // entra al e-CF (tipico: solo la Ley 10%). Se declaran exentos, y eso puede
  // estar perfectamente bien — el agua embotellada esta exenta de ITBIS en RD.
  // Se informa para que quien activa lo revise, no para bloquear.
  if (itemTaxes !== null && itemTaxes.soloExcluidos > 0) {
    checks.push({
      key: "item_taxes_exentos",
      level: "warn",
      message:
        `${itemTaxes.soloExcluidos} productos activos se declararan EXENTOS de ITBIS ` +
        `(tienen impuestos, pero ninguno entra al e-CF). Confirma que corresponde.`,
      detail: { soloExcluidos: itemTaxes.soloExcluidos, total: itemTaxes.total },
    });
  }

  return checks;
}
