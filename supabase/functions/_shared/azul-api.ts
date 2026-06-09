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
  | "VerifyPayment";

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
  [k: string]: string | undefined;
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
    ...(input.customerEmail ? { CustomerServiceEmail: input.customerEmail } : {}),
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
