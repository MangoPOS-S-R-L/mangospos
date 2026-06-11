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

import {
  corsPreflight,
  escapeHtmlAttr,
  htmlResponse,
  redirect,
} from "../_shared/responses.ts";
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

  // Vista de resultado: a donde el propio callback redirige al cliente tras
  // procesar (aprobado/declinado/cancelado/error). Se sirve desde acá porque
  // azul-callback ya es público — así no dependemos de mangopos.do (que daba 404)
  // ni de una función nueva con verify_jwt.
  if (url.searchParams.get("view") === "result") {
    return renderResultPage(
      url.searchParams.get("result") ?? "error",
      url.searchParams.get("reason") ?? "",
    );
  }

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
    return redirect(buildReturnUrl("error"));
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
    return redirect(buildReturnUrl("error"));
  }

  if (!session) {
    console.warn("[azul-callback] no session for OrderNumber", callback.orderNumber);
    await markEventProcessed(eventId, "session_not_found");
    return redirect(buildReturnUrl("error"));
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
    return redirect(buildReturnUrl(terminalToResult(session.status)));
  }

  // ----- 5. Validar AuthHash. -----
  if (!env.azulAuthKey) {
    console.error("[azul-callback] AZUL_AUTH_KEY no configurado");
    await markEventProcessed(eventId, "no_auth_key");
    return redirect(buildReturnUrl("error"));
  }
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
    return redirect(buildReturnUrl("error"));
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
  return redirect(buildReturnUrl("cancelled"));
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
    return redirect(buildReturnUrl("error"));
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
    return redirect(buildReturnUrl("error"));
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

  return redirect(buildReturnUrl("approved"));
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
  return redirect(`${buildReturnUrl("declined")}&reason=${reason}`);
}

// ---------------------------------------------------------------------------
// Utilidades
// ---------------------------------------------------------------------------

// Redirige a la vista de resultado del PROPIO azul-callback (?view=result), no a
// mangopos.do/onboarding/payment-result (esa página del front no existe → 404).
function buildReturnUrl(result: string): string {
  const root = getAzulEnv().publicCallbackBaseUrl.replace(/\/+$/, "");
  return `${root}/azul-callback?view=result&result=${result}`;
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

// ---------------------------------------------------------------------------
// Vista de resultado (HTML servida en el navegador tras procesar el pago)
// ---------------------------------------------------------------------------

interface ResultView {
  icon: string;
  color: string;
  title: string;
  body: string;
}

const RESULT_VIEWS: Record<string, ResultView> = {
  approved: {
    icon: "✅",
    color: "#16A34A",
    title: "¡Tarjeta registrada!",
    body: "Tu tarjeta quedó verificada. Vuelve a la app de MangoPOS — aparecerá automáticamente.",
  },
  declined: {
    icon: "⚠️",
    color: "#B91C1C",
    title: "Tarjeta declinada",
    body: "Tu banco no autorizó la verificación. Vuelve a la app e intenta con otra tarjeta.",
  },
  cancelled: {
    icon: "↩️",
    color: "#B45309",
    title: "Registro cancelado",
    body: "No se registró ninguna tarjeta. Puedes intentarlo de nuevo desde la app.",
  },
  error: {
    icon: "⚠️",
    color: "#B91C1C",
    title: "No pudimos completar",
    body: "Ocurrió un problema procesando tu tarjeta. Vuelve a la app e inténtalo de nuevo.",
  },
};

function renderResultPage(result: string, reason: string): Response {
  const v = RESULT_VIEWS[result] ?? RESULT_VIEWS.error;
  const e = escapeHtmlAttr;
  const reasonLine = reason
    ? `<p class="reason">${e(decodeURIComponent(reason))}</p>`
    : "";
  // En éxito cerramos la pestaña sola (vuelve a la app). Funciona si fue abierta
  // por la app (window.open en web). Si el navegador lo bloquea, queda el botón;
  // en el navegador in-app de móvil el usuario toca "Listo".
  const autoClose = result === "approved"
    ? `<script>setTimeout(function(){try{window.close();}catch(e){}},1800);</script>`
    : "";
  const html = `<!DOCTYPE html>
<html lang="es"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${e(v.title)}</title>
<style>
  body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;
       background:#f5f5f7;color:#222;display:flex;align-items:center;
       justify-content:center;min-height:100vh;margin:0;padding:20px}
  .box{background:#fff;border-radius:16px;padding:36px 28px;max-width:420px;
       width:100%;box-shadow:0 2px 24px rgba(0,0,0,.06);text-align:center}
  .ico{font-size:52px;margin-bottom:10px}
  h1{margin:0 0 10px;font-size:21px;color:${v.color}}
  p{margin:0;font-size:14px;color:#666;line-height:1.55}
  .reason{margin-top:10px;font-size:12px;color:#999}
  button{margin-top:22px;background:#FF7A00;color:#fff;border:0;padding:13px 22px;
         border-radius:10px;font-size:15px;font-weight:700;cursor:pointer;width:100%}
  .hint{margin-top:12px;font-size:12px;color:#9aa0a6}
</style></head>
<body><div class="box">
  <div class="ico">${v.icon}</div>
  <h1>${e(v.title)}</h1>
  <p>${e(v.body)}</p>
  ${reasonLine}
  <button onclick="try{window.close();}catch(e){}">Volver a MangoPOS</button>
  <p class="hint">Si no se cierra sola, cierra esta ventana y vuelve a la app.</p>
</div>${autoClose}</body></html>`;
  return htmlResponse(html);
}
