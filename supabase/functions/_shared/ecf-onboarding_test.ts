import { assert, assertEquals } from "https://deno.land/std@0.208.0/assert/mod.ts";
import {
  buildCompanyPayload,
  buildWebhooks,
  companiesMatchingRnc,
  defaultNcfTypeFor,
  MAX_CERTIFICATE_BYTES,
  nextSetTestRetry,
  parseAssociatedPage,
  parseProviderInfo,
  parseSetTest,
  planSequenceWrite,
  suggestItemExample,
  summarizeCompany,
  TaxpayerData,
  validateCertificate,
  validateEnablingXml,
  validateItemExample,
  validateTaxpayer,
} from "./ecf-onboarding.ts";

const TODAY = "2026-09-17";
const WEBHOOK_URL = "https://supabase.mangopos.do/functions/v1/alanube-webhook";

function errorsOf<T>(r: { ok: true; value: T } | { ok: false; errors: string[] }): string[] {
  return r.ok ? [] : r.errors;
}

/** base64 de bytes arbitrarios, arrancando como un DER real (0x30). */
function fakeP12(size = 64, firstByte = 0x30): string {
  const bytes = new Uint8Array(size);
  bytes[0] = firstByte;
  for (let i = 1; i < size; i++) bytes[i] = i % 251;
  return btoa(String.fromCharCode(...bytes));
}

// Datos reales de Tropella: la direccion FISCAL es Gurabo, no el local.
const TROPELLA: TaxpayerData = {
  rnc: "133328828",
  legal_name: "TROPELLA COFFEE SRL",
  trade_name: "Tropella Coffee",
  fiscal_address: "GREGORIO LUPERON, No. B 4, GURABO",
  province: "Santiago",
  municipality: "Santiago de los Caballeros",
  email: "tropela.cocktails01@gmail.com",
};

// ── Datos del contribuyente ────────────────────────────────────────────────

Deno.test("taxpayer: RNC con guiones se normaliza a digitos", () => {
  const r = validateTaxpayer({ rnc: "1-33-32882-8" });
  assert(r.ok);
  assertEquals(r.value.rnc, "133328828");
});

Deno.test("taxpayer: acepta cedula de 11 digitos (persona fisica)", () => {
  assert(validateTaxpayer({ rnc: "001-1234567-8" }).ok);
});

Deno.test("taxpayer: RNC de 8 digitos no pasa", () => {
  assertEquals(errorsOf(validateTaxpayer({ rnc: "13332882" })).length, 1);
});

Deno.test("taxpayer: RNC con letras y sin digitos no se acepta callado", () => {
  assertEquals(errorsOf(validateTaxpayer({ rnc: "pendiente" })).length, 1);
});

Deno.test("taxpayer: borrador incompleto se puede guardar", () => {
  const r = validateTaxpayer({ legal_name: "  Tropella   Coffee SRL " });
  assert(r.ok);
  assertEquals(r.value.legal_name, "Tropella Coffee SRL");
  assertEquals(r.value.rnc, null);
});

Deno.test("taxpayer: para dar de alta exige RNC, razon social y direccion fiscal", () => {
  const errs = errorsOf(validateTaxpayer({ email: "a@b.co" }, { forRegistration: true }));
  assertEquals(errs.length, 3);
});

Deno.test("taxpayer: direccion de mas de 100 caracteres la rechaza Alanube", () => {
  const errs = errorsOf(validateTaxpayer({ fiscal_address: "x".repeat(101) }));
  assertEquals(errs.length, 1);
});

Deno.test("taxpayer: correo invalido", () => {
  assertEquals(errorsOf(validateTaxpayer({ email: "tropela@" })).length, 1);
});

// ── Certificado ────────────────────────────────────────────────────────────

Deno.test("certificado: .p12 valido", () => {
  const r = validateCertificate({
    filename: "Firma Tropella.P12",
    content_base64: fakeP12(),
    password: "sEcR3T",
  });
  assert(r.ok);
  assertEquals(r.value.extension, "p12");
  assertEquals(r.value.name, "Firma Tropella");
});

Deno.test("certificado: acepta data URL del navegador y la limpia", () => {
  const content = fakeP12();
  const r = validateCertificate({
    filename: "firma.pfx",
    content_base64: `data:application/x-pkcs12;base64,${content}`,
    password: "x",
  });
  assert(r.ok);
  assertEquals(r.value.content, content);
});

Deno.test("certificado: un PDF renombrado no pasa", () => {
  const r = validateCertificate({
    filename: "firma.p12",
    content_base64: fakeP12(64, 0x25), // '%' de %PDF
    password: "x",
  });
  assertEquals(errorsOf(r).length, 1);
});

Deno.test("certificado: extension equivocada", () => {
  const r = validateCertificate({ filename: "firma.pdf", content_base64: fakeP12(), password: "x" });
  assertEquals(errorsOf(r).length, 1);
});

Deno.test("certificado: sin contrasena", () => {
  const r = validateCertificate({ filename: "firma.p12", content_base64: fakeP12(), password: "" });
  assertEquals(errorsOf(r).length, 1);
});

Deno.test("certificado: la contrasena no se recorta", () => {
  const r = validateCertificate({ filename: "firma.p12", content_base64: fakeP12(), password: " clave " });
  assert(r.ok);
  assertEquals(r.value.password, " clave ");
});

Deno.test("certificado: demasiado grande", () => {
  const r = validateCertificate({
    filename: "firma.p12",
    content_base64: fakeP12(MAX_CERTIFICATE_BYTES + 3),
    password: "x",
  });
  assertEquals(errorsOf(r).length, 1);
});

Deno.test("certificado: base64 roto", () => {
  const r = validateCertificate({ filename: "firma.p12", content_base64: "no-es-base64!", password: "x" });
  assertEquals(errorsOf(r).length, 1);
});

// ── Payload de alta ────────────────────────────────────────────────────────

Deno.test("alta: siempre asociada, con webhooks y direccion fiscal", () => {
  const cert = validateCertificate({ filename: "firma.p12", content_base64: fakeP12(), password: "s" });
  assert(cert.ok);
  const p = buildCompanyPayload(TROPELLA, cert.value, buildWebhooks(WEBHOOK_URL, "secreto"));

  assertEquals(p.type, "associated");
  assertEquals(p.identification, "133328828");
  assertEquals(p.address, "GREGORIO LUPERON, No. B 4, GURABO");
  assertEquals(p.tradeName, "Tropella Coffee");

  const hooks = p.webhooks as ReturnType<typeof buildWebhooks>;
  assertEquals(hooks.documents.emissionFinished.url, WEBHOOK_URL);
  assertEquals(hooks.general.governmentStatusChanged.headers["X-Webhook-Secret"], "secreto");
  // El preflight de provision-ecf busca la ruta del webhook dentro del JSON.
  assert(JSON.stringify(p.webhooks).includes("/functions/v1/alanube-webhook"));
});

Deno.test("alta: opcionales vacios no viajan", () => {
  const cert = validateCertificate({ filename: "firma.p12", content_base64: fakeP12(), password: "s" });
  assert(cert.ok);
  const p = buildCompanyPayload(
    { ...TROPELLA, trade_name: null, province: null, municipality: null, email: null },
    cert.value,
    buildWebhooks(WEBHOOK_URL, "s"),
  );
  assertEquals("tradeName" in p, false);
  assertEquals("email" in p, false);
});

// ── Empresas asociadas ─────────────────────────────────────────────────────

Deno.test("asociadas: parsea la pagina y el cursor", () => {
  const page = parseAssociatedPage({
    metadata: { from: null, to: "01NEXT", results_count: 2 },
    associatedCompanies: [
      { id: "01M11V7B6J4X6FQ5SRAFPVPATV", identification: "133328828", name: "TROPELLA COFFEE SRL" },
      { id: "01OTRA", identification: "101010101" },
      { sinId: true },
    ],
  });
  assertEquals(page.companies.length, 2);
  assertEquals(page.next, "01NEXT");
});

Deno.test("asociadas: ultima pagina no tiene cursor", () => {
  assertEquals(parseAssociatedPage({ metadata: { to: null }, associatedCompanies: [] }).next, null);
  assertEquals(parseAssociatedPage(null).companies.length, 0);
});

Deno.test("asociadas: coincide por RNC aunque venga con guiones", () => {
  const list = [
    { id: "a", identification: "133328828" },
    { id: "b", identification: "133679345" },
  ];
  assertEquals(companiesMatchingRnc(list, "1-33-32882-8").map((c) => c.id), ["a"]);
  assertEquals(companiesMatchingRnc(list, "").length, 0);
});

// ── Secuencias ─────────────────────────────────────────────────────────────

Deno.test("secuencia: E31 de Tropella tal como vino en la autorizacion", () => {
  const r = planSequenceWrite(
    {
      ncf_type: "e31",
      range_start: 1,
      range_end: 100,
      expiration_date: "2027-12-31",
      authorization_number: "6005460440",
    },
    null,
    TODAY,
  );
  assert(r.ok);
  assertEquals(r.value.kind, "insert");
  if (r.value.kind !== "insert") return;
  assertEquals(r.value.row.ncf_type, "E31");
  assertEquals(r.value.row.prefix, "E31");
  assertEquals(r.value.row.serie, "E");
  assertEquals(r.value.row.current_number, 0);
  assertEquals(r.value.row.authorized_by, "6005460440");
});

Deno.test("secuencia: E31 sin vencimiento no se carga (DGII 145)", () => {
  const r = planSequenceWrite({ ncf_type: "E31", range_start: 1, range_end: 100 }, null, TODAY);
  assertEquals(errorsOf(r).length, 1);
});

Deno.test("secuencia: E32 va sin vencimiento (la DGII pone N/A)", () => {
  const r = planSequenceWrite({ ncf_type: "E32", range_start: 1, range_end: 1000 }, null, TODAY);
  assert(r.ok);
  if (r.value.kind !== "insert") return;
  assertEquals(r.value.row.expiration_date, null);
});

Deno.test("secuencia: E34 tampoco exige vencimiento", () => {
  assert(planSequenceWrite({ ncf_type: "E34", range_start: 1, range_end: 50 }, null, TODAY).ok);
});

Deno.test("secuencia: autorizacion vencida", () => {
  const r = planSequenceWrite(
    { ncf_type: "E31", range_start: 1, range_end: 100, expiration_date: "2026-09-16" },
    null,
    TODAY,
  );
  assertEquals(errorsOf(r).length, 1);
});

Deno.test("secuencia: fecha imposible", () => {
  const r = planSequenceWrite(
    { ncf_type: "E31", range_start: 1, range_end: 100, expiration_date: "2027-02-30" },
    null,
    TODAY,
  );
  assertEquals(errorsOf(r).length, 1);
});

Deno.test("secuencia: tipos de papel no se cargan por aqui", () => {
  assertEquals(errorsOf(planSequenceWrite({ ncf_type: "B02", range_start: 1, range_end: 10 }, null, TODAY)).length, 1);
});

Deno.test("secuencia: rango al reves", () => {
  assertEquals(errorsOf(planSequenceWrite({ ncf_type: "E32", range_start: 10, range_end: 5 }, null, TODAY)).length, 1);
});

Deno.test("secuencia: numeros quemados fuera del sistema arrancan despues", () => {
  const r = planSequenceWrite({ ncf_type: "E32", range_start: 1, range_end: 1000, last_used: 2 }, null, TODAY);
  assert(r.ok);
  if (r.value.kind !== "insert") return;
  assertEquals(r.value.row.current_number, 2);
});

Deno.test("secuencia: segundo lote empieza en 101", () => {
  const r = planSequenceWrite(
    { ncf_type: "E31", range_start: 101, range_end: 200, expiration_date: "2027-12-31" },
    null,
    TODAY,
  );
  assert(r.ok);
  if (r.value.kind !== "insert") return;
  assertEquals(r.value.row.current_number, 100);
});

Deno.test("secuencia existente: corrige el rango sin tocar lo emitido", () => {
  // El caso real: se cargo range_end=1000 y la DGII solo autorizo 100.
  const r = planSequenceWrite(
    { ncf_type: "E31", range_start: 1, range_end: 100, expiration_date: "2027-12-31" },
    { id: "seq1", range_start: 1, range_end: 1000, current_number: 2 },
    TODAY,
  );
  assert(r.ok);
  assertEquals(r.value.kind, "update");
  if (r.value.kind !== "update") return;
  assertEquals(r.value.patch.range_end, 100);
  assertEquals("current_number" in r.value.patch, false);
});

Deno.test("secuencia existente: no deja cerrar el rango antes de lo ya usado", () => {
  const r = planSequenceWrite(
    { ncf_type: "E32", range_start: 1, range_end: 5 },
    { id: "seq1", range_start: 1, range_end: 1000, current_number: 12 },
    TODAY,
  );
  assertEquals(errorsOf(r).length, 1);
});

Deno.test("secuencia existente: last_used menor nunca baja la numeracion", () => {
  const r = planSequenceWrite(
    { ncf_type: "E32", range_start: 1, range_end: 1000, last_used: 3 },
    { id: "seq1", range_start: 1, range_end: 1000, current_number: 12 },
    TODAY,
  );
  assert(r.ok);
  if (r.value.kind !== "update") return;
  assertEquals("current_number" in r.value.patch, false);
});

Deno.test("secuencia existente: last_used mayor la adelanta", () => {
  const r = planSequenceWrite(
    { ncf_type: "E32", range_start: 1, range_end: 1000, last_used: 20 },
    { id: "seq1", range_start: 1, range_end: 1000, current_number: 12 },
    TODAY,
  );
  assert(r.ok);
  if (r.value.kind !== "update") return;
  assertEquals(r.value.patch.current_number, 20);
});

// ── Modalidad ──────────────────────────────────────────────────────────────

Deno.test("modalidad: igual que la POS", () => {
  assertEquals(defaultNcfTypeFor("B02", true), "E32");
  assertEquals(defaultNcfTypeFor("B01", true), "E32");
  assertEquals(defaultNcfTypeFor("E31", true), "E31");
  assertEquals(defaultNcfTypeFor("E31", false), "B02");
  assertEquals(defaultNcfTypeFor(null, true), "E32");
});

// ── Certificacion DGII ─────────────────────────────────────────────────────

function b64(text: string, bom = false): string {
  const bytes = new TextEncoder().encode(text);
  const all = bom ? new Uint8Array([0xef, 0xbb, 0xbf, ...bytes]) : bytes;
  return btoa(String.fromCharCode(...all));
}

Deno.test("xml: postulacion valida", () => {
  const r = validateEnablingXml({
    kind: "postulation",
    filename: "Postulacion_133328828.XML",
    content_base64: b64('<?xml version="1.0" encoding="utf-8"?><Postulacion/>'),
  });
  assert(r.ok);
  assertEquals(r.value.kind, "postulation");
});

Deno.test("xml: tolera BOM y espacios antes del <", () => {
  const r = validateEnablingXml({
    kind: "declaration",
    filename: "declaracion.xml",
    content_base64: b64("\n  <DeclaracionJurada/>", true),
  });
  assert(r.ok);
});

Deno.test("xml: un PDF con extension .xml no pasa", () => {
  const r = validateEnablingXml({
    kind: "postulation",
    filename: "postulacion.xml",
    content_base64: b64("%PDF-1.7 ..."),
  });
  assertEquals(errorsOf(r).length, 1);
});

Deno.test("xml: tipo desconocido y extension equivocada", () => {
  const r = validateEnablingXml({ kind: "otro", filename: "algo.pdf", content_base64: b64("<a/>") });
  assertEquals(errorsOf(r).length, 2);
});

Deno.test("producto de ejemplo: valido", () => {
  const r = validateItemExample({
    item_name: "EXPRESSO DOBLE",
    billing_indicator: 1,
    good_service_indicator: 1,
    unit_price: 125,
  });
  assert(r.ok);
  assertEquals(r.value.unitPriceItem, 125);
  assertEquals("itemDescription" in r.value, false);
});

Deno.test("producto de ejemplo: Alanube pide precio entero", () => {
  const r = validateItemExample({
    item_name: "EXPRESSO",
    billing_indicator: 1,
    good_service_indicator: 1,
    unit_price: 125.5,
  });
  assertEquals(errorsOf(r).length, 1);
});

Deno.test("producto de ejemplo: indicador 0 (no facturable) no aplica al set", () => {
  const r = validateItemExample({
    item_name: "LEY",
    billing_indicator: 0,
    good_service_indicator: 2,
    unit_price: 10,
  });
  assertEquals(errorsOf(r).length, 1);
});

Deno.test("set de pruebas: forma de la guia (documentsInfo objeto con zipUrl)", () => {
  const t = parseSetTest({
    testId: "01GK1P6FK2EQXFV9CB8FHVV9P4",
    status: "ACCEPTED",
    retryNumber: 41,
    totalDocumentProcessed: 20,
    documentsInfo: {
      zipUrl: "https://s3/docs.zip",
      documents: [{ documentType: "fiscalInvoice", status: "ACCEPTED", encf: "E310000001410" }],
    },
    resumesInfo: {
      zipUrl: "https://s3/resumes.zip",
      documents: [{ documentType: "resume", status: "ACCEPTED", encf: "E320000002410" }],
    },
  });
  assertEquals(t.id, "01GK1P6FK2EQXFV9CB8FHVV9P4");
  assertEquals(t.retry_number, 41);
  assertEquals(t.documents.length, 2);
  assertEquals(t.documents_zip_url, "https://s3/docs.zip");
  assertEquals(t.resumes_zip_url, "https://s3/resumes.zip");
});

Deno.test("set de pruebas: forma del OpenAPI (documentsInfo arreglo)", () => {
  const t = parseSetTest({
    testId: "01X",
    status: "in_progress",
    documentsInfo: [
      { documentType: "creditNote", status: "REJECTED", encf: "E340000001820" },
      { documentType: "debitNote", status: "IN_PROGRESS" },
    ],
  });
  assertEquals(t.status, "IN_PROGRESS");
  assertEquals(t.documents.map((d) => d.status), ["REJECTED", "IN_PROGRESS"]);
  assertEquals(t.documents[1].encf, null);
  assertEquals(t.documents_zip_url, null);
});

Deno.test("set de pruebas: respuesta de creacion trae id y no testId", () => {
  const t = parseSetTest({ id: "01NUEVO", status: "REGISTERED" });
  assertEquals(t.id, "01NUEVO");
  assertEquals(t.documents.length, 0);
});

Deno.test("set de pruebas: reintentos", () => {
  const first = nextSetTestRetry(null);
  assert(first.ok);
  assertEquals(first.value, null);
  const second = nextSetTestRetry(41);
  assert(second.ok);
  assertEquals(second.value, 42);
  assertEquals(errorsOf(nextSetTestRetry(99)).length, 1);
});

Deno.test("proveedor: saca los valores del formulario de postulacion", () => {
  const p = parseProviderInfo({
    data: {
      softwareType: { description: "Tipo de software", value: "EXTERNO" },
      softwareName: { value: "Alanube" },
      softwareVersion: { value: 1 },
      providerData: {
        rnc: { value: 132109122 },
        name: { value: "Alanube Soluciones SRL" },
        tradeName: { value: "Alanube Soluciones" },
      },
    },
  });
  assertEquals(p.software_version, "1");
  assertEquals(p.provider_rnc, "132109122");
  assertEquals(p.provider_name, "Alanube Soluciones SRL");
  assertEquals(parseProviderInfo(null).software_name, null);
});

Deno.test("empresa: resumen incluye las URLs para la postulacion", () => {
  const c = summarizeCompany({
    id: "01M1",
    companyUrls: { reception: "https://r", approval: "https://a", authentication: "https://t" },
  });
  assertEquals(c.company_urls?.authentication, "https://t");
});

Deno.test("sugerencia: el gravado mas caro, precio redondeado", () => {
  const s = suggestItemExample([
    { name: "AGUA", price: 45.45, taxed: false },
    { name: "EXPRESSO DOBLE", price: "125.00", taxed: true },
    { name: "GOMITAS", price: 23.44, taxed: true },
  ]);
  assertEquals(s?.item_name, "EXPRESSO DOBLE");
  assertEquals(s?.billing_indicator, 1);
  assertEquals(s?.unit_price, 125);
});

Deno.test("sugerencia: solo exentos va con indicador 4", () => {
  const s = suggestItemExample([{ name: "AGUA", price: 45.45, taxed: false }]);
  assertEquals(s?.billing_indicator, 4);
  assertEquals(s?.unit_price, 45);
});

Deno.test("sugerencia: sin productos con precio no inventa", () => {
  assertEquals(suggestItemExample([{ name: "GRATIS", price: 0, taxed: true }]), null);
});
