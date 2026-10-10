import { assert, assertEquals, assertNotEquals, assertRejects } from "https://deno.land/std@0.208.0/assert/mod.ts";
import { importSecretKey, openSecret, sealSecret, SEALED_PREFIX } from "./secret-box.ts";

// 32 bytes fijos: los tests no dependen de una llave real.
const KEY_B64 = btoa(String.fromCharCode(...Array.from({ length: 32 }, (_, i) => i)));
const BIZ = "38a0dfd6-f342-4e8c-b9d6-daf9e07d60da";

Deno.test("secret-box: ida y vuelta, con acentos y espacios", async () => {
  const key = await importSecretKey(KEY_B64);
  const sealed = await sealSecret(key, "Clave Ñandú 2026 ", BIZ);
  assert(sealed.startsWith(SEALED_PREFIX));
  assert(!sealed.includes("Clave"));
  assertEquals(await openSecret(key, sealed, BIZ), "Clave Ñandú 2026 ");
});

Deno.test("secret-box: el mismo texto cifra distinto cada vez (iv aleatorio)", async () => {
  const key = await importSecretKey(KEY_B64);
  assertNotEquals(await sealSecret(key, "abc", BIZ), await sealSecret(key, "abc", BIZ));
});

Deno.test("secret-box: no abre con otro negocio, otra llave ni si se altero", async () => {
  const key = await importSecretKey(KEY_B64);
  const sealed = await sealSecret(key, "abc", BIZ);
  await assertRejects(() => openSecret(key, sealed, "otro-negocio"));

  const other = await importSecretKey(btoa(String.fromCharCode(...new Array(32).fill(7))));
  await assertRejects(() => openSecret(other, sealed, BIZ));

  const raw = atob(sealed.slice(SEALED_PREFIX.length));
  const flipped = raw.slice(0, -1) + String.fromCharCode(raw.charCodeAt(raw.length - 1) ^ 1);
  await assertRejects(() => openSecret(key, SEALED_PREFIX + btoa(flipped), BIZ));

  await assertRejects(() => openSecret(key, "abc", BIZ));
});

Deno.test("secret-box: rechaza llaves que no son de 32 bytes", async () => {
  await assertRejects(() => importSecretKey(btoa("corta")));
  await assertRejects(() => importSecretKey("no es base64!!"));
});
