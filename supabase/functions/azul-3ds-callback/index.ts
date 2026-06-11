// azul-3ds-callback — recibe los POST del servidor ACS del banco emisor.
//
// kind=method  (MethodNotificationUrl): POST server-side del ACS con
//   `threeDSMethodData` (base64 con threeDSServerTransID). Solo registramos
//   que llegó; el avance lo dispara la página con action=method-complete.
//
// kind=term    (TermUrl): POST del navegador tras el desafío, con `cres`.
//   Aquí completamos: ProcessThreeDSChallenge → autorización final → guardamos
//   la tarjeta y redirigimos al navegador de vuelta a azul-3ds-page.
//
// Público (autorizado por el sid). Ver PRD-Azul-3DSecure §6/§7.

import { corsPreflight, htmlResponse, redirect } from "../_shared/responses.ts";
import { getAzulEnv } from "../_shared/env.ts";
import { getServiceClient } from "../_shared/supabase.ts";
import { processThreeDSChallenge } from "../_shared/azul-api.ts";
import { classify3DSResponse, decodeThreeDSServerTransID } from "../_shared/azul-3ds.ts";
import { finalizeApprovedSession, logWebhookEvent } from "../_shared/azul-3ds-flow.ts";

function pageResultUrl(sid: string, result: "approved" | "declined" | "error"): string {
  const base = getAzulEnv().publicCallbackBaseUrl.replace(/\/+$/, "");
  return `${base}/azul-3ds-page?sid=${sid}&result=${result}`;
}

Deno.serve(async (req) => {
  const pre = corsPreflight(req);
  if (pre) return pre;

  const url = new URL(req.url);
  const kind = url.searchParams.get("kind");
  const sid = url.searchParams.get("sid");
  if (!sid || (kind !== "method" && kind !== "term")) {
    return htmlResponse("<h1>Solicitud inválida</h1>", 400);
  }

  // El ACS postea form-encoded.
  let form: FormData;
  try {
    form = await req.formData();
  } catch {
    form = new FormData();
  }

  const service = getServiceClient();

  // -------------------------------------------------------------------------
  // kind=method — notificación del MethodForm (server-side del ACS)
  // -------------------------------------------------------------------------
  if (kind === "method") {
    const threeDSMethodData = (form.get("threeDSMethodData") as string) ?? null;
    const serverTransId = decodeThreeDSServerTransID(threeDSMethodData);
    await service
      .from("azul_payment_sessions")
      .update({
        method_notification_received_at: new Date().toISOString(),
        ...(serverTransId ? { threeds_server_trans_id: serverTransId } : {}),
      })
      .eq("id", sid);
    await logWebhookEvent(service, {
      eventType: "threeds_method_notification",
      sessionId: sid,
      rawUrl: "azul-3ds-callback?kind=method",
      body: { threeDSServerTransID: serverTransId },
    });
    // Respuesta mínima: el ACS no espera contenido útil.
    return htmlResponse("<!doctype html><title>ok</title>", 200);
  }

  // -------------------------------------------------------------------------
  // kind=term — resultado del desafío (POST del navegador)
  // -------------------------------------------------------------------------
  const cres = (form.get("cres") as string) ?? "";
  const { data: session } = await service
    .from("azul_payment_sessions")
    .select("id, business_id, azul_order_id, resulting_payment_method_id, status")
    .eq("id", sid)
    .maybeSingle();

  if (!session) return htmlResponse("<h1>Sesión no encontrada</h1>", 404);

  await service
    .from("azul_payment_sessions")
    .update({ cres_received_at: new Date().toISOString() })
    .eq("id", sid);

  if (!cres || !session.azul_order_id) {
    await service
      .from("azul_payment_sessions")
      .update({ status: "declined", response_message: "Desafío sin cres/azul_order_id" })
      .eq("id", sid);
    return redirect(pageResultUrl(sid, "declined"));
  }

  let result;
  try {
    result = await processThreeDSChallenge({ azulOrderId: session.azul_order_id, cRes: cres });
  } catch (_e) {
    await service.from("azul_payment_sessions").update({ status: "error" }).eq("id", sid);
    return redirect(pageResultUrl(sid, "error"));
  }

  const azul = result.body;
  await logWebhookEvent(service, {
    eventType: "threeds_term_callback",
    sessionId: sid,
    rawUrl: "azul-3ds-callback?kind=term (ProcessThreeDSChallenge)",
    body: {
      IsoCode: azul.IsoCode ?? null,
      ResponseMessage: azul.ResponseMessage ?? null,
      AzulOrderId: azul.AzulOrderId ?? null,
    },
    processed: result.httpStatus === 200,
  });

  const next = classify3DSResponse(result.httpStatus, azul);
  if (next.kind === "approved") {
    const fin = await finalizeApprovedSession(service, session, azul);
    return redirect(pageResultUrl(sid, fin.ok ? "approved" : "error"));
  }

  await service
    .from("azul_payment_sessions")
    .update({
      status: "declined",
      iso_code: azul.IsoCode ?? null,
      response_message: azul.ResponseMessage ?? null,
      completed_at: new Date().toISOString(),
    })
    .eq("id", sid);
  return redirect(pageResultUrl(sid, "declined"));
});
