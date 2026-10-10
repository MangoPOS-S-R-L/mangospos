// Cifrado de secretos de clientes que MangoPOS SI tiene que guardar, como la
// clave de la Oficina Virtual de la DGII (el operador la usa para la
// postulacion y las pruebas de certificacion).
//
// AES-256-GCM con una llave que vive en el entorno de la Edge Function, no en
// la BD: un respaldo de la base por si solo no revela ninguna clave. El
// `context` (por ejemplo el business_id) va como dato autenticado, asi que un
// valor copiado a la fila de otro negocio no se puede descifrar.
//
// Formato guardado: "v1:" + base64(iv de 12 bytes || texto cifrado con tag).

export const SEALED_PREFIX = "v1:";
const IV_BYTES = 12;
const KEY_BYTES = 32;

function toBase64(bytes: Uint8Array): string {
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin);
}

function fromBase64(text: string) {
  return Uint8Array.from(atob(text), (c) => c.charCodeAt(0));
}

/** Importa la llave (32 bytes en base64, p. ej. `openssl rand -base64 32`). */
export async function importSecretKey(rawBase64: string): Promise<CryptoKey> {
  let raw;
  try {
    raw = fromBase64(rawBase64.trim());
  } catch {
    throw new Error("La llave de cifrado no es base64 valido.");
  }
  if (raw.length !== KEY_BYTES) {
    throw new Error(`La llave de cifrado debe ser de ${KEY_BYTES} bytes (tiene ${raw.length}).`);
  }
  return await crypto.subtle.importKey("raw", raw, "AES-GCM", false, ["encrypt", "decrypt"]);
}

export async function sealSecret(key: CryptoKey, plain: string, context: string): Promise<string> {
  const iv = crypto.getRandomValues(new Uint8Array(IV_BYTES));
  const cipher = new Uint8Array(
    await crypto.subtle.encrypt(
      { name: "AES-GCM", iv, additionalData: new TextEncoder().encode(context) },
      key,
      new TextEncoder().encode(plain),
    ),
  );
  const out = new Uint8Array(iv.length + cipher.length);
  out.set(iv);
  out.set(cipher, iv.length);
  return SEALED_PREFIX + toBase64(out);
}

/** Lanza si el valor no es de este formato, se altero, o es de otro `context`. */
export async function openSecret(key: CryptoKey, sealed: string, context: string): Promise<string> {
  if (!sealed.startsWith(SEALED_PREFIX)) throw new Error("Formato de secreto desconocido.");
  const bytes = fromBase64(sealed.slice(SEALED_PREFIX.length));
  if (bytes.length <= IV_BYTES) throw new Error("Secreto incompleto.");
  const plain = await crypto.subtle.decrypt(
    {
      name: "AES-GCM",
      iv: bytes.slice(0, IV_BYTES),
      additionalData: new TextEncoder().encode(context),
    },
    key,
    bytes.slice(IV_BYTES),
  );
  return new TextDecoder().decode(plain);
}
