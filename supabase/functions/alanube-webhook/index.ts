// alanube-webhook
// Receptor publico de webhooks de Alanube. Validacion via header X-Webhook-Secret.

import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL");
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
const WEBHOOK_SECRET = Deno.env.get("ALANUBE_WEBHOOK_SECRET");

if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
  throw new Error("SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY required");
}
if (!WEBHOOK_SECRET) {
  throw new Error("ALANUBE_WEBHOOK_SECRET required");
}

interface WebhookPayload {
  event?: string;
  eventType?: string;
  data?: Record<string, unknown>;
  message?: string;
  documentId?: string;
  id?: string;
  status?: string;
  trackId?: string;
  publicUrl?: string;
  xmlUrl?: string;
  pdfUrl?: string;
  signedAt?: string;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return json({ error: "method_not_allowed" }, 405);
  }

  const startedAt = Date.now();

  const text = await req.text();
  let body: WebhookPayload;
  try {
    body = JSON.parse(text);
  } catch {
    console.error("invalid JSON in webhook body:", text.slice(0, 500));
    return json({ error: "invalid_json" }, 400);
  }

  if (body.message === "Test message") {
    console.log("Alanube webhook handshake received");
    return json({ ok: true, ack: "test" }, 200);
  }

  const providedSecret = req.headers.get("x-webhook-secret") ?? "";
  if (providedSecret !== WEBHOOK_SECRET) {
    console.error("webhook auth failed: invalid X-Webhook-Secret");
    return json({ error: "unauthorized" }, 401);
  }

  const headersObj: Record<string, string> = {};
  req.headers.forEach((value, key) => {
    const k = key.toLowerCase();
    if (k !== "authorization" && k !== "x-webhook-secret" && k !== "cookie") {
      headersObj[k] = value;
    }
  });

  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const eventType = body.event ?? body.eventType ?? "unknown";

  const { data: inboxRow, error: inboxErr } = await supabase
    .from("alanube_webhook_inbox")
    .insert({
      event_type: eventType,
      payload: body,
      headers: headersObj,
      signature_valid: true,
    })
    .select("id")
    .single();

  if (inboxErr || !inboxRow) {
    console.error("inbox insert failed:", inboxErr);
    return json({ error: "inbox_failed", detail: inboxErr?.message }, 500);
  }

  let processError: string | null = null;
  try {
    await processWebhook(supabase, eventType, body);
  } catch (e) {
    processError = e instanceof Error ? e.message : String(e);
    console.error(`processWebhook failed for inbox ${inboxRow.id}:`, e);
  }

  await supabase
    .from("alanube_webhook_inbox")
    .update({
      processed: !processError,
      processed_at: new Date().toISOString(),
      error: processError?.slice(0, 2000) ?? null,
    })
    .eq("id", inboxRow.id);

  return json({
    ok: !processError,
    inbox_id: inboxRow.id,
    event_type: eventType,
    processed: !processError,
    error: processError,
    duration_ms: Date.now() - startedAt,
  }, 200);
});

async function processWebhook(
  supabase: SupabaseClient,
  eventType: string,
  body: WebhookPayload,
) {
  // Shape REAL de Alanube DOM (verificado 2026-05-06): payload flat sin wrapper
  // event/data. Trae directamente:
  //   id (alanube_document_id), legalStatus, securityCode, signatureDate,
  //   documentStampUrl, documentNumber, governmentResponse, status, type
  // No hay campo `event` — Alanube manda webhook unico por documento.
  // Por eso eventType viene como 'unknown' y antes saltabamos por la guarda.
  const data = (body.data ?? body) as Record<string, unknown>;

  const alanubeDocId = (
    data.id ?? data.documentId ?? data.alanubeDocumentId ?? data.alanube_document_id
  ) as string | undefined;

  // Si no hay id, no es un webhook de documento — log y skip sin error.
  if (!alanubeDocId || typeof alanubeDocId !== "string") {
    console.log(
      `webhook sin id de documento, skip: ${JSON.stringify(data).slice(0, 200)}`,
    );
    return;
  }

  const { data: docRow, error: docErr } = await supabase
    .from("fiscal_documents")
    .select("id, ecf_status")
    .eq("alanube_document_id", alanubeDocId)
    .maybeSingle();

  if (docErr) throw new Error(`db error finding doc: ${docErr.message}`);
  if (!docRow) {
    console.log(
      `fiscal_document no encontrado para alanube_id=${alanubeDocId} — posible doc creado en otro entorno`,
    );
    return;
  }

  // Status DGII: legalStatus es la verdad final (ACCEPTED/REJECTED/IN_PROCESS).
  // status del payload (FINISHED/IN_PROGRESS) es del workflow Alanube interno.
  const rawLegalStatus = (data.legalStatus ?? data.status ?? data.documentStatus ?? "") as string;
  const newStatus = mapAlanubeStatus(rawLegalStatus);
  const previousStatus = docRow.ecf_status as string;

  if (!isForwardTransition(previousStatus, newStatus)) {
    console.log(
      `skipping backward transition for doc ${docRow.id}: ${previousStatus} -> ${newStatus}`,
    );
    return;
  }

  const updates: Record<string, unknown> = {
    ecf_status: newStatus,
    last_error: null,
  };

  // URLs (Alanube usa documentStampUrl para la URL pública DGII verificable).
  if (typeof data.documentStampUrl === "string") {
    updates.public_url = data.documentStampUrl;
  } else if (typeof data.publicUrl === "string") {
    updates.public_url = data.publicUrl;
  }
  if (typeof data.xmlUrl === "string") updates.xml_url = data.xmlUrl;
  if (typeof data.pdfUrl === "string") updates.pdf_url = data.pdfUrl;

  // Track ID DGII (puede venir null en sandbox).
  if (typeof data.trackId === "string") updates.ecf_tracking_number = data.trackId;
  if (typeof data.dgiiTrackId === "string") updates.ecf_tracking_number = data.dgiiTrackId;

  // Codigo de Seguridad y Fecha de Firma Digital (datos visibles en el QR/ticket).
  if (typeof data.securityCode === "string") updates.ecf_security_code = data.securityCode;

  // signatureDate viene como "DD-MM-YYYY HH:MM:SS" — parseamos a ISO para
  // que TIMESTAMPTZ de Postgres lo acepte. Si falla, dejamos como null.
  const signedRaw = (data.signatureDate ?? data.signedAt) as string | undefined;
  if (typeof signedRaw === "string" && signedRaw.length > 0) {
    const iso = parseAlanubeDateToIso(signedRaw);
    if (iso !== null) updates.ecf_signed_at = iso;
  }

  if (newStatus === "accepted") {
    updates.accepted_at =
      (updates.ecf_signed_at as string | undefined) ??
        new Date().toISOString();

    // "Aceptado con observaciones": el comprobante ES valido, pero la DGII
    // senala algo mal armado. Si no se guarda, la observacion solo se ve
    // entrando al portal de Alanube — y un negocio puede pasar meses
    // emitiendo con el mismo defecto sin enterarse. Se deja en last_error
    // para que quede a la vista, marcado como observacion y no como fallo.
    if (rawLegalStatus.toUpperCase().includes("OBSERVA")) {
      const detalle = extractRejectionReason(data);
      updates.last_error = detalle !== null
        ? `[Aceptado con observaciones] ${detalle}`
        : `[Aceptado con observaciones] ${rawLegalStatus}`;
    }
  }
  if (newStatus === "rejected") {
    updates.last_error = extractRejectionReason(data) ?? `DGII rejected: ${rawLegalStatus}`;
  }

  const { error: updErr } = await supabase
    .from("fiscal_documents")
    .update(updates)
    .eq("id", docRow.id);

  if (updErr) throw new Error(`update fiscal_documents failed: ${updErr.message}`);

  await supabase.from("fiscal_document_status_events").insert({
    fiscal_document_id: docRow.id,
    previous_status: previousStatus,
    new_status: newStatus,
    source: "webhook",
    note:
      `Alanube webhook legalStatus=${rawLegalStatus}; ` +
      `securityCode=${data.securityCode ?? "n/a"}; ` +
      `eventType=${eventType}`,
  });

  console.log(
    `webhook updated doc ${docRow.id}: ${previousStatus} -> ${newStatus} (alanube_id=${alanubeDocId}, legalStatus=${rawLegalStatus})`,
  );
}

/// Extrae la razon de rechazo del governmentResponse de DGII.
/// Shape: { code: 2, value: [ { codigo: "04", valor: "El RNC..." } ] }
function extractRejectionReason(data: Record<string, unknown>): string | null {
  const gr = data.governmentResponse as Record<string, unknown> | undefined;
  if (gr === undefined || gr === null) return null;
  const value = gr.value;
  if (Array.isArray(value) && value.length > 0) {
    const first = value[0] as Record<string, unknown>;
    const valor = first.valor as string | undefined;
    const codigo = first.codigo as string | undefined;
    if (valor !== undefined) {
      return codigo !== undefined ? `[${codigo}] ${valor}` : valor;
    }
  }
  return null;
}

/// Convierte "DD-MM-YYYY HH:MM:SS" (formato Alanube) a ISO 8601.
/// Devuelve null si el formato no calza.
function parseAlanubeDateToIso(raw: string): string | null {
  // "06-05-2026 14:20:38"
  const match = raw.match(
    /^(\d{2})-(\d{2})-(\d{4})\s+(\d{2}):(\d{2}):(\d{2})$/,
  );
  if (match === null) {
    // Si ya es ISO, devolverlo.
    if (raw.includes("T") && raw.includes("-")) return raw;
    return null;
  }
  const [, dd, mm, yyyy, hh, mi, ss] = match;
  // Asumimos hora local Dominicana (AST = UTC-4). En lugar de hacer math
  // manual, dejamos el offset explicito en el ISO.
  return `${yyyy}-${mm}-${dd}T${hh}:${mi}:${ss}-04:00`;
}

function mapAlanubeStatus(raw: string): "pending" | "sent" | "accepted" | "rejected" {
  if (!raw) return "sent";
  const s = raw.toLowerCase();
  // Alanube DOM legalStatus: ACCEPTED, REJECTED, IN_PROCESS
  if (s === "accepted" || s.includes("accept") || s.includes("aprob")) {
    return "accepted";
  }
  if (s === "rejected" || s.includes("reject") || s.includes("rechaz")) {
    return "rejected";
  }
  if (s === "in_process" || s === "in_progress" ||
      s.includes("pending") || s.includes("pendient") ||
      s.includes("process")) {
    return "sent";
  }
  // 'finished' no es status final; depende de legalStatus que ya manejamos arriba.
  if (s === "finished") return "sent";
  return "sent";
}

function isForwardTransition(prev: string, next: string): boolean {
  const order: Record<string, number> = {
    pending: 0,
    sent: 1,
    accepted: 2,
    rejected: 2,
  };
  const prevRank = order[prev] ?? -1;
  const nextRank = order[next] ?? -1;
  return nextRank >= prevRank;
}

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body, null, 2), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  });
}
