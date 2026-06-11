// PRD-Azul-Subscriptions §6 (post-pivot v2) — cliente Azul vía sidecar mTLS.
//
// Por qué hay un sidecar: Supabase Edge Runtime 1.67.4 no permite mTLS
// (no expone Deno.createHttpClient, bloquea Deno.Command, restringe FS).
// Por eso delegamos la llamada mTLS a `azul-proxy` (Node.js plano, ver
// supabase/azul-proxy/README.md).
//
// Esta función se ve usada por todas las edge functions Azul (B3+). Centraliza:
//   - URL del sidecar
//   - Auth con shared token
//   - Mapeo de TrxType / Method
//   - Tipado de respuesta

import { getAzulEnv } from "./env.ts";

// ---------------------------------------------------------------------------
// 1. Tipos
// ---------------------------------------------------------------------------

export type AzulMethod =
  | "ProcessPayment"
  | "ProcessDataVault"
  | "VerifyPayment"
  // Continuación del flujo 3D Secure 2.0 (solo CIT). Ver PRD-Azul-3DSecure §5.2.
  | "ProcessThreeDSMethod"
  | "ProcessThreeDSChallenge";

/**
 * Nodo presente cuando Azul responde IsoCode=3D2METHOD (frictionless con
 * recolección de datos del navegador). Trae el HTML del iframe oculto que hay
 * que renderizar para que el ACS recopile el ambiente del navegador.
 */
export interface ThreeDSMethodResponse {
  MethodForm?: string;
}

/**
 * Nodo presente cuando Azul responde IsoCode=3D (requiere desafío). `CReq` se
 * postea (campo `creq`, minúscula, case-sensitive) al `RedirectPostUrl` del ACS.
 */
export interface ThreeDSChallengeResponse {
  CReq?: string;
  MD?: string;
  PaReq?: string;
  RedirectPostUrl?: string;
}

export interface AzulResponse {
  IsoCode?: string;
  ResponseCode?: string;
  ResponseMessage?: string;
  ErrorDescription?: string;
  AuthorizationCode?: string;
  AzulOrderId?: string;
  CustomOrderId?: string;
  RRN?: string;
  DateTime?: string;
  Amount?: string;
  Ticket?: string;
  DataVaultToken?: string;
  DataVaultExpiration?: string;
  DataVaultBrand?: string;
  CardNumber?: string;
  Found?: string;
  // Nodos 3DS 2.0 (objetos anidados, no strings). Solo presentes en respuestas
  // intermedias del flujo de autenticación CIT.
  ThreeDSMethod?: ThreeDSMethodResponse;
  ThreeDSChallenge?: ThreeDSChallengeResponse;
  // Index amplio: Azul puede devolver campos extra (string) o anidados (3DS).
  [k: string]: unknown;
}

export interface AzulCallResult {
  ok: boolean;
  httpStatus: number;
  durationMs: number;
  body: AzulResponse;
}

interface ProxyOk {
  ok: boolean;
  httpStatus: number;
  durationMs: number;
  body: AzulResponse;
}

interface ProxyErr {
  error: { code: string; message: string; detail?: unknown };
}

export class AzulCallError extends Error {
  constructor(
    message: string,
    public readonly code: string,
    public readonly httpStatus: number,
    public readonly detail?: unknown,
  ) {
    super(message);
    this.name = "AzulCallError";
  }
}

// ---------------------------------------------------------------------------
// 2. Llamada base al sidecar
// ---------------------------------------------------------------------------

/**
 * Llama un Method de Azul a través del sidecar mTLS.
 *
 * El sidecar (`azul-proxy`) corre en la misma red Docker. Le pasamos el body
 * tal cual va al API (sin Auth1/Auth2 ni cert — eso lo agrega el sidecar).
 * El sidecar devuelve `{ ok, httpStatus, durationMs, body }` o `{ error }`.
 *
 * Throws `AzulCallError` si:
 *   - El sidecar no responde / network error
 *   - El sidecar rechazó nuestro token
 *   - El sidecar retornó un body malformado
 *   - Azul retornó algo no-JSON
 *
 * NO throw si Azul retornó JSON con IsoCode != "00" — el caller decide qué
 * hacer con esos casos de negocio.
 */
export async function callAzul(
  method: AzulMethod,
  payload: Record<string, unknown>,
): Promise<AzulCallResult> {
  const env = getAzulEnv();
  const proxyUrl = `${env.azulProxyUrl.replace(/\/$/, "")}/call`;

  let res: Response;
  try {
    res = await fetch(proxyUrl, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-proxy-auth": env.azulProxyAuthToken,
      },
      body: JSON.stringify({ method, body: payload }),
    });
  } catch (e) {
    throw new AzulCallError(
      `Sidecar unreachable: ${e instanceof Error ? e.message : String(e)}`,
      "sidecar_unreachable",
      0,
    );
  }

  const text = await res.text();
  let parsed: ProxyOk | ProxyErr;
  try {
    parsed = JSON.parse(text) as ProxyOk | ProxyErr;
  } catch (_e) {
    throw new AzulCallError(
      `Sidecar returned non-JSON (http=${res.status}): ${text.slice(0, 500)}`,
      "sidecar_non_json",
      res.status,
    );
  }

  if (!res.ok || "error" in parsed) {
    const err = "error" in parsed ? parsed.error : { code: "unknown", message: text };
    throw new AzulCallError(
      `Sidecar error: ${err.message}`,
      err.code,
      res.status,
      "detail" in err ? err.detail : undefined,
    );
  }

  return parsed;
}

// ---------------------------------------------------------------------------
// 3. Helpers tipados por operación
// ---------------------------------------------------------------------------

export interface CreateDataVaultInput {
  cardNumber: string;
  expiration: string; // YYYYMM
  cvc: string;
  customOrderId?: string;
}

export function createDataVaultToken(input: CreateDataVaultInput) {
  const env = getAzulEnv();
  return callAzul("ProcessDataVault", {
    Channel: "EC",
    Store: env.azulMerchantId,
    TrxType: "CREATE",
    CardNumber: input.cardNumber,
    Expiration: input.expiration,
    CVC: input.cvc,
    ...(input.customOrderId ? { CustomOrderId: input.customOrderId } : {}),
  });
}

export interface DeleteDataVaultInput {
  dataVaultToken: string;
}

export function deleteDataVaultToken(input: DeleteDataVaultInput) {
  const env = getAzulEnv();
  return callAzul("ProcessDataVault", {
    Channel: "EC",
    Store: env.azulMerchantId,
    TrxType: "DELETE",
    DataVaultToken: input.dataVaultToken,
  });
}

export interface ChargeWithTokenInput {
  dataVaultToken: string;
  amountCents: number;
  itbisCents: number;
  orderNumber: string;
  customerEmail?: string;
}

export function chargeWithToken(input: ChargeWithTokenInput) {
  const env = getAzulEnv();
  return callAzul("ProcessPayment", {
    Channel: "EC",
    Store: env.azulMerchantId,
    PosInputMode: "E-Commerce",
    TrxType: "Sale",
    Amount: input.amountCents.toString(),
    // Azul rechaza Itbis="0" con VALIDATION_ERROR:Itbis. Cuando no hay impuesto
    // separado debe ir "000"; con impuesto, los centavos como entero.
    Itbis: input.itbisCents > 0 ? input.itbisCents.toString() : "000",
    CurrencyPosCode: "$",
    OrderNumber: input.orderNumber,
    DataVaultToken: input.dataVaultToken,
    AcquirerRefData: "1",
    // Cobro recurrente iniciado por el comercio (MIT). El doc de Azul v1.2
    // eliminó el "método de recurrencia" dedicado: las suscripciones se cobran
    // con el token + este indicador (STANDING_ORDER = orden permanente),
    // respaldado por la transacción CIT original (la tokenización).
    merchantInitiatedIndicator: "STANDING_ORDER",
    // MIT no lleva 3D Secure: no hay tarjetahabiente presente para el desafío.
    ForceNo3DS: "1",
    ...(input.customerEmail ? { CustomerServiceEmail: input.customerEmail } : {}),
  });
}

export interface HoldWithTokenInput {
  dataVaultToken: string;
  amountCents: number;
  itbisCents: number;
  orderNumber: string;
}

/**
 * Pre-autorización (Hold) con token: reserva fondos sin liquidar. Se usa para
 * verificar la tarjeta al registrarla (Hold de RD$1, luego Void). A diferencia
 * de chargeWithToken (cobro recurrente MIT), este Hold es CIT — el
 * tarjetahabiente está presente y acaba de digitar su tarjeta; este Hold es la
 * transacción CIT original que respalda los cobros MIT futuros. Va sin
 * merchantInitiatedIndicator y con ForceNo3DS=1 (verificación rápida, sin
 * desafío que no podemos manejar in-app).
 */
export function holdWithToken(input: HoldWithTokenInput) {
  const env = getAzulEnv();
  return callAzul("ProcessPayment", {
    Channel: "EC",
    Store: env.azulMerchantId,
    PosInputMode: "E-Commerce",
    TrxType: "Hold",
    Amount: input.amountCents.toString(),
    Itbis: input.itbisCents > 0 ? input.itbisCents.toString() : "000",
    CurrencyPosCode: "$",
    OrderNumber: input.orderNumber,
    DataVaultToken: input.dataVaultToken,
    AcquirerRefData: "1",
    ForceNo3DS: "1",
  });
}

export interface RefundInput {
  azulOrderId: string;
  amountCents: number;
  itbisCents: number;
  orderNumber: string;
}

export function refund(input: RefundInput) {
  const env = getAzulEnv();
  return callAzul("ProcessPayment", {
    Channel: "EC",
    Store: env.azulMerchantId,
    PosInputMode: "E-Commerce",
    TrxType: "Refund",
    Amount: input.amountCents.toString(),
    // Azul rechaza Itbis="0" con VALIDATION_ERROR:Itbis. Cuando no hay impuesto
    // separado debe ir "000"; con impuesto, los centavos como entero.
    Itbis: input.itbisCents > 0 ? input.itbisCents.toString() : "000",
    CurrencyPosCode: "$",
    OrderNumber: input.orderNumber,
    AzulOrderId: input.azulOrderId,
  });
}

export interface VoidInput {
  azulOrderId: string;
}

export function voidTransaction(input: VoidInput) {
  const env = getAzulEnv();
  return callAzul("ProcessPayment", {
    Channel: "EC",
    Store: env.azulMerchantId,
    TrxType: "Void",
    AzulOrderId: input.azulOrderId,
  });
}

export interface VerifyPaymentInput {
  customOrderId: string;
}

/**
 * VerifyPayment — consulta una transacción previa por CustomOrderId. Útil para:
 *   - Smoke test del sidecar (con ID inexistente esperamos IsoCode="00", Found="0")
 *   - Reconciliación: confirmar si una venta llegó cuando perdimos la respuesta
 */
export function verifyPayment(input: VerifyPaymentInput) {
  const env = getAzulEnv();
  return callAzul("VerifyPayment", {
    Channel: "EC",
    Store: env.azulMerchantId,
    CustomOrderId: input.customOrderId,
  });
}

// ---------------------------------------------------------------------------
// 4. 3D Secure 2.0 (solo CIT — tarjetahabiente presente)
// ---------------------------------------------------------------------------
//
// Ver PRD-Azul-3DSecure.md. El cobro recurrente (MIT) NO usa esto: sigue con
// ForceNo3DS="1" en chargeWithToken. Estos helpers son para el registro/
// verificación de tarjeta del comercio, donde el tarjetahabiente digita la
// tarjeta en una página servida por nosotros y abierta en su navegador.
//
// El flujo es una máquina de estados (PRD §6):
//   processPaymentWith3DS (Hold/Sale + nodos 3DS)
//     → IsoCode 3D2METHOD → render MethodForm → processThreeDSMethod → ...
//     → IsoCode 3D        → render CReq desafío → processThreeDSChallenge → ...
//     → IsoCode 00        → aprobada
//
// Estos builders SOLO arman el payload; la orquestación (renders, esperas,
// persistencia) vive en las edge functions azul-3ds-* (fases 3DS.2/3DS.3).

/** Nodo ThreeDSAuth — URLs de callback del ACS + preferencia de desafío. */
export interface ThreeDSAuthInput {
  /** URL nuestra (por-sesión, con sid único) donde el ACS postea el `cres`. */
  termUrl: string;
  /** URL nuestra (por-sesión) donde el ACS notifica el fin del MethodForm. */
  methodNotificationUrl: string;
  /**
   * Preferencia de desafío. Default "01" (sin preferencia). "04" no aplica en
   * RD. Ver PRD D20.
   */
  requestorChallengeIndicator?: "01" | "02" | "03" | "04";
}

/**
 * Nodo CardHolderInfo — ayuda al motor de riesgo del emisor. Name y Email son
 * obligatorios; el resto se omite si va vacío (recomendación del doc Azul).
 */
export interface CardHolderInfoInput {
  name: string;
  email: string;
  phoneHome?: string;
  phoneMobile?: string;
  phoneWork?: string;
  billingAddressLine1?: string;
  billingAddressLine2?: string;
  billingAddressLine3?: string;
  billingAddressCity?: string;
  billingAddressState?: string;
  billingAddressCountry?: string; // ISO 2 chars
  billingAddressZip?: string;
  shippingAddressLine1?: string;
  shippingAddressLine2?: string;
  shippingAddressLine3?: string;
  shippingAddressCity?: string;
  shippingAddressState?: string;
  shippingAddressCountry?: string; // ISO 2 chars
  shippingAddressZip?: string;
}

/**
 * Nodo BrowserInfo — capturado del navegador del tarjetahabiente. Los 9 campos
 * son obligatorios para autenticar. AcceptHeader/IPAddress/UserAgent se
 * completan server-side desde los headers; el resto con el script JS del doc.
 */
export interface BrowserInfoInput {
  acceptHeader: string;
  ipAddress: string;
  language: string;
  colorDepth: string;
  screenWidth: string;
  screenHeight: string;
  timeZone: string;
  userAgent: string;
  javaScriptEnabled: string; // "true" | "false"
}

/** Quita claves con valor undefined o string vacío (para omitir opcionales). */
function pruneEmpty(obj: Record<string, string | undefined>): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [k, v] of Object.entries(obj)) {
    if (v !== undefined && v !== "") out[k] = v;
  }
  return out;
}

function buildCardHolderInfo(c: CardHolderInfoInput): Record<string, string> {
  // Name y Email obligatorios → van siempre; el resto se poda si está vacío.
  return {
    Name: c.name,
    Email: c.email,
    ...pruneEmpty({
      PhoneHome: c.phoneHome,
      PhoneMobile: c.phoneMobile,
      PhoneWork: c.phoneWork,
      BillingAddressLine1: c.billingAddressLine1,
      BillingAddressLine2: c.billingAddressLine2,
      BillingAddressLine3: c.billingAddressLine3,
      BillingAddressCity: c.billingAddressCity,
      BillingAddressState: c.billingAddressState,
      BillingAddressCountry: c.billingAddressCountry,
      BillingAddressZip: c.billingAddressZip,
      ShippingAddressLine1: c.shippingAddressLine1,
      ShippingAddressLine2: c.shippingAddressLine2,
      ShippingAddressLine3: c.shippingAddressLine3,
      ShippingAddressCity: c.shippingAddressCity,
      ShippingAddressState: c.shippingAddressState,
      ShippingAddressCountry: c.shippingAddressCountry,
      ShippingAddressZip: c.shippingAddressZip,
    }),
  };
}

function buildBrowserInfo(b: BrowserInfoInput): Record<string, string> {
  // Los 9 son obligatorios → no se podan.
  return {
    AcceptHeader: b.acceptHeader,
    IPAddress: b.ipAddress,
    Language: b.language,
    ColorDepth: b.colorDepth,
    ScreenWidth: b.screenWidth,
    ScreenHeight: b.screenHeight,
    TimeZone: b.timeZone,
    UserAgent: b.userAgent,
    JavaScriptEnabled: b.javaScriptEnabled,
  };
}

export interface ProcessPaymentWith3DSInput {
  /** "Hold" para verificación de tarjeta (D17), "Sale" para cobro CIT directo. */
  trxType: "Sale" | "Hold";
  amountCents: number;
  itbisCents: number;
  orderNumber: string;
  /** Tarjeta cruda (CIT con tarjetahabiente digitando). Mutuamente excluyente con dataVaultToken. */
  card?: { cardNumber: string; expiration: string; cvc: string };
  /** Cobro CIT sobre tarjeta ya tokenizada (alternativa a card). */
  dataVaultToken?: string;
  /** "1" para tokenizar en el mismo round-trip (registro de tarjeta). */
  saveToDataVault?: boolean;
  customOrderId?: string;
  threeDSAuth: ThreeDSAuthInput;
  cardHolderInfo: CardHolderInfoInput;
  browserInfo: BrowserInfoInput;
}

/**
 * Inicia una transacción CIT (Sale/Hold) que pasa por 3D Secure 2.0. Agrega los
 * tres nodos (ThreeDSAuth, CardHolderInfo, BrowserInfo) y manda ForceNo3DS="0"
 * para activar la autenticación. La respuesta puede ser final (IsoCode 00) o
 * intermedia (3D2METHOD / 3D) — el caller maneja la continuación.
 */
export function processPaymentWith3DS(input: ProcessPaymentWith3DSInput) {
  const env = getAzulEnv();
  if (!input.card && !input.dataVaultToken) {
    throw new Error("processPaymentWith3DS: requiere card o dataVaultToken");
  }
  return callAzul("ProcessPayment", {
    Channel: "EC",
    Store: env.azulMerchantId,
    PosInputMode: "E-Commerce",
    TrxType: input.trxType,
    Amount: input.amountCents.toString(),
    Itbis: input.itbisCents > 0 ? input.itbisCents.toString() : "000",
    CurrencyPosCode: "$",
    OrderNumber: input.orderNumber,
    AcquirerRefData: "1",
    ...(input.card
      ? {
        CardNumber: input.card.cardNumber,
        Expiration: input.card.expiration,
        CVC: input.card.cvc,
      }
      : { DataVaultToken: input.dataVaultToken! }),
    SaveToDataVault: input.saveToDataVault ? "1" : "0",
    ...(input.customOrderId ? { CustomOrderId: input.customOrderId } : {}),
    // "0" (o Null/"") activa el flujo 3DS; "1" lo saltaría (eso es solo MIT).
    ForceNo3DS: "0",
    ThreeDSAuth: {
      TermUrl: input.threeDSAuth.termUrl,
      MethodNotificationUrl: input.threeDSAuth.methodNotificationUrl,
      RequestorChallengeIndicator:
        input.threeDSAuth.requestorChallengeIndicator ?? "01",
    },
    CardHolderInfo: buildCardHolderInfo(input.cardHolderInfo),
    BrowserInfo: buildBrowserInfo(input.browserInfo),
  });
}

export interface ProcessThreeDSMethodInput {
  azulOrderId: string;
  /** Resultado de la notificación del MethodForm. Ver PRD §5.3. */
  methodNotificationStatus:
    | "RECEIVED"
    | "EXPECTED_BUT_NOT_RECEIVED"
    | "NOT_EXPECTED";
}

/**
 * Paso 5 (SF) / continuación tras el MethodForm: notifica a Azul que el método
 * 3DS terminó para que avance la autenticación. Respuesta: final (00) o escala
 * a desafío (3D).
 */
export function processThreeDSMethod(input: ProcessThreeDSMethodInput) {
  const env = getAzulEnv();
  return callAzul("ProcessThreeDSMethod", {
    Channel: "EC",
    Store: env.azulMerchantId,
    AzulOrderId: input.azulOrderId,
    MethodNotificationStatus: input.methodNotificationStatus,
  });
}

export interface ProcessThreeDSChallengeInput {
  azulOrderId: string;
  /** Valor `cres` devuelto por el ACS al TermUrl tras el desafío. */
  cRes: string;
}

/**
 * Paso final del flujo de desafío: envía el `cres` del ACS para completar la
 * autorización. Respuesta: IsoCode 00 (aprobada) o distinto (declinada).
 */
export function processThreeDSChallenge(input: ProcessThreeDSChallengeInput) {
  const env = getAzulEnv();
  return callAzul("ProcessThreeDSChallenge", {
    Channel: "EC",
    Store: env.azulMerchantId,
    AzulOrderId: input.azulOrderId,
    CRes: input.cRes,
  });
}
