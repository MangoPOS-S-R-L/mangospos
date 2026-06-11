// PRD §7.2 — azul-payment-form
//
// GET /functions/v1/azul-payment-form?session_id=<uuid>
//
// Sirve el HTML auto-submit que postea al Payment Page de Azul.
//   - Sin auth: público por diseño. La seguridad la da el session_id (UUID v4
//     con suficiente entropía) y expires_at (30 min default).
//   - Cualquier sesión que no sea status=pending devuelve 410 Gone.
//   - Al servir, marca status=redirected (PRD §7.2 paso 2). Esto significa
//     que la sesión solo puede consumirse una vez por su URL.

import {
  corsPreflight,
  escapeHtmlAttr,
  htmlResponse,
} from "../_shared/responses.ts";
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

  if (req.method !== "GET") {
    return htmlResponse(errorPage("Método no permitido"), 405);
  }

  const url = new URL(req.url);
  const sessionId = url.searchParams.get("session_id");
  if (!sessionId) {
    return htmlResponse(errorPage("Falta session_id"), 400);
  }

  const env = getAzulEnv();
  const authKey = env.azulAuthKey;
  const paymentPageUrl = env.azulPaymentPageUrl;
  if (!authKey || !paymentPageUrl) {
    return htmlResponse(
      errorPage("Configuración de pago incompleta en el servidor."),
      500,
    );
  }
  const service = getServiceClient();

  const { data: session, error } = await service
    .from("azul_payment_sessions")
    .select("id, business_id, intent_type, order_number, amount_cents, status, expires_at, auth_hash_sent")
    .eq("id", sessionId)
    .maybeSingle();

  if (error) {
    console.error("[azul-payment-form] db error", error);
    return htmlResponse(errorPage("Error al cargar la sesión"), 500);
  }
  if (!session) {
    return htmlResponse(errorPage("Sesión no encontrada"), 404);
  }
  if (session.status !== "pending") {
    // Ventana reabierta/vuelta-atrás: ya se sirvió o ya se procesó. No es un
    // error — solo está vieja. Mensaje calmado + auto-cierre.
    return htmlResponse(
      stalePage(
        "Ya completaste o cerraste este registro. Vuelve a la app de MangoPOS "
          + "para ver tu tarjeta o intentar de nuevo.",
      ),
      410,
    );
  }
  if (new Date(session.expires_at) <= new Date()) {
    // Marca expirada para que no se reuse.
    await service
      .from("azul_payment_sessions")
      .update({ status: "timeout", updated_at: new Date().toISOString() })
      .eq("id", session.id);
    return htmlResponse(
      stalePage("La sesión expiró. Vuelve a la app e intenta de nuevo."),
      410,
    );
  }

  // Reconstruir los mismos campos para que el AuthHash coincida byte-exacto.
  // (No reutilizamos el almacenado; lo recalculamos y validamos que coincida —
  // defensa contra corrupción/manipulación silenciosa de la fila.)
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

  const recomputedHash = await computeAuthHash(
    paymentPageFieldsToOrdered(fields),
    authKey,
  );
  if (recomputedHash !== session.auth_hash_sent) {
    console.error("[azul-payment-form] auth_hash mismatch — session may be corrupted", {
      sessionId: session.id,
    });
    await service
      .from("azul_payment_sessions")
      .update({ status: "error", updated_at: new Date().toISOString() })
      .eq("id", session.id);
    return htmlResponse(errorPage("Sesión inválida"), 500);
  }

  // Marcar redirected ANTES de servir el HTML (PRD §7.2 paso 2).
  const { error: upErr } = await service
    .from("azul_payment_sessions")
    .update({
      status: "redirected",
      redirected_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    })
    .eq("id", session.id)
    .eq("status", "pending"); // optimistic: solo si sigue pending
  if (upErr) {
    return htmlResponse(errorPage("No se pudo iniciar la sesión"), 500);
  }

  return htmlResponse(renderForm(paymentPageUrl, fields, recomputedHash));
});

function renderForm(
  action: string,
  f: {
    merchantId: string;
    merchantName: string;
    merchantType: string;
    currencyCode: string;
    orderNumber: string;
    amount: string;
    itbis: string;
    approvedUrl: string;
    declinedUrl: string;
    cancelUrl: string;
    useCustomField1: string;
    customField1Label: string;
    customField1Value: string;
    useCustomField2: string;
    customField2Label: string;
    customField2Value: string;
  },
  authHash: string,
): string {
  const e = escapeHtmlAttr;
  return `<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Redirigiendo a Azul…</title>
  <style>
    body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;
         background:#f5f5f7;color:#333;display:flex;align-items:center;
         justify-content:center;height:100vh;margin:0;padding:20px;text-align:center}
    .box{background:#fff;border-radius:12px;padding:32px;max-width:420px;
         box-shadow:0 2px 20px rgba(0,0,0,.05)}
    h1{margin:0 0 12px;font-size:18px;color:#1a1a1a}
    p{margin:0 0 16px;font-size:14px;line-height:1.5;color:#666}
    .spinner{width:32px;height:32px;border:3px solid #eee;border-top-color:#FF7A00;
             border-radius:50%;margin:0 auto 16px;animation:spin 1s linear infinite}
    @keyframes spin{to{transform:rotate(360deg)}}
    button{background:#FF7A00;color:#fff;border:0;padding:12px 24px;
           border-radius:8px;font-size:14px;cursor:pointer;margin-top:8px}
  </style>
</head>
<body onload="document.forms[0].submit()">
  <div class="box">
    <div class="spinner"></div>
    <h1>Redirigiendo a la pasarela segura…</h1>
    <p>Estamos llevándote a Azul para validar tu tarjeta. No cierres esta ventana.</p>
    <form action="${e(action)}" method="post">
      <input type="hidden" name="MerchantId" value="${e(f.merchantId)}">
      <input type="hidden" name="MerchantName" value="${e(f.merchantName)}">
      <input type="hidden" name="MerchantType" value="${e(f.merchantType)}">
      <input type="hidden" name="TrxType" value="Hold">
      <input type="hidden" name="CurrencyCode" value="${e(f.currencyCode)}">
      <input type="hidden" name="OrderNumber" value="${e(f.orderNumber)}">
      <input type="hidden" name="Amount" value="${e(f.amount)}">
      <input type="hidden" name="ITBIS" value="${e(f.itbis)}">
      <input type="hidden" name="ApprovedUrl" value="${e(f.approvedUrl)}">
      <input type="hidden" name="DeclinedUrl" value="${e(f.declinedUrl)}">
      <input type="hidden" name="CancelUrl" value="${e(f.cancelUrl)}">
      <input type="hidden" name="UseCustomField1" value="${e(f.useCustomField1)}">
      <input type="hidden" name="CustomField1Label" value="${e(f.customField1Label)}">
      <input type="hidden" name="CustomField1Value" value="${e(f.customField1Value)}">
      <input type="hidden" name="UseCustomField2" value="${e(f.useCustomField2)}">
      <input type="hidden" name="CustomField2Label" value="${e(f.customField2Label)}">
      <input type="hidden" name="CustomField2Value" value="${e(f.customField2Value)}">
      <input type="hidden" name="SaveToDataVault" value="1">
      <input type="hidden" name="AuthHash" value="${e(authHash)}">
      <noscript><button type="submit">Continuar</button></noscript>
    </form>
  </div>
</body>
</html>`;
}

function noticePage(
  opts: { title: string; message: string; color: string; autoClose: boolean },
): string {
  const e = escapeHtmlAttr;
  const auto = opts.autoClose
    ? `<script>setTimeout(function(){try{window.close();}catch(e){}},2200);</script>`
    : "";
  return `<!DOCTYPE html>
<html lang="es"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${e(opts.title)}</title>
<style>body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;
background:#f5f5f7;color:#222;display:flex;align-items:center;justify-content:center;
min-height:100vh;margin:0;padding:20px}
.box{background:#fff;border-radius:16px;padding:36px 28px;max-width:420px;width:100%;
box-shadow:0 2px 24px rgba(0,0,0,.06);text-align:center}
h1{margin:0 0 10px;font-size:20px;color:${opts.color}}
p{margin:0;font-size:14px;color:#666;line-height:1.55}
button{margin-top:22px;background:#FF7A00;color:#fff;border:0;padding:13px 22px;
border-radius:10px;font-size:15px;font-weight:700;cursor:pointer;width:100%}
.hint{margin-top:12px;font-size:12px;color:#9aa0a6}</style></head>
<body><div class="box"><h1>${e(opts.title)}</h1><p>${e(opts.message)}</p>
<button onclick="try{window.close();}catch(e){}">Volver a MangoPOS</button>
<p class="hint">Si no se cierra sola, cierra esta ventana y vuelve a la app.</p>
</div>${auto}</body></html>`;
}

/** Ventana ya consumida o expirada: el registro ya pasó o ya no aplica. Calma + auto-cierre. */
function stalePage(message: string): string {
  return noticePage({
    title: "Esta ventana ya no está activa",
    message,
    color: "#B45309",
    autoClose: true,
  });
}

/** Error genuino (no se autocierra, para que el usuario lo lea). */
function errorPage(message: string): string {
  return noticePage({
    title: "No pudimos continuar",
    message,
    color: "#B91C1C",
    autoClose: false,
  });
}
