// Pruebas del esquema de firma que va a implementar el canal.
// Correr: deno test --no-check --allow-env --allow-net \
//            supabase/functions/_shared/external-channel-auth_test.ts
//
// `--no-check` porque el cliente de Supabase que viene de esm.sh arrastra
// @types/node y este repo no tiene node_modules para las edge functions. Los
// modulos si pasan `deno check` uno por uno.

import { hmacHex } from "./external-channel-auth.ts";

// Asserts propios: el `std` de deno.land arrastra @types/node y rompe el check
// en este repo, que no tiene node_modules para las edge functions.
function assertEquals<T>(actual: T, expected: T, msg?: string): void {
  if (actual !== expected) {
    throw new Error(msg ?? `esperaba ${String(expected)}, llego ${String(actual)}`);
  }
}
function assertNotEquals<T>(actual: T, expected: T, msg?: string): void {
  if (actual === expected) {
    throw new Error(msg ?? `no deberian ser iguales: ${String(actual)}`);
  }
}

const SECRET = "3c3cec00fe8f4f018042af2ee626f923f14ba817d9924552b7c7124ee8294009";

Deno.test("la firma es estable para el mismo cuerpo y timestamp", async () => {
  const body = '{"external_order_id":"pnc_1","external_number":"142"}';
  const t = 1757280000;
  const a = await hmacHex(SECRET, `${t}.${body}`);
  const b = await hmacHex(SECRET, `${t}.${body}`);
  assertEquals(a, b);
  assertEquals(a.length, 64); // sha256 en hex
});

Deno.test("cambiar UN caracter del cuerpo cambia la firma", async () => {
  const t = 1757280000;
  const original = await hmacHex(SECRET, `${t}.{"total":1250.00}`);
  const alterado = await hmacHex(SECRET, `${t}.{"total":1250.01}`);
  assertNotEquals(original, alterado);
});

Deno.test("re-serializar el JSON rompe la firma (por eso se firma el cuerpo crudo)", async () => {
  const t = 1757280000;
  const crudo = '{"a":1,"b":2}';
  const reserializado = JSON.stringify(JSON.parse('{"a":1, "b":2}'));
  assertEquals(reserializado, '{"a":1,"b":2}');
  // Mismo objeto, distinto texto: un espacio de mas y ya no cuadra.
  const conEspacio = '{"a":1, "b":2}';
  assertNotEquals(
    await hmacHex(SECRET, `${t}.${crudo}`),
    await hmacHex(SECRET, `${t}.${conEspacio}`),
  );
});

Deno.test("otro secreto produce otra firma", async () => {
  const t = 1757280000;
  const body = '{"x":1}';
  assertNotEquals(
    await hmacHex(SECRET, `${t}.${body}`),
    await hmacHex("otro-secreto", `${t}.${body}`),
  );
});

Deno.test("un GET firma la cadena vacia", async () => {
  const t = 1757280000;
  const firma = await hmacHex(SECRET, `${t}.`);
  assertEquals(firma.length, 64);
});
