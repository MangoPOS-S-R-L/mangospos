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
  constantTimeEquals,
  generateChargeOrderNumber,
  generateTokenizeOrderNumber,
  paymentPageFieldsToOrdered,
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
