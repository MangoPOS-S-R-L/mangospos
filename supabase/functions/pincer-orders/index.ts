// pincer-orders — recepcion de pedidos de canales externos.
//
//   POST /pincer-orders                      → ingiere un pedido ya aceptado
//   GET  /pincer-orders/{external_order_id}  → estado del pedido en el POS
//   POST /pincer-orders/{id}/cancel          → anulacion (F1d, todavia no)
//
// Ver docs/PRD_INTEGRACION_PINCER.md §5.
//
// El pedido llega YA ACEPTADO por la cajera en la tablet de Pincer (§3.1), asi
// que aca no hay decision que tomar: entra, va a cocina y se registra el cobro.
//
// TODO lo que llega se guarda en `external_order_inbox` ANTES de ingerirse,
// incluso si la firma es invalida o la ingesta revienta. Si un pedido se pierde,
// tiene que quedar rastro de por que.

import {
  corsPreflight,
  errorResponse,
  jsonResponse,
} from "../_shared/responses.ts";
import {
  authenticateChannel,
  type ChannelCredential,
  checkRateLimit,
  serviceClient,
} from "../_shared/external-channel-auth.ts";

/** Traduce el error de la RPC al HTTP que Pincer sabe interpretar (§5.7). */
function mapIngestError(message: string): { status: number; code: string } {
  if (message.includes("EXT_UNKNOWN_MENU_ITEM")) {
    return { status: 422, code: "unknown_menu_item" };
  }
  if (message.includes("EXT_INVALID_PAYLOAD")) {
    return { status: 422, code: "invalid_payload" };
  }
  if (message.includes("EXT_NO_USER")) {
    return { status: 500, code: "internal_error" };
  }
  return { status: 500, code: "internal_error" };
}

async function logToInbox(
  credential: ChannelCredential | null,
  externalOrderId: string | null,
  payload: unknown,
  req: Request,
  signatureValid: boolean,
  httpStatus: number,
  processed: boolean,
  error: string | null,
): Promise<void> {
  try {
    await serviceClient().from("external_order_inbox").insert({
      business_id: credential?.businessId ?? null,
      channel: credential?.channel ?? "pincer",
      external_order_id: externalOrderId,
      payload: payload ?? {},
      headers: {
        "user-agent": req.headers.get("user-agent"),
        "content-type": req.headers.get("content-type"),
        "x-api-key-prefix": req.headers.get("x-api-key")?.slice(0, 8) ?? null,
      },
      signature_valid: signatureValid,
      http_status: httpStatus,
      processed,
      error,
    });
  } catch (e) {
    // El inbox es auditoria: si falla, no se tumba la respuesta al canal.
    console.error("inbox insert fallo:", e instanceof Error ? e.message : e);
  }
}

async function handleIngest(req: Request, rawBody: string): Promise<Response> {
  let payload: Record<string, unknown>;
  try {
    payload = JSON.parse(rawBody);
  } catch {
    await logToInbox(null, null, { raw: rawBody.slice(0, 2000) }, req, false, 422, false, "json invalido");
    return errorResponse(422, "invalid_payload", "El cuerpo no es JSON valido");
  }

  const externalOrderId = typeof payload.external_order_id === "string"
    ? payload.external_order_id
    : null;

  const auth = await authenticateChannel(req, rawBody, "orders:write");
  if (!auth.ok) {
    await logToInbox(
      null,
      externalOrderId,
      payload,
      req,
      auth.failure.code !== "invalid_signature" && auth.failure.code !== "stale_timestamp",
      auth.failure.status,
      false,
      auth.message,
    );
    return errorResponse(auth.failure.status, auth.failure.code, auth.message);
  }

  const { credential } = auth;

  const rate = await checkRateLimit(credential);
  if (!rate.allowed) {
    await logToInbox(credential, externalOrderId, payload, req, true, 429, false, "rate limit");
    return errorResponse(
      429,
      "rate_limited",
      `Maximo ${credential.rateLimitRpm} llamadas por minuto`,
      undefined,
    );
  }

  const db = serviceClient();
  const { data, error } = await db.rpc("fn_ingest_external_order", {
    p_business_id: credential.businessId,
    p_channel: credential.channel,
    p_payload: payload,
    p_environment: credential.environment,
  });

  if (error) {
    const mapped = mapIngestError(error.message ?? "");
    console.error("ingesta fallo:", error.message);
    await logToInbox(credential, externalOrderId, payload, req, true, mapped.status, false, error.message);
    return errorResponse(mapped.status, mapped.code, error.message);
  }

  const result = data as Record<string, unknown>;
  const duplicate = result.duplicate === true;
  const status = duplicate ? 200 : 201;

  await logToInbox(credential, externalOrderId, payload, req, true, status, true, null);

  return jsonResponse({
    order_id: result.order_id,
    order_number: result.order_number,
    external_number: result.external_number,
    status: result.status ?? "accepted",
    duplicate,
    // "encolada para imprimir", NO "salio el papel": la impresora depende de la
    // red del local y eso se resuelve en el POS, no reintentando desde Pincer.
    queued_for_print: true,
    kds: true,
    items: result.items,
    pos_total: result.pos_total,
    tip_amount: result.tip_amount,
    payment_state: result.payment_state,
    needs_review: result.needs_review,
    environment: result.environment,
  }, { status });
}

async function handleStatus(req: Request, externalOrderId: string): Promise<Response> {
  const auth = await authenticateChannel(req, "", "catalog:read");
  if (!auth.ok) {
    return errorResponse(auth.failure.status, auth.failure.code, auth.message);
  }

  const db = serviceClient();
  const { data, error } = await db
    .from("external_orders")
    .select(
      "external_order_id, external_number, order_id, service_type, payment_state, " +
        "cancel_state, external_total, tip_amount, needs_review, environment, created_at, " +
        "orders(status, status_ext, total, kitchen_done_at, closed_at)",
    )
    .eq("business_id", auth.credential.businessId)
    .eq("external_order_id", externalOrderId)
    .maybeSingle();

  if (error) {
    console.error("consulta de estado fallo:", error.message);
    return errorResponse(500, "internal_error", "No se pudo leer el pedido");
  }
  if (!data) {
    return errorResponse(404, "unknown_order", "Ese pedido no existe en el POS");
  }

  // El select con relacion anidada no se infiere solo; lo tipamos aca.
  const row = data as unknown as Record<string, unknown>;
  const order = (row.orders ?? null) as Record<string, unknown> | null;

  // Estado que le sirve a Pincer, no el interno del POS.
  let state = "accepted";
  if (row.cancel_state && row.cancel_state !== "none") state = "cancelled";
  else if (order?.kitchen_done_at) state = "ready";
  else if (order?.status === "sent") state = "preparing";

  return jsonResponse({
    external_order_id: row.external_order_id,
    external_number: row.external_number,
    order_id: row.order_id,
    state,
    payment_state: row.payment_state,
    pos_total: order?.total ?? null,
    tip_amount: row.tip_amount,
    needs_review: row.needs_review,
    environment: row.environment,
    created_at: row.created_at,
  });
}

Deno.serve(async (req) => {
  const preflight = corsPreflight(req);
  if (preflight) return preflight;

  // /functions/v1/pincer-orders/{id}[/cancel]
  const path = new URL(req.url).pathname
    .replace(/^\/functions\/v1/, "")
    .replace(/^\/pincer-orders\/?/, "")
    .replace(/\/+$/, "");
  const segments = path.length > 0 ? path.split("/") : [];

  try {
    if (req.method === "POST" && segments.length === 0) {
      return await handleIngest(req, await req.text());
    }

    if (req.method === "GET" && segments.length === 1) {
      return await handleStatus(req, decodeURIComponent(segments[0]));
    }

    if (req.method === "POST" && segments.length === 2 && segments[1] === "cancel") {
      // F1d. Cancelar aca no es un "cancel" liviano: la orden ya esta cobrada y
      // casi siempre con comprobante emitido, asi que exige nota de credito.
      // Devolvemos 501 explicito para que Pincer pueda integrar la ruta desde ya
      // sin creer que la anulacion quedo hecha.
      return errorResponse(
        501,
        "not_implemented",
        "La cancelacion todavia no esta disponible. Por ahora se anula en el POS, " +
          "con nota de credito. Avisaremos cuando el endpoint quede activo.",
      );
    }

    return errorResponse(405, "method_not_allowed", `${req.method} ${path} no existe`);
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("pincer-orders excepcion:", message);
    return errorResponse(500, "internal_error", "Error interno del POS");
  }
});
