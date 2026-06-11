// Golden test del AuthHash en Deno — paralelo al test Dart
// (test/core/billing/azul/azul_hash_test.dart).
//
// Si este test pasa y el Dart pasa, garantizamos que ambos lenguajes producen
// el mismo hash byte-exacto contra el ejemplo de Azul.
//
// Correr local:
//   deno test supabase/functions/_shared/azul_test.ts

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  computeAuthHash,
  computeResponseAuthHash,
  constantTimeEquals,
  generateChargeOrderNumber,
  generateTokenizeOrderNumber,
  parseCallbackQuery,
  paymentPageFieldsToOrdered,
  responseFieldsToOrdered,
  validateCallbackHash,
} from "./azul.ts";

const GOLDEN_AUTH_KEY =
  "asdhakjshdkjasdasmndajksdkjaskldga8odya9d8yoasyd98asdyaisdhoaisyd0a8sydoashd8oasydoiahdpiashd09ayusidhaos8dy0a8dya08syd0a8ssdsax";

const EXPECTED_HASH =
  "6662f1e52260cf845a848845e6769ece7ef173c2809ea215f1fc8907442a21f3" +
  "95bdfbb8422eb4d6ce8673eb6961beb730d97842e8030668516beba717ffff5b";

Deno.test("golden: produce hash byte-exacto del ejemplo de Azul §6.3", async () => {
  const fields = paymentPageFieldsToOrdered({
    merchantId: "39038540035",
    merchantName: "Prueba AZUL",
    merchantType: "ECommerce",
    currencyCode: "$",
    orderNumber: "001",
    amount: "10000",
    itbis: "000",
    approvedUrl: "https://google.com",
    declinedUrl: "https://google.com",
    cancelUrl: "https://google.com",
    // defaults: useCustomField1/2="0", labels/values=""
  });
  const hash = await computeAuthHash(fields, GOLDEN_AUTH_KEY);
  assertEquals(hash, EXPECTED_HASH);
  assertEquals(hash.length, 128);
});

Deno.test("hash es determinístico", async () => {
  const fields = ["a", "b", "c"];
  const h1 = await computeAuthHash(fields, "k");
  const h2 = await computeAuthHash(fields, "k");
  assertEquals(h1, h2);
});

Deno.test("avalanche: cambiar UN char cambia el hash", async () => {
  const base = await computeAuthHash(["a", "b", "c"], "k");
  const cambio = await computeAuthHash(["a", "B", "c"], "k");
  assertEquals(base === cambio, false);
});

Deno.test("UTF-8 multibyte: acentos producen hash distinto a sin acento", async () => {
  const con = await computeAuthHash(["Restauración"], "k");
  const sin = await computeAuthHash(["Restauracion"], "k");
  assertEquals(con === sin, false);
  assertEquals(con.length, 128);
});

Deno.test("campos vacíos no rompen — concat sin separadores", async () => {
  const h1 = await computeAuthHash(["", "medio", "", "final", ""], "k");
  const h2 = await computeAuthHash(["mediofinal"], "k");
  assertEquals(h1, h2);
});

Deno.test("constantTimeEquals — iguales", () => {
  const h = "deadbeef".repeat(16);
  assertEquals(constantTimeEquals(h, h), true);
});

Deno.test("constantTimeEquals — distintos del mismo largo", () => {
  const a = "a".repeat(128);
  const b = "b".repeat(128);
  assertEquals(constantTimeEquals(a, b), false);
});

Deno.test("constantTimeEquals — largos distintos no lanza", () => {
  assertEquals(constantTimeEquals("abc", "abcd"), false);
  assertEquals(constantTimeEquals("", "a"), false);
});

Deno.test("constantTimeEquals — vacíos iguales", () => {
  assertEquals(constantTimeEquals("", ""), true);
});

// --- OrderNumber: Azul exige alfanumérico ≤15 (sin guiones bajos) ---

const ORDER_RE = /^[A-Z0-9]{1,15}$/;

Deno.test("generateChargeOrderNumber: alfanumérico y exactamente 15 chars", () => {
  const on = generateChargeOrderNumber(
    "4d068df7-a5bf-4f55-bea1-70a84d08d662",
    new Date(Date.UTC(2026, 5, 1)), // junio 2026
    1,
  );
  assertEquals(on.length <= 15, true);
  assertEquals(ORDER_RE.test(on), true);
  assertEquals(on, "MP4D068DF726061"); // MP + 4D068DF7 + 26 + 06 + 1
});

Deno.test("generateChargeOrderNumber: determinístico por (membership, período, intento)", () => {
  const id = "4d068df7-a5bf-4f55-bea1-70a84d08d662";
  const d = new Date(Date.UTC(2026, 5, 1));
  assertEquals(generateChargeOrderNumber(id, d, 1), generateChargeOrderNumber(id, d, 1));
  // distinto intento → distinto número
  assertEquals(
    generateChargeOrderNumber(id, d, 1) === generateChargeOrderNumber(id, d, 2),
    false,
  );
  // distinto mes → distinto número
  const d2 = new Date(Date.UTC(2026, 6, 1));
  assertEquals(
    generateChargeOrderNumber(id, d, 1) === generateChargeOrderNumber(id, d2, 1),
    false,
  );
});

Deno.test("generateTokenizeOrderNumber: alfanumérico, 15 chars y único", () => {
  const a = generateTokenizeOrderNumber();
  const b = generateTokenizeOrderNumber();
  assertEquals(a.length, 15);
  assertEquals(ORDER_RE.test(a), true);
  assertEquals(a === b, false); // aleatorio
});

// --- Hash de RESPUESTA del callback — UTF-16LE (doc Página de Pago pág. 9) ---
// Golden byte-exacto contra un callback REAL aprobado de Azul (2026-06-11).
// Si este test pasa, validateCallbackHash valida los callbacks reales y NO los
// marca 'tampered' por error (el bug que teníamos: usaba UTF-8).

const REAL_CALLBACK_FIELDS = {
  orderNumber: "MTCDCBBEC0C45A4",
  amount: "100",
  authorizationCode: "OK7978",
  dateTime: "20260611150359",
  responseCode: "ISO8583",
  isoCode: "00",
  responseMessage: "APROBADA",
  errorDescription: "",
  rrn: "2026061115040244918003",
};
const REAL_CALLBACK_HASH =
  "851b86a09188613c794dd7d71cfccced782ec26200299a8da89c3f40191a4fd5" +
  "5599a3316ee25549871dc8def64e553a3eaea7b467cbc847e6d5c1f1b4b77abf";

Deno.test("golden respuesta: computeResponseAuthHash (UTF-16LE) byte-exacto vs callback real", async () => {
  const h = await computeResponseAuthHash(
    responseFieldsToOrdered(REAL_CALLBACK_FIELDS),
    GOLDEN_AUTH_KEY,
  );
  assertEquals(h, REAL_CALLBACK_HASH);
});

Deno.test("regresión del bug: el hash de respuesta en UTF-8 NO coincide (por eso era UTF-16LE)", async () => {
  const ordered = responseFieldsToOrdered(REAL_CALLBACK_FIELDS);
  const utf16 = await computeResponseAuthHash(ordered, GOLDEN_AUTH_KEY);
  const utf8 = await computeAuthHash(ordered, GOLDEN_AUTH_KEY);
  assertEquals(utf16, REAL_CALLBACK_HASH);
  assertEquals(utf16 === utf8, false);
});

Deno.test("parseCallbackQuery lee IsoCode (no ISOCode) y validateCallbackHash aprueba el callback real", async () => {
  const u = new URL(
    "https://x/azul-callback?status=approved" +
      "&OrderNumber=MTCDCBBEC0C45A4&Amount=100&AuthorizationCode=OK7978" +
      "&DateTime=20260611150359&ResponseCode=ISO8583&IsoCode=00" +
      "&ResponseMessage=APROBADA&ErrorDescription=&RRN=2026061115040244918003" +
      "&AuthHash=" + REAL_CALLBACK_HASH,
  );
  const cb = parseCallbackQuery(u);
  assertEquals(cb.isoCode, "00"); // antes leía "" por el casing del param
  assertEquals(await validateCallbackHash(cb, GOLDEN_AUTH_KEY), true);
});
