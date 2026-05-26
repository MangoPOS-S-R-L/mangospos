// PRD §7.3 — azul-callback
//
// GET /functions/v1/azul-callback?status=<approved|declined|cancelled>&...
//
// Recibe el redirect del Payment Page de Azul. Es la pieza más crítica:
//   - Loguea SIEMPRE el callback en azul_webhook_events (antes de cualquier
//     validación) para tener bitácora forense.
//   - Valida AuthHash recibido (HMAC-SHA512 con campos de respuesta).
//   - Si válido: INSERT payment_method status='verified', dispara void-hold,
//     marca sesión approved.
//   - Si inválido: marca sesión 'tampered', alerta admin (TODO email/Slack).
//   - Idempotencia: doble callback con OrderNumber ya procesado no reprocesa,
//     solo incrementa callback_count y redirige al estado final.
//   - Final: redirige al cliente a PUBLIC_RETURN_BASE_URL con result en query.

import { corsPreflight, redirect } from "../_shared/responses.ts";
import { getAzulEnv } from "../_shared/env.ts";
import { getServiceClient } from "../_shared/supabase.ts";
import {
  parseCallbackQuery,
  validateCallbackHash,
} from "../_shared/azul.ts";

Deno.serve(async (req) => {
  const pre = corsPreflight(req);
  if (pre) return pre;

  const url = new URL(req.url);
  const env = getAzulEnv();
  const service = getServiceClient();

  // ----- 1. Log RAW del callback ANTES de cualquier validación. -----
  const sourceIp = req.headers.get("x-forwarded-for")?.split(",")[0].trim()
    ?? req.headers.get("cf-connecting-ip")
    ?? null;
  const rawHeaders: Record<string, string> = {};
  req.headers.forEach((v, k) => (rawHeaders[k] = v));
  const rawQuery: Record<string, string> = {};
  url.searchParams.forEach((v, k) => (rawQuery[k] = v));

  const { data: eventRow, error: eventErr } = await service
    .from("azul_webhook_events")
    .insert({
      event_type: "payment_page_callback",
      source_ip: sourceIp,
      http_method: req.method,
      raw_url: url.toString(),
      raw_query: rawQuery,
      raw_headers: rawHeaders,
      processed: false,
    })
    .select("id")
    .single();
  if (eventErr) {
    console.error("[azul-callback] failed to log webhook event", eventErr);
    // No reventamos — seguimos para no perder el callback. Re-loguear al final.
  }
  const eventId = eventRow?.id ?? null;

  // ----- 2. Caso "cancelled" — el cliente abortó en Azul. -----
  const statusParam = url.searchParams.get("status");
  const callback = parseCallbackQuery(url);

  if (statusParam === "cancelled") {
    return await handleCancelled(callback, eventId);
  }

  if (statusParam !== "approved" && statusParam !== "declined") {
    await markEventProcessed(eventId, "unknown_status_param");
    return redirect(buildReturnUrl(env.publicReturnBaseUrl, "error"));
  }

  // ----- 3. Buscar la sesión por OrderNumber. -----
  const { data: session, error: sessErr } = await service
    .from("azul_payment_sessions")
    .select("id, business_id, intent_type, order_number, status, amount_cents, callback_count")
    .eq("order_number", callback.orderNumber)
    .maybeSingle();

  if (sessErr) {
    console.error("[azul-callback] db error fetching session", sessErr);
    await markEventProcessed(eventId, "db_error_session_lookup");
    return redirect(buildReturnUrl(env.publicReturnBaseUrl, "error"));
  }

  if (!session) {
    console.warn("[azul-callback] no session for OrderNumber", callback.orderNumber);
    await markEventProcessed(eventId, "session_not_found");
    return redirect(buildReturnUrl(env.publicReturnBaseUrl, "error"));
  }

  // Asociar el evento a la sesión.
  if (eventId) {
    await service
      .from("azul_webhook_events")
      .update({ related_session_id: session.id })
      .eq("id", eventId);
  }

  // ----- 4. Idempotencia: si la sesión ya está en estado final, no reprocesar. -----
  if (session.status !== "redirected" && session.status !== "pending") {
    await service
      .from("azul_payment_sessions")
      .update({
        callback_count: (session.callback_count ?? 0) + 1,
        updated_at: new Date().toISOString(),
      })
      .eq("id", session.id);
    await markEventProcessed(eventId, "duplicate_callback_ignored");
    return redirect(buildReturnUrl(env.publicReturnBaseUrl, terminalToResult(session.status)));
  }

  // ----- 5. Validar AuthHash. -----
  const hashValid = await validateCallbackHash(callback, env.azulAuthKey);
  if (!hashValid) {
    console.error("[azul-callback] AuthHash MISMATCH — possible tampering", {
      orderNumber: callback.orderNumber,
      sessionId: session.id,
    });
    await service
      .from("azul_payment_sessions")
      .update({
        status: "tampered",
        auth_hash_received: callback.authHash,
        raw_callback_query: url.search,
        callback_count: (session.callback_count ?? 0) + 1,
        updated_at: new Date().toISOString(),
      })
      .eq("id", session.id);
    if (eventId) {
      await service
        .from("azul_webhook_events")
        .update({ auth_hash_valid: false, processed: true, processing_error: "tampered" })
        .eq("id", eventId);
    }
    // TODO: alertar admins (Resend/Slack) — agregar en F6.
    return redirect(buildReturnUrl(env.publicReturnBaseUrl, "error"));
  }

  // ----- 6. Hash válido. Procesar approved / declined. -----
  if (statusParam === "approved") {
    return await handleApproved(session, callback, eventId, url);
  }
  return await handleDeclined(session, callback, eventId);
});

// ---------------------------------------------------------------------------
// Handlers por tipo de resultado
// ---------------------------------------------------------------------------

async function handleCancelled(
  callback: ReturnType<typeof parseCallbackQuery>,
  eventId: string | null,
): Promise<Response> {
  const env = getAzulEnv();
  const service = getServiceClient();

  if (callback.orderNumber) {
    const { data: session } = await service
      .from("azul_payment_sessions")
      .select("id, callback_count")
      .eq("order_number", callback.orderNumber)
      .maybeSingle();
    if (session) {
      await service
        .from("azul_payment_sessions")
        .update({
          status: "cancelled",
          completed_at: new Date().toISOString(),
          callback_count: (session.callback_count ?? 0) + 1,
          updated_at: new Date().toISOString(),
        })
        .eq("id", session.id)
        .in("status", ["pending", "redirected"]);
      if (eventId) {
        await service
          .from("azul_webhook_events")
          .update({ related_session_id: session.id, processed: true })
          .eq("id", eventId);
      }
    }
  }
  return redirect(buildReturnUrl(env.publicReturnBaseUrl, "cancelled"));
}

async function handleApproved(
  session: { id: string; business_id: string; intent_type: string; callback_count: number | null },
  callback: ReturnType<typeof parseCallbackQuery>,
  eventId: string | null,
  url: URL,
): Promise<Response> {
  const env = getAzulEnv();
  const service = getServiceClient();

  // Validar que tenemos los campos del DataVault (porque pedimos SaveToDataVault=1).
  if (!callback.dataVaultToken || !callback.dataVaultExpiration) {
    console.error("[azul-callback] approved sin DataVaultToken — config Azul", {
      orderNumber: callback.orderNumber,
    });
    await service
      .from("azul_payment_sessions")
      .update({
        status: "error",
        error_description: "Approved sin DataVaultToken",
        raw_callback_query: url.search,
        callback_count: (session.callback_count ?? 0) + 1,
        updated_at: new Date().toISOString(),
      })
      .eq("id", session.id);
    await markEventProcessed(eventId, "approved_without_token");
    return redirect(buildReturnUrl(env.publicReturnBaseUrl, "error"));
  }

  // Si es replace_card, desmarcar default actual antes de insertar nueva.
  if (session.intent_type === "replace_card") {
    await service
      .from("azul_payment_methods")
      .update({ is_default: false, updated_at: new Date().toISOString() })
      .eq("business_id", session.business_id)
      .eq("is_default", true);
  } else {
    // tokenize_and_verify: si por alguna razón ya hay default, lo bajamos.
    await service
      .from("azul_payment_methods")
      .update({ is_default: false, updated_at: new Date().toISOString() })
      .eq("business_id", session.business_id)
      .eq("is_default", true);
  }

  // INSERT payment_method con status=verified, is_default=true.
  const { data: pm, error: pmErr } = await service
    .from("azul_payment_methods")
    .insert({
      business_id: session.business_id,
      data_vault_token: callback.dataVaultToken,
      data_vault_expiration: callback.dataVaultExpiration,
      data_vault_brand: callback.dataVaultBrand ?? "UNKNOWN",
      card_number_masked: callback.cardNumber ?? "************",
      azul_order_id_at_creation: callback.azulOrderId,
      status: "verified",
      is_default: true,
      verification_session_id: session.id,
    })
    .select("id")
    .single();

  if (pmErr || !pm) {
    console.error("[azul-callback] failed to insert payment_method", pmErr);
    await service
      .from("azul_payment_sessions")
      .update({
        status: "error",
        error_description: `PM insert failed: ${pmErr?.message}`,
        callback_count: (session.callback_count ?? 0) + 1,
        updated_at: new Date().toISOString(),
      })
      .eq("id", session.id);
    await markEventProcessed(eventId, "pm_insert_failed");
    return redirect(buildReturnUrl(env.publicReturnBaseUrl, "error"));
  }

  // UPDATE session approved con todos los datos.
  await service
    .from("azul_payment_sessions")
    .update({
      status: "approved",
      azul_order_id: callback.azulOrderId,
      authorization_code: callback.authorizationCode,
      response_code: callback.responseCode,
      iso_code: callback.isoCode,
      response_message: callback.responseMessage,
      error_description: callback.errorDescription,
      rrn: callback.rrn,
      auth_hash_received: callback.authHash,
      raw_callback_query: url.search,
      resulting_payment_method_id: pm.id,
      completed_at: new Date().toISOString(),
      callback_count: (session.callback_count ?? 0) + 1,
      updated_at: new Date().toISOString(),
    })
    .eq("id", session.id);

  if (eventId) {
    await service
      .from("azul_webhook_events")
      .update({
        related_session_id: session.id,
        auth_hash_valid: true,
        processed: true,
      })
      .eq("id", eventId);
  }

  // Disparar void-hold fire-and-forget. NO await: si falla, hay job de retención.
  void invokeVoidHold(session.id, callback.azulOrderId).catch((err) => {
    console.error("[azul-callback] void-hold invocation failed (will retry)", err);
  });

  return redirect(buildReturnUrl(env.publicReturnBaseUrl, "approved"));
}

async function handleDeclined(
  session: { id: string; callback_count: number | null },
  callback: ReturnType<typeof parseCallbackQuery>,
  eventId: string | null,
): Promise<Response> {
  const env = getAzulEnv();
  const service = getServiceClient();

  await service
    .from("azul_payment_sessions")
    .update({
      status: "declined",
      azul_order_id: callback.azulOrderId,
      authorization_code: callback.authorizationCode,
      response_code: callback.responseCode,
      iso_code: callback.isoCode,
      response_message: callback.responseMessage,
      error_description: callback.errorDescription,
      rrn: callback.rrn,
      auth_hash_received: callback.authHash,
      completed_at: new Date().toISOString(),
      callback_count: (session.callback_count ?? 0) + 1,
      updated_at: new Date().toISOString(),
    })
    .eq("id", session.id);

  if (eventId) {
    await service
      .from("azul_webhook_events")
      .update({ related_session_id: session.id, auth_hash_valid: true, processed: true })
      .eq("id", eventId);
  }

  const reason = encodeURIComponent(callback.responseMessage || "declined");
  return redirect(`${buildReturnUrl(env.publicReturnBaseUrl, "declined")}&reason=${reason}`);
}

// ---------------------------------------------------------------------------
// Utilidades
// ---------------------------------------------------------------------------

function buildReturnUrl(base: string, result: string): string {
  const root = base.replace(/\/+$/, "");
  return `${root}/onboarding/payment-result?result=${result}`;
}

function terminalToResult(sessionStatus: string): string {
  switch (sessionStatus) {
    case "approved":
      return "approved";
    case "declined":
      return "declined";
    case "cancelled":
      return "cancelled";
    case "tampered":
    case "error":
    case "timeout":
      return "error";
    default:
      return "error";
  }
}

async function markEventProcessed(eventId: string | null, error?: string): Promise<void> {
  if (!eventId) return;
  const service = getServiceClient();
  await service
    .from("azul_webhook_events")
    .update({ processed: true, processing_error: error ?? null })
    .eq("id", eventId);
}

async function invokeVoidHold(sessionId: string, azulOrderId: string): Promise<void> {
  const env = getAzulEnv();
  const base = env.publicCallbackBaseUrl.replace(/\/+$/, "");
  const resp = await fetch(`${base}/azul-void-hold`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${env.supabaseServiceRoleKey}`,
    },
    body: JSON.stringify({ session_id: sessionId, azul_order_id: azulOrderId }),
  });
  if (!resp.ok) {
    throw new Error(`void-hold returned ${resp.status}`);
  }
}
