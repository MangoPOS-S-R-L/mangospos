// Alta e-CF desde el panel de MangoPOS: logica PURA (validacion y armado de
// lo que viaja a Alanube y a la BD), sin red ni base de datos, para que sea
// verificable con tests.
//
// Lo consume `ecf-onboarding`, que solo pone el I/O (auth, Alanube, Supabase).

import { normalizeRnc } from "./ecf-preflight.ts";
import { TYPES_WITH_SEQUENCE_DUE_DATE } from "./ecf-payload.ts";

export type Validation<T> =
  | { ok: true; value: T }
  | { ok: false; errors: string[] };

// ── Datos del contribuyente ────────────────────────────────────────────────

export interface TaxpayerInput {
  rnc?: string | null;
  legal_name?: string | null;
  trade_name?: string | null;
  fiscal_address?: string | null;
  province?: string | null;
  municipality?: string | null;
  email?: string | null;
}

/** Lo que se guarda en `ecf_onboarding`. Cualquier campo puede faltar mientras
 *  el operador va capturando; `validateTaxpayer` con `forRegistration` exige
 *  los que Alanube pide para dar de alta. */
export interface TaxpayerData {
  rnc: string | null;
  legal_name: string | null;
  trade_name: string | null;
  fiscal_address: string | null;
  province: string | null;
  municipality: string | null;
  email: string | null;
}

/** Limites del esquema de `POST /company` de Alanube. */
export const MAX_ADDRESS_LENGTH = 100;
export const MAX_EMAIL_LENGTH = 80;

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

function clean(v: string | null | undefined): string | null {
  const t = (v ?? "").trim().replace(/\s+/g, " ");
  return t.length > 0 ? t : null;
}

export function validateTaxpayer(
  input: TaxpayerInput,
  opts: { forRegistration?: boolean } = {},
): Validation<TaxpayerData> {
  const errors: string[] = [];

  const rawRnc = clean(input.rnc);
  const rnc = rawRnc === null ? null : normalizeRnc(rawRnc);
  if (rawRnc !== null && rnc !== null && rnc.length !== 9 && rnc.length !== 11) {
    errors.push("El RNC debe tener 9 digitos (o 11 si es una cedula).");
  }

  const address = clean(input.fiscal_address);
  if (address !== null && address.length > MAX_ADDRESS_LENGTH) {
    errors.push(
      `La direccion fiscal tiene ${address.length} caracteres; Alanube acepta ` +
        `maximo ${MAX_ADDRESS_LENGTH}.`,
    );
  }

  const email = clean(input.email)?.toLowerCase() ?? null;
  if (email !== null) {
    if (email.length > MAX_EMAIL_LENGTH) {
      errors.push(`El correo supera los ${MAX_EMAIL_LENGTH} caracteres.`);
    } else if (!EMAIL_RE.test(email)) {
      errors.push("El correo no tiene un formato valido.");
    }
  }

  const value: TaxpayerData = {
    rnc: rnc && rnc.length > 0 ? rnc : null,
    legal_name: clean(input.legal_name),
    trade_name: clean(input.trade_name),
    fiscal_address: address,
    province: clean(input.province),
    municipality: clean(input.municipality),
    email,
  };

  if (opts.forRegistration) {
    if (!value.rnc) errors.push("Falta el RNC.");
    if (!value.legal_name) errors.push("Falta la razon social.");
    if (!value.fiscal_address) errors.push("Falta la direccion fiscal.");
  }

  return errors.length > 0 ? { ok: false, errors } : { ok: true, value };
}

// ── Certificado digital ────────────────────────────────────────────────────

export interface CertificateInput {
  filename?: string | null;
  content_base64?: string | null;
  password?: string | null;
}

export interface ValidCertificate {
  name: string;
  extension: "p12" | "pfx";
  content: string;
  password: string;
}

/** Un .p12 de firma pesa 3–10 KB. Cien KB ya es otra cosa. */
export const MAX_CERTIFICATE_BYTES = 100 * 1024;

const BASE64_RE = /^[A-Za-z0-9+/]+={0,2}$/;

export function validateCertificate(input: CertificateInput): Validation<ValidCertificate> {
  const errors: string[] = [];

  const filename = (input.filename ?? "").trim();
  const dot = filename.lastIndexOf(".");
  const ext = dot >= 0 ? filename.slice(dot + 1).toLowerCase() : "";
  if (ext !== "p12" && ext !== "pfx") {
    errors.push("El certificado tiene que ser un archivo .p12 o .pfx.");
  }

  // El navegador puede mandarlo como data URL; Alanube quiere base64 pelado.
  const content = (input.content_base64 ?? "")
    .replace(/^data:[^,]*,/, "")
    .replace(/\s+/g, "");
  let bytes: Uint8Array | null = null;
  if (content.length === 0) {
    errors.push("El archivo del certificado esta vacio.");
  } else if (content.length % 4 !== 0 || !BASE64_RE.test(content)) {
    errors.push("El contenido del certificado no es base64 valido.");
  } else {
    bytes = Uint8Array.from(atob(content), (c) => c.charCodeAt(0));
    if (bytes.length > MAX_CERTIFICATE_BYTES) {
      errors.push(
        `El certificado pesa ${Math.round(bytes.length / 1024)} KB; un .p12 de ` +
          `firma no pasa de ${MAX_CERTIFICATE_BYTES / 1024} KB. Revisa el archivo.`,
      );
    } else if (bytes[0] !== 0x30) {
      // PKCS#12 es DER: siempre arranca con SEQUENCE (0x30). Atrapa el PDF o la
      // foto del certificado antes de que Alanube responda algo criptico.
      errors.push("El archivo no parece un certificado .p12 (no es PKCS#12).");
    }
  }

  // La contrasena NO se recorta: un espacio puede ser parte de ella.
  const password = input.password ?? "";
  if (password.length === 0) {
    errors.push("Falta la contrasena del certificado.");
  }

  if (errors.length > 0) return { ok: false, errors };
  return {
    ok: true,
    value: {
      name: dot > 0 ? filename.slice(0, dot) : filename,
      extension: ext as "p12" | "pfx",
      content,
      password,
    },
  };
}

// ── Alta de la empresa en Alanube ──────────────────────────────────────────

/**
 * Webhooks con que nace la empresa. `emissionFinished` es el que mueve los
 * comprobantes de `sent` a `accepted`/`rejected`; `governmentStatusChanged`
 * avisa cambios de la empresa ante la DGII. Los dos van a `alanube-webhook`,
 * que valida el header X-Webhook-Secret.
 */
export function buildWebhooks(webhookUrl: string, secret: string) {
  const hook = {
    url: webhookUrl,
    headers: { "X-Webhook-Secret": secret },
    status: "active",
  };
  return {
    general: { governmentStatusChanged: hook },
    documents: { emissionFinished: hook },
  };
}

/** Body de `POST /company`. Siempre `associated`: la principal es MANGOPOS SRL. */
export function buildCompanyPayload(
  data: TaxpayerData,
  cert: ValidCertificate,
  webhooks: ReturnType<typeof buildWebhooks>,
): Record<string, unknown> {
  const payload: Record<string, unknown> = {
    name: data.legal_name,
    identification: data.rnc,
    type: "associated",
    address: data.fiscal_address,
    certificate: {
      name: cert.name,
      extension: cert.extension,
      content: cert.content,
      password: cert.password,
    },
    webhooks,
  };
  if (data.trade_name) payload.tradeName = data.trade_name;
  if (data.province) payload.province = data.province;
  if (data.municipality) payload.municipality = data.municipality;
  if (data.email) payload.email = data.email;
  return payload;
}

// ── Empresas asociadas ya dadas de alta ────────────────────────────────────

export interface AssociatedCompany {
  id: string;
  name?: string;
  tradeName?: string;
  identification?: string;
  address?: string;
  type?: string;
  certificationStep?: number;
  certificate?: { name?: string; issuerName?: string; startDate?: string; endDate?: string };
  companyUrls?: { reception?: string; approval?: string; authentication?: string };
}

/** Una pagina de `GET /companies/associated`. `next` es el cursor `from` de la
 *  siguiente; null cuando no hay mas. */
export function parseAssociatedPage(body: unknown): {
  companies: AssociatedCompany[];
  next: string | null;
} {
  const b = (body ?? {}) as {
    associatedCompanies?: unknown;
    metadata?: { to?: unknown };
  };
  const list = Array.isArray(b.associatedCompanies) ? b.associatedCompanies : [];
  const companies = list.filter(
    (c): c is AssociatedCompany =>
      typeof c === "object" && c !== null && typeof (c as { id?: unknown }).id === "string",
  );
  const to = b.metadata?.to;
  return { companies, next: typeof to === "string" && to.length > 0 ? to : null };
}

export function companiesMatchingRnc(
  companies: AssociatedCompany[],
  rnc: string | null | undefined,
): AssociatedCompany[] {
  const target = normalizeRnc(rnc);
  if (target.length === 0) return [];
  return companies.filter((c) => normalizeRnc(c.identification) === target);
}

/** Resumen de una empresa de Alanube que se le puede mostrar al panel. */
export function summarizeCompany(c: AssociatedCompany) {
  return {
    id: c.id,
    name: c.name ?? null,
    trade_name: c.tradeName ?? null,
    identification: c.identification ?? null,
    address: c.address ?? null,
    type: c.type ?? null,
    certification_step: typeof c.certificationStep === "number" ? c.certificationStep : null,
    certificate: c.certificate
      ? {
        name: c.certificate.name ?? null,
        issuer: c.certificate.issuerName ?? null,
        end_date: c.certificate.endDate ?? null,
      }
      : null,
    company_urls: c.companyUrls
      ? {
        reception: c.companyUrls.reception ?? null,
        approval: c.companyUrls.approval ?? null,
        authentication: c.companyUrls.authentication ?? null,
      }
      : null,
  };
}

// ── Secuencias e-NCF ───────────────────────────────────────────────────────

/** Tipos que el panel deja cargar: los que `emit-document` sabe mandar, mas la
 *  E34 que usan las anulaciones. */
export const ONBOARDING_SEQUENCE_TYPES = ["E31", "E32", "E34", "E44", "E45"];

/** e-NCF = E + 2 digitos de tipo + 10 de secuencia. */
export const MAX_ECF_SEQUENCE = 9_999_999_999;

export interface SequenceInput {
  ncf_type?: string | null;
  range_start?: number | null;
  range_end?: number | null;
  expiration_date?: string | null;
  authorization_number?: string | null;
  /** Ultimo numero ya consumido de esa autorizacion (rechazos incluidos). */
  last_used?: number | null;
}

export interface ExistingSequence {
  id: string;
  range_start: number;
  range_end: number;
  current_number: number;
}

export type SequenceWrite =
  | {
    kind: "insert";
    row: {
      ncf_type: string;
      serie: string;
      prefix: string;
      range_start: number;
      range_end: number;
      current_number: number;
      expiration_date: string | null;
      is_active: true;
      authorized_by: string | null;
    };
  }
  | {
    kind: "update";
    id: string;
    patch: {
      range_start: number;
      range_end: number;
      expiration_date: string | null;
      is_active: true;
      authorized_by?: string;
      current_number?: number;
    };
  };

const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;

function isRealDate(v: string): boolean {
  if (!DATE_RE.test(v)) return false;
  const d = new Date(`${v}T00:00:00Z`);
  return !Number.isNaN(d.getTime()) && d.toISOString().slice(0, 10) === v;
}

/**
 * Decide que escribir en `ncf_sequences` a partir de lo que dice el PDF de la
 * DGII. `today` va como YYYY-MM-DD.
 *
 * Sobre una secuencia existente NUNCA baja `current_number`: la numeracion ya
 * emitida no se reutiliza. Solo lo sube si el operador informa numeros
 * quemados fuera del sistema.
 */
export function planSequenceWrite(
  input: SequenceInput,
  existing: ExistingSequence | null,
  today: string,
): Validation<SequenceWrite> {
  const errors: string[] = [];
  const type = (input.ncf_type ?? "").trim().toUpperCase();
  if (!ONBOARDING_SEQUENCE_TYPES.includes(type)) {
    errors.push(`Tipo de comprobante no soportado: "${input.ncf_type ?? ""}".`);
  }

  const start = input.range_start;
  const end = input.range_end;
  if (!Number.isInteger(start) || (start as number) < 1) {
    errors.push("El rango tiene que empezar en un entero mayor que 0.");
  }
  if (!Number.isInteger(end) || (end as number) > MAX_ECF_SEQUENCE) {
    errors.push("El fin del rango no es valido.");
  } else if (Number.isInteger(start) && (end as number) < (start as number)) {
    errors.push("El fin del rango es menor que el inicio.");
  }

  const exp = (input.expiration_date ?? "").trim();
  if (exp.length === 0) {
    if (TYPES_WITH_SEQUENCE_DUE_DATE.includes(type)) {
      errors.push(
        `${type} exige la fecha de vencimiento de la autorizacion: sin ella la ` +
          `DGII rechaza con el codigo 145.`,
      );
    }
  } else if (!isRealDate(exp)) {
    errors.push("La fecha de vencimiento no es una fecha valida (AAAA-MM-DD).");
  } else if (exp < today) {
    errors.push(`La autorizacion vencio el ${exp}. Hay que solicitar una nueva a la DGII.`);
  }

  const auth = (input.authorization_number ?? "").trim();
  if (auth.length > 40) errors.push("El numero de autorizacion es demasiado largo.");

  const lastUsed = input.last_used ?? null;
  if (lastUsed !== null && (!Number.isInteger(lastUsed) || lastUsed < 0)) {
    errors.push("El ultimo numero usado tiene que ser un entero, 0 o mayor.");
  } else if (lastUsed !== null && Number.isInteger(end) && lastUsed > (end as number)) {
    errors.push("El ultimo numero usado no puede pasar del fin del rango.");
  }

  if (existing && Number.isInteger(end) && (end as number) < Number(existing.current_number)) {
    errors.push(
      `Esa secuencia ya uso hasta el ${existing.current_number}; el rango no ` +
        `puede terminar antes.`,
    );
  }

  if (errors.length > 0) return { ok: false, errors };

  const s = start as number;
  const e = end as number;

  if (existing) {
    const patch: Extract<SequenceWrite, { kind: "update" }>["patch"] = {
      range_start: s,
      range_end: e,
      expiration_date: exp.length > 0 ? exp : null,
      is_active: true,
    };
    if (auth.length > 0) patch.authorized_by = auth;
    if (lastUsed !== null && lastUsed > Number(existing.current_number)) {
      patch.current_number = lastUsed;
    }
    return { ok: true, value: { kind: "update", id: existing.id, patch } };
  }

  return {
    ok: true,
    value: {
      kind: "insert",
      row: {
        ncf_type: type,
        serie: "E",
        prefix: type,
        range_start: s,
        range_end: e,
        current_number: Math.max(s - 1, lastUsed ?? 0),
        expiration_date: exp.length > 0 ? exp : null,
        is_active: true,
        authorized_by: auth.length > 0 ? auth : null,
      },
    },
  };
}

// ── Modalidad e-CF ─────────────────────────────────────────────────────────

/**
 * Comprobante predefinido al cambiar de modalidad. Calcado de
 * `FiscalViewModel.toggleElectronicBilling` en la POS: se conserva si su serie
 * es compatible (E con e-CF, B sin e-CF); si no, cae al Consumo de la
 * modalidad nueva.
 */
export function defaultNcfTypeFor(currentDefault: string | null | undefined, ecfEnabled: boolean): string {
  const current = (currentDefault ?? "").trim().toUpperCase();
  const matches = ecfEnabled ? current.startsWith("E") : current.startsWith("B");
  if (matches) return current;
  return ecfEnabled ? "E32" : "B02";
}

// ── Certificacion ante la DGII (fase 2) ────────────────────────────────────
//
// Orden del proceso segun Alanube: postulacion en la OFV (con los datos del
// proveedor y las URLs de la empresa) → firmar el XML de postulacion → set de
// pruebas → firmar la declaracion jurada → asignar roles (XML opcional).
// Los XML los genera la DGII; Alanube solo los firma con el certificado de la
// empresa. Subirlos a la OFV lo hace el cliente o el operador con su clave.

export const SIGN_KINDS = ["postulation", "declaration", "roles"] as const;
export type SignKind = typeof SIGN_KINDS[number];

/** Columna de `ecf_onboarding` que registra cuando se firmo cada documento. */
export const SIGNED_AT_COLUMN: Record<SignKind, string> = {
  postulation: "postulation_signed_at",
  declaration: "declaration_signed_at",
  roles: "roles_signed_at",
};

/** Los XML de habilitacion pesan pocos KB; 2 MB ya no es uno de ellos. */
export const MAX_ENABLING_XML_BYTES = 2 * 1024 * 1024;

export interface EnablingXmlInput {
  kind?: string | null;
  filename?: string | null;
  content_base64?: string | null;
}

export interface ValidEnablingXml {
  kind: SignKind;
  filename: string;
  bytes: Uint8Array;
}

export function validateEnablingXml(input: EnablingXmlInput): Validation<ValidEnablingXml> {
  const errors: string[] = [];

  const kind = (input.kind ?? "").trim() as SignKind;
  if (!SIGN_KINDS.includes(kind)) {
    errors.push(`Tipo de documento desconocido: "${input.kind ?? ""}".`);
  }

  const filename = (input.filename ?? "").trim();
  if (!filename.toLowerCase().endsWith(".xml")) {
    errors.push("El archivo tiene que ser el .xml que genera la DGII.");
  }

  const content = (input.content_base64 ?? "")
    .replace(/^data:[^,]*,/, "")
    .replace(/\s+/g, "");
  let bytes: Uint8Array | null = null;
  if (content.length === 0) {
    errors.push("El archivo esta vacio.");
  } else if (content.length % 4 !== 0 || !BASE64_RE.test(content)) {
    errors.push("El contenido del archivo no es base64 valido.");
  } else {
    bytes = Uint8Array.from(atob(content), (c) => c.charCodeAt(0));
    if (bytes.length > MAX_ENABLING_XML_BYTES) {
      errors.push("El archivo es demasiado grande para ser un XML de la DGII.");
    } else if (!looksLikeXml(bytes)) {
      errors.push("El archivo no es XML (¿se descargo el PDF en vez del XML?).");
    }
  }

  if (errors.length > 0 || bytes === null) return { ok: false, errors };
  return { ok: true, value: { kind, filename, bytes } };
}

/** Primer caracter util `<`, tolerando BOM UTF-8 y espacios. */
function looksLikeXml(bytes: Uint8Array): boolean {
  let i = 0;
  if (bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf) i = 3;
  while (i < bytes.length && (bytes[i] === 0x20 || bytes[i] === 0x09 || bytes[i] === 0x0a || bytes[i] === 0x0d)) {
    i++;
  }
  return bytes[i] === 0x3c; // '<'
}

export interface ItemExampleInput {
  item_name?: string | null;
  billing_indicator?: number | null;
  good_service_indicator?: number | null;
  unit_price?: number | null;
  item_description?: string | null;
}

/** `itemExample` de `POST /set-tests`, con los nombres de Alanube. */
export interface ItemExample {
  billingIndicator: 1 | 2 | 3 | 4;
  itemName: string;
  goodServiceIndicator: 1 | 2;
  unitPriceItem: number;
  itemDescription?: string;
}

export function validateItemExample(input: ItemExampleInput): Validation<ItemExample> {
  const errors: string[] = [];

  const name = clean(input.item_name);
  if (!name) errors.push("Falta el nombre del producto de ejemplo.");
  else if (name.length > 80) errors.push("El nombre del producto no puede pasar de 80 caracteres.");

  const billing = input.billing_indicator;
  if (billing !== 1 && billing !== 2 && billing !== 3 && billing !== 4) {
    errors.push("Indicador de facturacion invalido (1 = ITBIS 18%, 2 = 16%, 3 = 0%, 4 = exento).");
  }

  const goodService = input.good_service_indicator;
  if (goodService !== 1 && goodService !== 2) {
    errors.push("Indica si es un bien (1) o un servicio (2).");
  }

  // Alanube lo pide ENTERO: 125.50 no pasa su validacion.
  const price = input.unit_price;
  if (!Number.isInteger(price) || (price as number) < 1 || (price as number) > 99_999_999) {
    errors.push("El precio de ejemplo tiene que ser un entero entre 1 y 99,999,999.");
  }

  const description = clean(input.item_description);
  if (description && description.length > 1000) {
    errors.push("La descripcion no puede pasar de 1000 caracteres.");
  }

  if (errors.length > 0) return { ok: false, errors };
  const value: ItemExample = {
    billingIndicator: billing as 1 | 2 | 3 | 4,
    itemName: name as string,
    goodServiceIndicator: goodService as 1 | 2,
    unitPriceItem: price as number,
  };
  if (description) value.itemDescription = description;
  return { ok: true, value };
}

export interface SetTestDocument {
  type: string;
  status: string;
  encf: string | null;
}

export interface SetTestSummary {
  id: string | null;
  status: string;
  retry_number: number | null;
  processed: number | null;
  documents: SetTestDocument[];
  documents_zip_url: string | null;
  resumes_zip_url: string | null;
}

export const SET_TEST_FINAL_STATUSES = ["ACCEPTED", "REJECTED"];

/**
 * Respuesta de `GET /check-set-tests/{id}/idCompany/{idCompany}`. La guia de
 * Alanube y su OpenAPI no coinciden: `documentsInfo` viene como objeto
 * `{ zipUrl, documents[] }` en una y como arreglo en la otra. Se aceptan las dos.
 */
export function parseSetTest(body: unknown): SetTestSummary {
  const b = (body ?? {}) as Record<string, unknown>;

  const readGroup = (raw: unknown): { docs: SetTestDocument[]; zip: string | null } => {
    const obj = raw && typeof raw === "object" && !Array.isArray(raw)
      ? raw as { zipUrl?: unknown; documents?: unknown }
      : null;
    const list = Array.isArray(raw) ? raw : Array.isArray(obj?.documents) ? obj!.documents as unknown[] : [];
    const docs = list
      .filter((d): d is Record<string, unknown> => typeof d === "object" && d !== null)
      .map((d) => ({
        type: typeof d.documentType === "string" ? d.documentType : "desconocido",
        status: typeof d.status === "string" ? d.status.toUpperCase() : "DESCONOCIDO",
        encf: typeof d.encf === "string" ? d.encf : null,
      }));
    const zip = typeof obj?.zipUrl === "string" && obj.zipUrl.length > 0 ? obj.zipUrl : null;
    return { docs, zip };
  };

  const documents = readGroup(b.documentsInfo);
  const resumes = readGroup(b.resumesInfo);
  const id = typeof b.testId === "string" ? b.testId : typeof b.id === "string" ? b.id : null;

  return {
    id,
    status: typeof b.status === "string" ? b.status.toUpperCase() : "DESCONOCIDO",
    retry_number: typeof b.retryNumber === "number" ? b.retryNumber : null,
    processed: typeof b.totalDocumentProcessed === "number" ? b.totalDocumentProcessed : null,
    documents: [...documents.docs, ...resumes.docs],
    documents_zip_url: documents.zip,
    resumes_zip_url: resumes.zip,
  };
}

/**
 * `retryNumber` para generar un set nuevo despues de uno rechazado. Alanube
 * no deja repetir el numero (AP4005) y lo limita a 0–99.
 */
export function nextSetTestRetry(previous: number | null): Validation<number | null> {
  if (previous === null) return { ok: true, value: null };
  if (previous >= 99) {
    return { ok: false, errors: ["Se agotaron los reintentos del set de pruebas (maximo 99). Hay que hablar con Alanube."] };
  }
  return { ok: true, value: previous + 1 };
}

export interface ProviderInfo {
  software_type: string | null;
  software_name: string | null;
  software_version: string | null;
  provider_rnc: string | null;
  provider_name: string | null;
  provider_trade_name: string | null;
}

/** `GET /provider-info`: lo que se copia en el formulario de postulacion. */
export function parseProviderInfo(body: unknown): ProviderInfo {
  const data = ((body ?? {}) as { data?: Record<string, unknown> }).data ?? {};
  const val = (v: unknown): string | null => {
    const raw = (v as { value?: unknown } | undefined)?.value;
    return raw === undefined || raw === null || raw === "" ? null : String(raw);
  };
  const provider = (data.providerData ?? {}) as Record<string, unknown>;
  return {
    software_type: val(data.softwareType),
    software_name: val(data.softwareName),
    software_version: val(data.softwareVersion),
    provider_rnc: val(provider.rnc),
    provider_name: val(provider.name),
    provider_trade_name: val(provider.tradeName),
  };
}

/**
 * Producto de ejemplo sugerido para el set de pruebas: el activo con mas
 * precio entre los que llevan ITBIS (los comprobantes salen representativos).
 * El operador lo puede cambiar.
 */
export function suggestItemExample(
  items: Array<{ name: string; price: number | string; taxed: boolean }>,
): ItemExampleInput | null {
  const candidates = items
    .map((i) => ({ ...i, price: Number(i.price) }))
    .filter((i) => Number.isFinite(i.price) && i.price >= 1 && i.name.trim().length > 0);
  if (candidates.length === 0) return null;
  const taxed = candidates.filter((i) => i.taxed);
  const pool = taxed.length > 0 ? taxed : candidates;
  const pick = pool.reduce((a, b) => (b.price > a.price ? b : a));
  return {
    item_name: pick.name.trim().slice(0, 80),
    billing_indicator: pick.taxed ? 1 : 4,
    good_service_indicator: 1,
    unit_price: Math.max(1, Math.round(pick.price)),
  };
}

// ── Solicitud del cliente desde la POS ─────────────────────────────────────

export interface RequestContactInput {
  contact_name?: string | null;
  contact_phone?: string | null;
}

export function validateRequestContact(
  input: RequestContactInput,
): Validation<{ contact_name: string; contact_phone: string }> {
  const errors: string[] = [];
  const name = clean(input.contact_name);
  if (!name) errors.push("Falta el nombre de la persona de contacto.");
  else if (name.length > 80) errors.push("El nombre de contacto es demasiado largo.");

  const phone = clean(input.contact_phone);
  const digits = (phone ?? "").replace(/\D/g, "");
  if (!phone) errors.push("Falta el telefono de contacto.");
  else if (digits.length < 10 || digits.length > 15) {
    errors.push("El telefono de contacto no es valido (incluye el codigo de area).");
  }

  if (errors.length > 0) return { ok: false, errors };
  return { ok: true, value: { contact_name: name as string, contact_phone: phone as string } };
}

export interface SequenceUsabilityRow {
  ncf_type: string;
  range_end: number;
  current_number: number;
  expiration_date: string | null;
  is_active: boolean | null;
}

/** Hay al menos una secuencia electronica con la que se puede emitir hoy. */
export function hasUsableEcfSequence(rows: SequenceUsabilityRow[], today: string): boolean {
  return rows.some((s) =>
    s.ncf_type.startsWith("E") &&
    s.is_active === true &&
    Number(s.current_number) < Number(s.range_end) &&
    (s.expiration_date
      ? s.expiration_date >= today
      : !TYPES_WITH_SEQUENCE_DUE_DATE.includes(s.ncf_type))
  );
}

/**
 * En que va la facturacion electronica de un negocio, en los terminos que ve
 * el cliente. Se DERIVA de lo que ya existe; no hay un estado guardado aparte
 * que se pueda desincronizar.
 *   none          → nunca la pidio y nadie la empezo
 *   company       → pedida, falta registrar/vincular la empresa en Alanube
 *   certification → falta la autorizacion de la DGII
 *   sequences     → autorizado, faltan las secuencias e-NCF
 *   activation    → todo listo, falta activar
 *   active        → ya emite
 */
export type RequestStage = "none" | "company" | "certification" | "sequences" | "activation" | "active";

export function requestStage(input: {
  requested: boolean;
  hasCompany: boolean;
  dgiiAuthorized: boolean;
  usableSequences: boolean;
  provisioned: boolean;
  ecfEnabled: boolean;
}): RequestStage {
  if (input.provisioned && input.ecfEnabled) return "active";
  if (!input.requested && !input.hasCompany && !input.provisioned) return "none";
  if (!input.hasCompany) return "company";
  // La DGII no entrega secuencias E a quien no autorizo.
  if (!input.dgiiAuthorized && !input.usableSequences && !input.provisioned) return "certification";
  if (!input.usableSequences) return "sequences";
  return "activation";
}
