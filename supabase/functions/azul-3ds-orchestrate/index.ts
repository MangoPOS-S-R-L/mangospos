// azul-3ds-orchestrate — cerebro server-side de la máquina de estados 3DS 2.0.
//
// POST /functions/v1/azul-3ds-orchestrate?sid=<session_id>
// Público (autorizado por el sid). Llamado por azul-3ds-page vía fetch.
// Body:
//   { action: "start", card: {number, expiration:"YYYYMM", cvc},
//     cardholder: {name, email}, browserInfo: {...} }
//   { action: "method-complete" }
// → { next: "approved"|"declined"|"method"|"challenge", ... }
//
// NUNCA persiste ni loguea PAN/CVC. Ver PRD-Azul-3DSecure §6/§9.

import { corsPreflight, errorResponse, jsonResponse } from "../_shared/responses.ts";
import { getAzulEnv } from "../_shared/env.ts";
import { getServiceClient } from "../_shared/supabase.ts";
import { processPaymentWith3DS, processThreeDSMethod } from "../_shared/azul-api.ts";
import {
  classify3DSResponse,
  clientIpFromHeaders,
  decideMethodNotificationStatus,
  STANDARD_ACCEPT_HEADER,
} from "../_shared/azul-3ds.ts";
import { finalizeApprovedSession, logWebhookEvent } from "../_shared/azul-3ds-flow.ts";

interface StartBody {
  action: "start";
  card?: { number?: string; expiration?: string; cvc?: string };
  cardholder?: { name?: string; email?: string };
  browserInfo?: Record<string, string>;
}
interface MethodCompleteBody {
  action: "method-complete";
}
type Body = StartBody | MethodCompleteBody;

function threeDSUrls(sid: string) {
  const base = getAzulEnv().publicCallbackBaseUrl.replace(/\/+$/, "");
  return {
    termUrl: `${base}/azul-3ds-callback?kind=term&sid=${sid}`,
    methodNotificationUrl: `${base}/azul-3ds-callback?kind=method&sid=${sid}`,
  };
}

Deno.serve(async (req) => {
  const pre = corsPreflight(req);
  if (pre) return pre;
  if (req.method !== "POST") {
    return errorResponse(405, "method_not_allowed", "Use POST");
  }

  const sid = new URL(req.url).searchParams.get("sid");
  if (!sid) return errorResponse(400, "invalid_request", "Falta sid");

  let body: Body;
  try {
    body = await req.json();
  } catch {
    return errorResponse(400, "invalid_request", "Body must be JSON");
  }

  const service = getServiceClient();
  const { data: session, error } = await service
    .from("azul_payment_sessions")
    .select("id, business_id, order_number, status, expires_at, azul_order_id, resulting_payment_method_id, method_notification_received_at, threeds_flow")
    .eq("id", sid)
    .maybeSingle();

  if (error) return errorResponse(500, "db_error", "Error al cargar la sesión");
  if (!session) return errorResponse(404, "not_found", "Sesión no encontrada");
  if (new Date(session.expires_at) <= new Date()) {
    await service.from("azul_payment_sessions").update({ status: "timeout" }).eq("id", sid);
    return errorResponse(410, "expired", "La sesión expiró");
  }

  // -------------------------------------------------------------------------
  // ACCIÓN: start — primer ProcessPayment (Hold RD$1, SaveToDataVault=1) con 3DS
  // -------------------------------------------------------------------------
  if (body.action === "start") {
    // Consumo único: solo si sigue 'pending'.
    const { data: claimed } = await service
      .from("azul_payment_sessions")
      .update({ status: "authenticating", redirected_at: new Date().toISOString() })
      .eq("id", sid)
      .eq("status", "pending")
      .select("id")
      .maybeSingle();
    if (!claimed) {
      return errorResponse(409, "already_started", "La sesión ya fue iniciada");
    }

    const number = (body.card?.number ?? "").replace(/\s+/g, "");
    const expiration = (body.card?.expiration ?? "").trim();
    const cvc = (body.card?.cvc ?? "").trim();
    const name = (body.cardholder?.name ?? "").trim();
    const email = (body.cardholder?.email ?? "").trim();
    if (!/^[0-9]{13,19}$/.test(number)) {
      return failSession(service, sid, "invalid_card", "Número de tarjeta inválido");
    }
    if (!/^[0-9]{6}$/.test(expiration)) {
      return failSession(service, sid, "invalid_card", "Expiración debe ser AAAAMM");
    }
    if (!/^[0-9]{3,4}$/.test(cvc)) {
      return failSession(service, sid, "invalid_card", "CVC inválido");
    }
    if (!name || !email) {
      return failSession(service, sid, "invalid_request", "Nombre y email son obligatorios");
    }

    const bi = body.browserInfo ?? {};
    const browserInfo = {
      acceptHeader: STANDARD_ACCEPT_HEADER,
      ipAddress: clientIpFromHeaders(req.headers),
      language: bi.language || "es-DO",
      colorDepth: bi.colorDepth || "24",
      screenWidth: bi.screenWidth || "0",
      screenHeight: bi.screenHeight || "0",
      timeZone: bi.timeZone || "0",
      userAgent: bi.userAgent || req.headers.get("user-agent") || "",
      javaScriptEnabled: bi.javaScriptEnabled || "true",
    };
    const cardHolderInfo = { name, email };
    const urls = threeDSUrls(sid);

    let result;
    try {
      result = await processPaymentWith3DS({
        trxType: "Hold",
        amountCents: 100,
        itbisCents: 0,
        orderNumber: session.order_number,
        card: { cardNumber: number, expiration, cvc },
        saveToDataVault: true,
        threeDSAuth: { termUrl: urls.termUrl, methodNotificationUrl: urls.methodNotificationUrl },
        cardHolderInfo,
        browserInfo,
      });
    } catch (e) {
      return failSession(service, sid, "azul_unreachable", e instanceof Error ? e.message : String(e));
    }

    const azul = result.body;
    await service
      .from("azul_payment_sessions")
      .update({
        azul_order_id: azul.AzulOrderId ?? null,
        browser_info: browserInfo,
        cardholder_info: cardHolderInfo, // sin PAN/CVC
      })
      .eq("id", sid);
    await logEvent(service, sid, "ProcessPayment 3DS (Hold)", azul, result.httpStatus);

    return await handleClassified(service, { ...session, azul_order_id: azul.AzulOrderId ?? session.azul_order_id }, result.httpStatus, azul, sid, true);
  }

  // -------------------------------------------------------------------------
  // ACCIÓN: method-complete — tras renderizar el MethodForm, continuar
  // -------------------------------------------------------------------------
  if (body.action === "method-complete") {
    if (session.status !== "authenticating") {
      return errorResponse(409, "bad_state", `Estado inesperado: ${session.status}`);
    }
    if (!session.azul_order_id) {
      return failSession(service, sid, "bad_state", "Falta azul_order_id");
    }

    const notificationReceived = !!session.method_notification_received_at;
    const methodStatus = decideMethodNotificationStatus({
      methodFormSent: true,
      notificationReceived,
    });
    await service
      .from("azul_payment_sessions")
      .update({ threeds_method_status: methodStatus })
      .eq("id", sid);

    let result;
    try {
      result = await processThreeDSMethod({
        azulOrderId: session.azul_order_id,
        methodNotificationStatus: methodStatus,
      });
    } catch (e) {
      return failSession(service, sid, "azul_unreachable", e instanceof Error ? e.message : String(e));
    }

    const azul = result.body;
    await logEvent(service, sid, "ProcessThreeDSMethod", azul, result.httpStatus);
    return await handleClassified(service, session, result.httpStatus, azul, sid, true);
  }

  return errorResponse(400, "invalid_request", "action desconocida");
});

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Aplica la clasificación de la respuesta 3DS y devuelve el JSON para la página. */
async function handleClassified(
  // deno-lint-ignore no-explicit-any
  service: any,
  // deno-lint-ignore no-explicit-any
  session: any,
  httpStatus: number,
  // deno-lint-ignore no-explicit-any
  azul: any,
  sid: string,
  methodFormSent: boolean,
): Promise<Response> {
  const next = classify3DSResponse(httpStatus, azul);

  if (next.kind === "approved") {
    const fin = await finalizeApprovedSession(service, session, azul);
    if (fin.ok) return jsonResponse({ next: "approved", payment_method_id: fin.paymentMethodId });
    return jsonResponse({ next: "declined", message: fin.reason ?? "No se pudo completar" });
  }

  if (next.kind === "method") {
    await service
      .from("azul_payment_sessions")
      .update({ threeds_flow: "frictionless" })
      .eq("id", sid);
    return jsonResponse({ next: "method", methodForm: next.methodForm });
  }

  if (next.kind === "challenge") {
    await service
      .from("azul_payment_sessions")
      .update({ threeds_flow: "challenge", challenge_started_at: new Date().toISOString() })
      .eq("id", sid);
    return jsonResponse({
      next: "challenge",
      creq: next.creq,
      redirectPostUrl: next.redirectPostUrl,
      termUrl: threeDSUrls(sid).termUrl,
    });
  }

  // declined
  void methodFormSent;
  await service
    .from("azul_payment_sessions")
    .update({
      status: "declined",
      iso_code: next.iso ?? null,
      response_message: next.message ?? null,
      error_description: next.errorDescription ?? null,
      completed_at: new Date().toISOString(),
    })
    .eq("id", sid);
  return jsonResponse({ next: "declined", message: next.message ?? "Transacción declinada" });
}

/** Marca la sesión en error y devuelve un errorResponse. */
async function failSession(
  // deno-lint-ignore no-explicit-any
  service: any,
  sid: string,
  code: string,
  message: string,
): Promise<Response> {
  await service
    .from("azul_payment_sessions")
    .update({ status: "error", response_message: message, completed_at: new Date().toISOString() })
    .eq("id", sid);
  return errorResponse(code === "azul_unreachable" ? 502 : 400, code, message);
}

/** Log redactado del WS (sin PAN/CVC). */
async function logEvent(
  // deno-lint-ignore no-explicit-any
  service: any,
  sid: string,
  label: string,
  // deno-lint-ignore no-explicit-any
  azul: any,
  httpStatus: number,
): Promise<void> {
  await logWebhookEvent(service, {
    eventType: "webservice_response",
    sessionId: sid,
    rawUrl: `azul-proxy /call (${label})`,
    body: {
      IsoCode: azul.IsoCode ?? null,
      ResponseCode: azul.ResponseCode ?? null,
      ResponseMessage: azul.ResponseMessage ?? null,
      ErrorDescription: azul.ErrorDescription ?? null,
      AzulOrderId: azul.AzulOrderId ?? null,
    },
    processed: httpStatus === 200,
  });
}
