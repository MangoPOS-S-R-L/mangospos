import { assertEquals } from "https://deno.land/std@0.208.0/assert/mod.ts";
import {
  buildChecks,
  environmentFromBaseUrl,
  normalizeRnc,
  normalizeText,
  PreflightInput,
  worstLevel,
} from "./ecf-preflight.ts";

const WEBHOOK_PATH = "/functions/v1/alanube-webhook";

// Caso base calcado del real: Tropella Coffee SRL, ya certificada.
function tropella(over: Partial<PreflightInput> = {}): PreflightInput {
  return {
    fiscal: { rnc: "133328828", business_legal_name: "Tropella Coffee SRL" },
    business: { address: "GREGORIO LUPERON, No. B 4, GURABO" },
    company: {
      id: "01M11V7B6J4X6FQ5SRAFPVPATV",
      name: "TROPELLA COFFEE SRL",
      tradeName: "TROPELLA COFFEE",
      identification: "133328828",
      address: "GREGORIO LUPERON, No. B 4, GURABO",
      type: "associated",
      certificationStep: 4,
      webhooks: {
        general: {
          governmentStatusChanged: {
            url: "https://supabase.mangopos.do/functions/v1/alanube-webhook",
          },
        },
      },
      certificate: { name: "FIRMA DIGITAL", endDate: "2027-04-23 21:30:54" },
    },
    sequences: [
      { ncf_type: "E32", range_start: 1, range_end: 1000, current_number: 1, expiration_date: "2027-12-31", is_active: true },
      { ncf_type: "B02", range_start: 1, range_end: 100000, current_number: 9833, expiration_date: null, is_active: true },
      // E34: sin ella no se puede anular ante la DGII una factura ya aceptada.
      { ncf_type: "E34", range_start: 1, range_end: 500, current_number: 0, expiration_date: null, is_active: true },
    ],
    itemTaxes: { total: 46, sinImpuesto: 0, soloExcluidos: 0 },
    webhookPath: WEBHOOK_PATH,
    now: new Date("2026-08-29T00:00:00Z"),
    ...over,
  };
}

function levelOf(input: PreflightInput, key: string): string {
  const c = buildChecks(input).find((c) => c.key === key);
  return c ? c.level : "ausente";
}

Deno.test("normalizeRnc ignora guiones y espacios", () => {
  assertEquals(normalizeRnc("1-33-32882-8"), "133328828");
  assertEquals(normalizeRnc(" 133 328 828 "), "133328828");
  assertEquals(normalizeRnc(null), "");
});

Deno.test("normalizeText ignora acentos, mayusculas y puntuacion", () => {
  assertEquals(normalizeText("Gregorio Luperón,  No. B 4, Gurabo"), "GREGORIO LUPERON NO B 4 GURABO");
  assertEquals(normalizeText("GREGORIO LUPERON, No. B 4, GURABO"), "GREGORIO LUPERON NO B 4 GURABO");
});

Deno.test("environment sale de la URL, no de lo que pida el caller", () => {
  assertEquals(environmentFromBaseUrl("https://sandbox.alanube.co/dom/v1"), "sandbox");
  assertEquals(environmentFromBaseUrl("https://api.alanube.co/dom/v1"), "production");
});

Deno.test("negocio listo: todo en ok", () => {
  const checks = buildChecks(tropella());
  assertEquals(worstLevel(checks), "ok");
});

// ── El chequeo que justifica toda la funcion ────────────────────────────
Deno.test("RNC de otro contribuyente BLOQUEA la activacion", () => {
  // El error real que casi cometemos: activar Tropella con el ULID de MANGOPOS.
  const input = tropella({
    company: {
      ...tropella().company,
      id: "01M11S3RXW0DJ6B7R110XTTM9J",
      name: "MANGOPOS SRL",
      identification: "133679345",
    },
  });
  assertEquals(levelOf(input, "rnc"), "fail");
  assertEquals(worstLevel(buildChecks(input)), "fail");
});

Deno.test("mismo RNC escrito con guiones NO bloquea", () => {
  const input = tropella({ fiscal: { rnc: "133-32882-8", business_legal_name: "Tropella Coffee SRL" } });
  assertEquals(levelOf(input, "rnc"), "ok");
});

Deno.test("negocio sin RNC bloquea", () => {
  assertEquals(levelOf(tropella({ fiscal: { rnc: "", business_legal_name: "X" } }), "rnc"), "fail");
  assertEquals(levelOf(tropella({ fiscal: null }), "rnc"), "fail");
});

// ── Certificado ─────────────────────────────────────────────────────────
Deno.test("certificado vencido bloquea", () => {
  const input = tropella({
    company: { ...tropella().company, certificate: { name: "FIRMA", endDate: "2026-01-01 10:00:00" } },
  });
  assertEquals(levelOf(input, "certificate"), "fail");
});

Deno.test("sin certificado bloquea", () => {
  const input = tropella({ company: { ...tropella().company, certificate: undefined } });
  assertEquals(levelOf(input, "certificate"), "fail");
});

// ── Secuencias ──────────────────────────────────────────────────────────
Deno.test("sin secuencia e-NCF activa bloquea", () => {
  // Solo B02: es justo lo que tenia Tropella antes de cargar los rangos E.
  const input = tropella({
    sequences: [
      { ncf_type: "B02", range_start: 1, range_end: 100000, current_number: 9833, expiration_date: null, is_active: true },
    ],
  });
  assertEquals(levelOf(input, "sequences"), "fail");
});

Deno.test("secuencia E agotada no cuenta como disponible", () => {
  const input = tropella({
    sequences: [
      { ncf_type: "E32", range_start: 1, range_end: 1000, current_number: 1000, expiration_date: "2027-12-31", is_active: true },
    ],
  });
  assertEquals(levelOf(input, "sequences"), "fail");
});

Deno.test("E32 sin fecha de vencimiento es CORRECTO: la DGII no se la asigna", () => {
  // La autorizacion real de Tropella dice "Fecha Vencimiento: N/A" para E32.
  const input = tropella({
    sequences: [
      { ncf_type: "E32", range_start: 1, range_end: 1000, current_number: 1, expiration_date: null, is_active: true },
    ],
  });
  assertEquals(levelOf(input, "sequences"), "ok");
});

Deno.test("E31 sin fecha de vencimiento SI avisa (el emisor la inventa)", () => {
  const input = tropella({
    sequences: [
      { ncf_type: "E31", range_start: 1, range_end: 100, current_number: 0, expiration_date: null, is_active: true },
    ],
  });
  assertEquals(levelOf(input, "sequences"), "warn");
});

Deno.test("E31 con su fecha cargada queda en verde", () => {
  const input = tropella({
    sequences: [
      { ncf_type: "E31", range_start: 1, range_end: 100, current_number: 0, expiration_date: "2027-12-31", is_active: true },
      { ncf_type: "E32", range_start: 1, range_end: 1000, current_number: 1, expiration_date: null, is_active: true },
    ],
  });
  assertEquals(levelOf(input, "sequences"), "ok");
});

// ── Direccion: el caso Tropella (fiscal != operacion) ───────────────────
Deno.test("sin secuencia E34 avisa: no se podria anular ante la DGII", () => {
  const input = tropella({
    sequences: tropella().sequences.filter((s) => s.ncf_type !== "E34"),
  });
  assertEquals(levelOf(input, "credit_note_sequence"), "warn");
  // Avisa, pero NO impide activar: el negocio puede facturar igual.
  assertEquals(worstLevel(buildChecks(input)), "warn");
});

Deno.test("E34 agotada cuenta como si no estuviera", () => {
  const input = tropella({
    sequences: [
      ...tropella().sequences.filter((s) => s.ncf_type !== "E34"),
      { ncf_type: "E34", range_start: 1, range_end: 500, current_number: 500, expiration_date: null, is_active: true },
    ],
  });
  assertEquals(levelOf(input, "credit_note_sequence"), "warn");
});

Deno.test("direccion distinta avisa pero NO bloquea", () => {
  // Domicilio fiscal en Gurabo, local en Real Food Park. Ambas legitimas.
  const input = tropella({ business: { address: "Reparto Universitario, Real Food Park, Santiago" } });
  assertEquals(levelOf(input, "address"), "warn");
  assertEquals(worstLevel(buildChecks(input)), "warn");
});

Deno.test("negocio sin direccion bloquea: el emisor aborta sin ella", () => {
  assertEquals(levelOf(tropella({ business: { address: null } }), "address"), "fail");
});

// ── Webhooks y productos ───────────────────────────────────────────────
Deno.test("sin webhooks avisa: los docs se quedarian en 'sent'", () => {
  const input = tropella({ company: { ...tropella().company, webhooks: {} } });
  assertEquals(levelOf(input, "webhooks"), "warn");
});

Deno.test("webhook de otro destino no cuenta", () => {
  const input = tropella({
    company: { ...tropella().company, webhooks: { general: { url: "https://otro.dominio/hook" } } },
  });
  assertEquals(levelOf(input, "webhooks"), "warn");
});

Deno.test("productos sin impuesto vinculado avisan (irian con ITBIS 0)", () => {
  const input = tropella({ itemTaxes: { total: 46, sinImpuesto: 25, soloExcluidos: 0 } });
  assertEquals(levelOf(input, "item_taxes"), "warn");
});

Deno.test("producto con SOLO Ley 10% se reporta aparte: se declara exento", () => {
  // El caso real: AGUA y BOTELLON DE AGUA en Tropella. Exentos de ITBIS en RD,
  // asi que no es un error de configuracion — pero quien activa debe verlo.
  const input = tropella({ itemTaxes: { total: 162, sinImpuesto: 0, soloExcluidos: 2 } });
  assertEquals(levelOf(input, "item_taxes"), "ok");
  assertEquals(levelOf(input, "item_taxes_exentos"), "warn");
});

Deno.test("sin productos exentos no aparece ese chequeo", () => {
  assertEquals(levelOf(tropella(), "item_taxes_exentos"), "ausente");
});

Deno.test("si no se pudo contar productos, avisa en vez de dar ok", () => {
  assertEquals(levelOf(tropella({ itemTaxes: null }), "item_taxes"), "warn");
});

// ── certificationStep ──────────────────────────────────────────────────
Deno.test("certificationStep incompleto avisa pero no bloquea", () => {
  // Tropella real reporta 2 y el dueño confirmo que esta certificada.
  const input = tropella({ company: { ...tropella().company, certificationStep: 2 } });
  assertEquals(levelOf(input, "certification_step"), "warn");
  assertEquals(worstLevel(buildChecks(input)), "warn");
});

Deno.test("worstLevel: fail gana sobre warn, warn sobre ok", () => {
  assertEquals(worstLevel([{ key: "a", level: "ok", message: "" }]), "ok");
  assertEquals(worstLevel([{ key: "a", level: "ok", message: "" }, { key: "b", level: "warn", message: "" }]), "warn");
  assertEquals(
    worstLevel([{ key: "a", level: "warn", message: "" }, { key: "b", level: "fail", message: "" }]),
    "fail",
  );
});
