import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  chargeCustomOrderId,
  classifyChargeVerify,
  decideOnExistingCharge,
  IN_FLIGHT_WINDOW_MS,
  inFlightCutoffIso,
  parseFound,
  VERIFY_MIN_AGE_MS,
} from "./retry_policy.ts";

const NOW = Date.parse("2026-08-13T07:00:09Z");
const ago = (ms: number) => new Date(NOW - ms).toISOString();

// ---------------------------------------------------------------------------
// decideOnExistingCharge
// ---------------------------------------------------------------------------

Deno.test("pending recién creado está en vuelo: no se vuelve a mandar a Azul (agosto 2026)", () => {
  // El segundo pedido llegó segundos después del primero, con la venta todavía
  // en Azul. Antes esto se reintentaba y cobraba dos veces.
  assertEquals(
    decideOnExistingCharge({ status: "pending", attempted_at: ago(6_000) }, NOW),
    "in_progress",
  );
});

Deno.test("approved y declined son terminales: jamás se recobran", () => {
  assertEquals(decideOnExistingCharge({ status: "approved", attempted_at: ago(1_000) }, NOW), "terminal");
  assertEquals(decideOnExistingCharge({ status: "declined", attempted_at: ago(1_000) }, NOW), "terminal");
});

Deno.test("un estado inesperado no dispara un cobro automático", () => {
  assertEquals(decideOnExistingCharge({ status: "voided", attempted_at: ago(1_000) }, NOW), "terminal");
});

Deno.test("error de hace segundos: demasiado pronto para verificar con Azul", () => {
  assertEquals(decideOnExistingCharge({ status: "error", attempted_at: ago(30_000) }, NOW), "in_progress");
});

Deno.test("error con más de 2 minutos: se verifica y, si Azul no lo cobró, se reintenta", () => {
  assertEquals(decideOnExistingCharge({ status: "error", attempted_at: ago(VERIFY_MIN_AGE_MS) }, NOW), "retry");
  assertEquals(decideOnExistingCharge({ status: "error", attempted_at: ago(24 * 3600_000) }, NOW), "retry");
});

Deno.test("pending de más de 10 minutos se puede reintentar (el worker murió)", () => {
  assertEquals(
    decideOnExistingCharge({ status: "pending", attempted_at: ago(IN_FLIGHT_WINDOW_MS + 60_000) }, NOW),
    "retry",
  );
});

Deno.test("el borde exacto de la ventana ya es reintentable", () => {
  assertEquals(
    decideOnExistingCharge({ status: "pending", attempted_at: ago(IN_FLIGHT_WINDOW_MS) }, NOW),
    "retry",
  );
  assertEquals(
    decideOnExistingCharge({ status: "pending", attempted_at: ago(IN_FLIGHT_WINDOW_MS - 1) }, NOW),
    "in_progress",
  );
});

Deno.test("sin fecha legible no se cobra", () => {
  assertEquals(decideOnExistingCharge({ status: "pending", attempted_at: null }, NOW), "in_progress");
  assertEquals(decideOnExistingCharge({ status: "error", attempted_at: "basura" }, NOW), "in_progress");
});

Deno.test("inFlightCutoffIso es ahora menos la ventana", () => {
  assertEquals(inFlightCutoffIso(NOW), "2026-08-13T06:50:09.000Z");
});

// ---------------------------------------------------------------------------
// CustomOrderId
// ---------------------------------------------------------------------------

Deno.test("CustomOrderId del cobro: estable, sin guiones y con prefijo propio", () => {
  const id = "B01E3351-A28A-4CF3-86F7-95F8A9D103C9";
  assertEquals(chargeCustomOrderId(id), "mpch-b01e3351a28a4cf386f795f8a9d103c9");
  assertEquals(chargeCustomOrderId(id), chargeCustomOrderId(id.toLowerCase()));
  assertEquals(chargeCustomOrderId(id).length, 37);
});

// ---------------------------------------------------------------------------
// classifyChargeVerify
// ---------------------------------------------------------------------------

Deno.test("verificación: Azul encontró la venta aprobada → no se vuelve a cobrar", () => {
  assertEquals(
    classifyChargeVerify(200, { Found: "1", IsoCode: "00", ResponseCode: "ISO8583" }),
    "approved",
  );
});

Deno.test("verificación: Found=0 con IsoCode 00 NO es una venta (la consulta salió bien, la venta no existe)", () => {
  assertEquals(classifyChargeVerify(200, { Found: "0", IsoCode: "00" }), "not_charged");
});

Deno.test("verificación: venta encontrada pero rechazada o sin procesar → no movió dinero", () => {
  assertEquals(classifyChargeVerify(200, { Found: "1", IsoCode: "51", ResponseCode: "ISO8583" }), "not_charged");
  assertEquals(classifyChargeVerify(200, { Found: "true", IsoCode: "", ResponseCode: "Error" }), "not_charged");
});

Deno.test("verificación: respuesta ambigua o no-200 → no se cobra", () => {
  assertEquals(classifyChargeVerify(500, { Found: "1", IsoCode: "00" }), "unknown");
  assertEquals(classifyChargeVerify(200, { IsoCode: "00" }), "unknown");
  assertEquals(classifyChargeVerify(200, { Found: "quizás", IsoCode: "00" }), "unknown");
  assertEquals(classifyChargeVerify(200, { Found: "1", IsoCode: "", ResponseCode: "" }), "unknown");
});

Deno.test("parseFound acepta las formas que manda Azul", () => {
  assertEquals(parseFound("1"), true);
  assertEquals(parseFound("TRUE"), true);
  assertEquals(parseFound(0), false);
  assertEquals(parseFound("false"), false);
  assertEquals(parseFound(undefined), null);
});
