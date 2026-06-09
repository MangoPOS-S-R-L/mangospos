// PRD-Azul-Subscriptions §6 — AuthHash HMAC-SHA512 (versión Deno/TypeScript).
//
// Paralelo byte-exacto del AzulHash en Dart (lib/core/billing/azul/azul_hash.dart).
// Cualquier cambio acá debe espejarse allá. El golden test (azul_test.ts) garantiza
// que ambos lenguajes producen el mismo hash.

// ---------------------------------------------------------------------------
// 1. Cálculo de hash
// ---------------------------------------------------------------------------

const enc = new TextEncoder();

/**
 * Calcula el AuthHash HMAC-SHA512(UTF-8) que va en el form HTML de Azul.
 *
 * Algoritmo Azul:
 *   - Concatenar campos en orden estricto, sin separadores. Campo vacío = "".
 *   - Mensaje = concat(campos) + AuthKey (la AuthKey va AL FINAL del mensaje).
 *   - HMAC-SHA512 con AuthKey como clave HMAC.
 *   - Encoding UTF-8 (D2 — validado contra golden test del PRD §6.3).
 *   - Output hex lowercase, 128 chars.
 */
export async function computeAuthHash(
  orderedFields: string[],
  authKey: string,
): Promise<string> {
  const message = orderedFields.join("") + authKey;
  const keyBytes = enc.encode(authKey);
  const cryptoKey = await crypto.subtle.importKey(
    "raw",
    keyBytes,
    { name: "HMAC", hash: "SHA-512" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign("HMAC", cryptoKey, enc.encode(message));
  return bytesToHex(new Uint8Array(signature));
}

function bytesToHex(bytes: Uint8Array): string {
  const out = new Array<string>(bytes.length);
  for (let i = 0; i < bytes.length; i++) {
    out[i] = bytes[i].toString(16).padStart(2, "0");
  }
  return out.join("");
}

/**
 * Comparación constant-time de dos hashes hex (PRD §7.3 — anti timing attack).
 * Falla rápido en longitudes distintas (no es secreto), pero el loop sobre bytes
 * iguales nunca hace early-exit.
 */
export function constantTimeEquals(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) {
    diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return diff === 0;
}

// ---------------------------------------------------------------------------
// 2. Field builders ordenados por TrxType (PRD §6.2)
//    TrxType NO entra al hash; solo viaja en el form HTML.
// ---------------------------------------------------------------------------

/** Campos de Sale/Hold/Create al Payment Page. */
export interface PaymentPageFields {
  merchantId: string;
  merchantName: string;
  merchantType: string;
  currencyCode: string;
  orderNumber: string;
  amount: string; // entero en unidad mínima (DOP centavos). Ej: 100 = RD$1.00
  itbis: string; // entero o "000" si no aplica
  approvedUrl: string;
  declinedUrl: string;
  cancelUrl: string;
  useCustomField1?: string; // "0" | "1"
  customField1Label?: string;
  customField1Value?: string;
  useCustomField2?: string;
  customField2Label?: string;
  customField2Value?: string;
}

export function paymentPageFieldsToOrdered(f: PaymentPageFields): string[] {
  return [
    f.merchantId,
    f.merchantName,
    f.merchantType,
    f.currencyCode,
    f.orderNumber,
    f.amount,
    f.itbis,
    f.approvedUrl,
    f.declinedUrl,
    f.cancelUrl,
    f.useCustomField1 ?? "0",
    f.customField1Label ?? "",
    f.customField1Value ?? "",
    f.useCustomField2 ?? "0",
    f.customField2Label ?? "",
    f.customField2Value ?? "",
  ];
}

/** Campos de la respuesta de Azul para validar el AuthHash recibido. */
export interface ResponseFields {
  orderNumber: string;
  amount: string;
  authorizationCode: string;
  dateTime: string;
  responseCode: string;
  isoCode: string;
  responseMessage: string;
  errorDescription: string;
  rrn: string;
}

export function responseFieldsToOrdered(f: ResponseFields): string[] {
  return [
    f.orderNumber,
    f.amount,
    f.authorizationCode,
    f.dateTime,
    f.responseCode,
    f.isoCode,
    f.responseMessage,
    f.errorDescription,
    f.rrn,
  ];
}

// ---------------------------------------------------------------------------
// 3. OrderNumber generators (PRD §4 D6 — idempotencia determinística)
// ---------------------------------------------------------------------------

// IMPORTANTE: Azul valida OrderNumber como ALFANUMÉRICO y de longitud ≤15.
// Guiones bajos o más de 15 caracteres → `VALIDATION_ERROR:OrderNumber`
// (confirmado en pruebas contra pruebas.azul.com.do, 2026-06-09). Por eso aquí
// solo se usan [A-Z0-9] y exactamente 15 chars.

/**
 * Tokenización: `MT{13 hex}` (15 chars, [A-Z0-9]). Aleatorio — único cross-business
 * (respaldado por el UNIQUE de azul_payment_sessions.order_number).
 */
export function generateTokenizeOrderNumber(): string {
  const hex = crypto.randomUUID().replaceAll("-", "").toUpperCase();
  return `MT${hex.slice(0, 13)}`;
}

/**
 * Cobro mensual: `MP{8 hex del membershipId}{YY}{MM}{attempt}` = 15 chars [A-Z0-9].
 * Determinístico: dado el mismo (membership, período, intento), siempre el mismo
 * order_number. Hace que el cron sea idempotente — segunda corrida choca con el
 * UNIQUE de azul_charges. La unicidad fuerte la garantiza igualmente el índice
 * único (membership_id, billing_period_start, attempt_number).
 */
export function generateChargeOrderNumber(
  membershipId: string,
  billingPeriodStart: Date,
  attemptNumber: number,
): string {
  const yy = billingPeriodStart.getUTCFullYear().toString().slice(-2);
  const mm = (billingPeriodStart.getUTCMonth() + 1).toString().padStart(2, "0");
  const compactId = membershipId.replaceAll("-", "").slice(0, 8).toUpperCase();
  return `MP${compactId}${yy}${mm}${attemptNumber}`;
}

// ---------------------------------------------------------------------------
// 4. Tipos para los callbacks de Azul
// ---------------------------------------------------------------------------

export interface AzulCallbackParams {
  orderNumber: string;
  amount: string;
  authorizationCode: string;
  dateTime: string;
  responseCode: string;
  isoCode: string;
  responseMessage: string;
  errorDescription: string;
  rrn: string;
  authHash: string;
  azulOrderId: string;
  // DataVault fields presentes solo si SaveToDataVault=1 y la trx fue aprobada
  dataVaultToken?: string;
  dataVaultExpiration?: string;
  dataVaultBrand?: string;
  cardNumber?: string;
}

/**
 * Extrae los campos del callback desde el query string que llega vía GET.
 * Azul usa nombres específicos en el query — los normalizamos a camelCase.
 */
export function parseCallbackQuery(url: URL): AzulCallbackParams {
  const q = (k: string) => url.searchParams.get(k) ?? "";
  return {
    orderNumber: q("OrderNumber"),
    amount: q("Amount"),
    authorizationCode: q("AuthorizationCode"),
    dateTime: q("DateTime"),
    responseCode: q("ResponseCode"),
    isoCode: q("ISOCode"),
    responseMessage: q("ResponseMessage"),
    errorDescription: q("ErrorDescription"),
    rrn: q("RRN"),
    authHash: q("AuthHash"),
    azulOrderId: q("AzulOrderId") || q("AzulOrderID"),
    dataVaultToken: q("DataVaultToken") || undefined,
    dataVaultExpiration: q("DataVaultExpiration") || undefined,
    dataVaultBrand: q("DataVaultBrand") || undefined,
    cardNumber: q("CardNumber") || undefined,
  };
}

/**
 * Valida que el AuthHash recibido coincida con el calculado a partir de los
 * campos de respuesta (PRD §7.3 paso d). Retorna true si es auténtico.
 */
export async function validateCallbackHash(
  callback: AzulCallbackParams,
  authKey: string,
): Promise<boolean> {
  const expected = await computeAuthHash(
    responseFieldsToOrdered({
      orderNumber: callback.orderNumber,
      amount: callback.amount,
      authorizationCode: callback.authorizationCode,
      dateTime: callback.dateTime,
      responseCode: callback.responseCode,
      isoCode: callback.isoCode,
      responseMessage: callback.responseMessage,
      errorDescription: callback.errorDescription,
      rrn: callback.rrn,
    }),
    authKey,
  );
  return constantTimeEquals(expected, callback.authHash.toLowerCase());
}
