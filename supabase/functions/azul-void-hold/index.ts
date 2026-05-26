// PRD §7.4 — azul-void-hold
//
// POST /functions/v1/azul-void-hold
// Body: { session_id, azul_order_id }
//
// Anula el Hold de RD$1 inmediatamente después de tokenizar exitosamente.
// Invocada server-to-server por azul-callback con bearer service_role.
//
// IMPORTANTE (PRD §7.4 edge case): el doc de Azul describe Void en el contexto
// de Payment Page (con redirect). Acá lo hacemos server-to-server. Esta es la
// hipótesis de trabajo: el endpoint del Payment Page acepta POST con TrxType=Void
// + AzulOrderID del Hold + mismos campos + AuthHash. Si en pruebas reales falla,
// el item "Confirmar mecanismo de Void sobre Hold" del PRD §13 nos dará el camino
// alternativo (probablemente vía Web Services de Azul, no Payment Page).

import { corsPreflight, errorResponse, jsonResponse } from "../_shared/responses.ts";
import { getAzulEnv } from "../_shared/env.ts";
import { getServiceClient } from "../_shared/supabase.ts";
import {
  computeAuthHash,
  paymentPageFieldsToOrdered,
} from "../_shared/azul.ts";

const VERIFICATION_AMOUNT_CENTS = "100";
const VERIFICATION_ITBIS = "000";

Deno.serve(async (req) => {
  const pre = corsPreflight(req);
  if (pre) return pre;

  if (req.method !== "POST") {
    return errorResponse(405, "method_not_allowed", "Use POST");
  }

  // Validar service_role bearer.
  const authHeader = req.headers.get("Authorization") ?? "";
  const env = getAzulEnv();
  const expected = `Bearer ${env.supabaseServiceRoleKey}`;
  if (authHeader !== expected) {
    return errorResponse(401, "unauthorized", "Service role required");
  }

  let body: { session_id?: string; azul_order_id?: string };
  try {
    body = await req.json();
  } catch {
    return errorResponse(400, "invalid_request", "Body must be JSON");
  }

  const sessionId = body.session_id?.trim();
  const azulOrderId = body.azul_order_id?.trim();
  if (!sessionId || !azulOrderId) {
    return errorResponse(400, "invalid_request", "session_id and azul_order_id required");
  }

  const service = getServiceClient();
  const { data: session, error: sessErr } = await service
    .from("azul_payment_sessions")
    .select("id, order_number")
    .eq("id", sessionId)
    .maybeSingle();

  if (sessErr || !session) {
    return errorResponse(404, "not_found", "Session not found");
  }

  // Construir campos del Void. Reutilizamos el mismo orden y mismos valores que
  // el Hold original — solo cambiamos TrxType (que no entra al hash).
  const callbackBase = env.publicCallbackBaseUrl.replace(/\/+$/, "");
  const fields = {
    merchantId: env.azulMerchantId,
    merchantName: env.azulMerchantName,
    merchantType: env.azulMerchantType,
    currencyCode: env.azulCurrencyCode,
    orderNumber: session.order_number,
    amount: VERIFICATION_AMOUNT_CENTS,
    itbis: VERIFICATION_ITBIS,
    approvedUrl: `${callbackBase}/azul-callback?status=approved`,
    declinedUrl: `${callbackBase}/azul-callback?status=declined`,
    cancelUrl: `${callbackBase}/azul-callback?status=cancelled`,
    useCustomField1: "1",
    customField1Label: "Verificacion de tarjeta",
    customField1Value: "RD$1.00 sera reembolsado automaticamente",
    useCustomField2: "0",
    customField2Label: "",
    customField2Value: "",
  };
  const authHash = await computeAuthHash(
    paymentPageFieldsToOrdered(fields),
    env.azulAuthKey,
  );

  const formBody = new URLSearchParams();
  formBody.set("MerchantId", fields.merchantId);
  formBody.set("MerchantName", fields.merchantName);
  formBody.set("MerchantType", fields.merchantType);
  formBody.set("TrxType", "Void");
  formBody.set("AzulOrderId", azulOrderId);
  formBody.set("CurrencyCode", fields.currencyCode);
  formBody.set("OrderNumber", fields.orderNumber);
  formBody.set("Amount", fields.amount);
  formBody.set("ITBIS", fields.itbis);
  formBody.set("ApprovedUrl", fields.approvedUrl);
  formBody.set("DeclinedUrl", fields.declinedUrl);
  formBody.set("CancelUrl", fields.cancelUrl);
  formBody.set("UseCustomField1", fields.useCustomField1);
  formBody.set("CustomField1Label", fields.customField1Label);
  formBody.set("CustomField1Value", fields.customField1Value);
  formBody.set("UseCustomField2", fields.useCustomField2);
  formBody.set("CustomField2Label", fields.customField2Label);
  formBody.set("CustomField2Value", fields.customField2Value);
  formBody.set("AuthHash", authHash);

  // Retry simple con backoff exponencial: 1s, 3s, 10s, 30s.
  const backoffs = [0, 1000, 3000, 10000, 30000];
  let lastError: string | null = null;
  let lastStatus = 0;
  let lastBody = "";

  for (let attempt = 0; attempt < backoffs.length; attempt++) {
    if (backoffs[attempt] > 0) {
      await new Promise((r) => setTimeout(r, backoffs[attempt]));
    }
    try {
      const resp = await fetch(env.azulPaymentPageUrl, {
        method: "POST",
        headers: {
          "Content-Type": "application/x-www-form-urlencoded",
        },
        body: formBody.toString(),
      });
      lastStatus = resp.status;
      lastBody = await resp.text();

      // Loguear cada intento como webservice_response.
      await service.from("azul_webhook_events").insert({
        event_type: "webservice_response",
        http_method: "POST",
        raw_url: env.azulPaymentPageUrl,
        raw_body: lastBody.slice(0, 10000), // cap por si Azul devuelve un HTML inmenso
        related_session_id: session.id,
        processed: true,
        processing_error: resp.ok ? null : `http_${resp.status}`,
      });

      if (resp.ok) {
        // Asumimos éxito si Azul responde 2xx. La validación fina del payload
        // de respuesta dependerá del formato que devuelva (HTML vs query string)
        // — la confirmaremos contra el primer Void real en pruebas.
        return jsonResponse({
          ok: true,
          azul_status: resp.status,
          attempt: attempt + 1,
        });
      }
      lastError = `http_${resp.status}`;
    } catch (e) {
      lastError = e instanceof Error ? e.message : String(e);
      await service.from("azul_webhook_events").insert({
        event_type: "webservice_response",
        http_method: "POST",
        raw_url: env.azulPaymentPageUrl,
        raw_body: `EXCEPTION: ${lastError}`,
        related_session_id: session.id,
        processed: true,
        processing_error: lastError,
      });
    }
  }

  // Agotados los reintentos. Devolvemos 502 y dejamos la sesión sin cambios —
  // un job de retención (F6) puede reintentar más adelante.
  return errorResponse(
    502,
    "void_failed_after_retries",
    `Void to Azul failed after ${backoffs.length} attempts (last status: ${lastStatus})`,
    { lastError, lastStatus, lastBody: lastBody.slice(0, 500) },
  );
});
