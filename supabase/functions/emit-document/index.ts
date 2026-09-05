// emit-document: procesa alanube_emit_outbox.
// Disparado por cron (cada 60s) o manualmente por curl.
// Cada invocación procesa hasta BATCH_SIZE docs pendientes.

import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import { createAlanubeClient, AlanubeClient, AlanubeError } from "../_shared/alanube-client.ts";
import { EcfTaxLine, summarizeEcfTaxLines } from "../_shared/ecf-tax-lines.ts";
import {
  buildAlanubePayload,
  EcfTaxBreakdown,
  FiscalDocument,
  isCreditNoteType,
  ModifiedDocumentRef,
  OrderItem,
  Sender,
} from "../_shared/ecf-payload.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL");
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
  throw new Error("SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY required");
}

const BATCH_SIZE = 10;
const MAX_ATTEMPTS = 5;
const BACKOFF_MINUTES = [1, 5, 15, 60, 240];

interface OutboxRow {
  id: string;
  fiscal_document_id: string;
  business_id: string;
  settings_id: string;
  attempts: number;
}

interface Settings {
  alanube_company_id: string;
  environment: string;
  mode: string;
}

function getEndpointForNcfType(ncfType: string): string | null {
  switch (ncfType) {
    case "E31": return "/fiscal-invoices";
    case "E32": return "/invoices";
    case "E44": return "/special-regimes";
    case "E45": return "/gubernamentals";
    // Nota de credito: es como se anula un e-CF que la DGII ya acepto.
    case "E34": return "/credit-notes";
    default: return null;
  }
}

interface AlanubeSubmitResponse {
  id?: string;
  trackId?: string;
  securityCode?: string;
  signedAt?: string;
  status?: string;
  publicUrl?: string;
  xmlUrl?: string;
  pdfUrl?: string;
}

function nextAttemptAt(attemptsAfterIncrement: number): string {
  const idx = Math.min(attemptsAfterIncrement - 1, BACKOFF_MINUTES.length - 1);
  const minutes = BACKOFF_MINUTES[Math.max(0, idx)];
  return new Date(Date.now() + minutes * 60_000).toISOString();
}


async function computeEcfBreakdown(
  supabase: SupabaseClient,
  orderId: string | null,
  items: OrderItem[],
): Promise<EcfTaxBreakdown | null> {
  if (!orderId) return null;

  const itemIds = items.map((it) => it.id).filter(Boolean);
  if (itemIds.length === 0) return null;

  // `name` y `rate` se traen para el fallback por nombre de la Ley 10% en los
  // negocios que todavia no apagaron "Incluir en e-CF DGII" en ese impuesto.
  const { data, error } = await supabase
    .from("order_item_tax_lines")
    .select("order_item_id, tax_rate, amount, taxes(include_in_ecf, name, rate)")
    .in("order_item_id", itemIds);

  if (error) {
    console.error("computeEcfBreakdown: failed to load tax_lines:", error);
    return null;
  }

  return summarizeEcfTaxLines(items, (data ?? []) as EcfTaxLine[]);
}

async function claimBatch(supabase: SupabaseClient): Promise<OutboxRow[]> {
  const now = new Date().toISOString();

  const { data: candidates, error } = await supabase
    .from("alanube_emit_outbox")
    .select("id, fiscal_document_id, business_id, settings_id, attempts")
    .eq("status", "pending")
    .lte("next_attempt_at", now)
    .order("created_at", { ascending: true })
    .limit(BATCH_SIZE);

  if (error) {
    console.error("claim select failed:", error);
    return [];
  }

  const claimed: OutboxRow[] = [];
  for (const c of candidates ?? []) {
    const { data: row, error: updErr } = await supabase
      .from("alanube_emit_outbox")
      .update({
        status: "processing",
        attempts: c.attempts + 1,
        last_attempt_at: now,
      })
      .eq("id", c.id)
      .eq("status", "pending")
      .select("id, fiscal_document_id, business_id, settings_id, attempts")
      .maybeSingle();

    if (updErr) {
      console.error(`claim update failed for ${c.id}:`, updErr);
      continue;
    }
    if (row) claimed.push(row as OutboxRow);
  }

  return claimed;
}

/**
 * Fecha de vencimiento de la secuencia e-NCF, como la autorizo la DGII.
 *
 * La DGII valida `FechaVencimientoSecuencia` contra la autorizacion del rango:
 * si no es la de la autorizacion devuelve el codigo 145 ("Fecha de vencimiento
 * de secuencia invalida") y RECHAZA el comprobante. Por eso sale de
 * `ncf_sequences.expiration_date` y nunca se calcula.
 *
 * Un negocio puede tener varias filas del mismo tipo (varias autorizaciones);
 * se elige la que cubre el numero de este e-NCF, y si ninguna lo cubre, la
 * activa.
 */
async function loadSequenceDueDate(
  supabase: SupabaseClient,
  businessId: string,
  doc: FiscalDocument,
): Promise<string | null> {
  const { data, error } = await supabase
    .from("ncf_sequences")
    .select("ncf_type, range_start, range_end, expiration_date, is_active")
    .eq("business_id", businessId)
    .eq("ncf_type", doc.ncf_type);

  if (error) {
    console.error(`load ncf_sequences failed for ${businessId}/${doc.ncf_type}:`, error);
    return null;
  }
  const rows = (data ?? []) as Array<{
    range_start: number;
    range_end: number;
    expiration_date: string | null;
    is_active: boolean | null;
  }>;
  if (rows.length === 0) return null;

  const digits = /(\d+)$/.exec(doc.ncf_number ?? "");
  const seq = digits ? Number(digits[1]) : NaN;
  const covering = Number.isFinite(seq)
    ? rows.find((r) => Number(r.range_start) <= seq && seq <= Number(r.range_end))
    : undefined;
  const row = covering ?? rows.find((r) => r.is_active === true) ?? rows[0];
  const raw = row.expiration_date;
  return raw ? String(raw).slice(0, 10) : null;
}

async function loadContext(
  supabase: SupabaseClient,
  outbox: OutboxRow,
): Promise<
  {
    doc: FiscalDocument;
    settings: Settings;
    sender: Sender;
    items: OrderItem[];
    modifiedDoc: ModifiedDocumentRef | null;
  } | null
> {
  const [docRes, settingsRes, fiscalSettingsRes, businessRes] = await Promise.all([
    supabase
      .from("fiscal_documents")
      .select(
        // OJO: aqui NO van las columnas de la nota de credito
        // (modification_code/modification_reason). Son nuevas, y pedirlas en
        // este select haria que PostgREST tumbe la emision de TODAS las
        // facturas si la funcion se despliega antes que su migracion. Se leen
        // aparte, solo cuando el documento es una nota.
        "id, business_id, order_id, ncf_type, ncf_number, customer_rnc, customer_name, customer_address, subtotal, discount, tax_exempt, taxable_amount, itbis_amount, service_fee, tip, total, is_electronic, alanube_document_id, issued_at, idempotency_key, related_document_id",
      )
      .eq("id", outbox.fiscal_document_id)
      .single(),
    supabase
      .from("business_alanube_settings")
      .select("alanube_company_id, environment, mode")
      .eq("id", outbox.settings_id)
      .single(),
    supabase
      .from("fiscal_settings")
      .select("rnc, business_legal_name")
      .eq("business_id", outbox.business_id)
      .maybeSingle(),
    supabase
      .from("businesses")
      .select("business_name, branch_name, address")
      .eq("id", outbox.business_id)
      .single(),
  ]);

  if (docRes.error || !docRes.data) {
    console.error("load fiscal_document failed:", docRes.error);
    return null;
  }
  if (settingsRes.error || !settingsRes.data) {
    console.error("load settings failed:", settingsRes.error);
    return null;
  }
  if (businessRes.error || !businessRes.data) {
    console.error("load business failed:", businessRes.error);
    return null;
  }

  const fs = fiscalSettingsRes.data as { rnc: string; business_legal_name: string } | null;
  const biz = businessRes.data as { business_name: string; branch_name: string | null; address: string | null };

  if (!fs || !fs.rnc) {
    console.error(`fiscal_settings missing rnc for business ${outbox.business_id}`);
    return null;
  }
  if (!biz.address) {
    console.error(`businesses.address missing for ${outbox.business_id}`);
    return null;
  }

  const sender: Sender = {
    rnc: fs.rnc,
    companyName: fs.business_legal_name || biz.business_name,
    tradename: biz.business_name,
    address: biz.address,
    branchOffice: biz.branch_name ?? undefined,
  };

  const doc = docRes.data as FiscalDocument;

  let items: OrderItem[] = [];
  if (doc.order_id) {
    let query = supabase
      .from("order_items")
      .select(
        "id, product_id, product_name, sku, quantity, unit_price, tax_rate, tax, subtotal, discounts",
      )
      .eq("order_id", doc.order_id);

    // Un item anulado no se vendio: declararlo a DGII es sobre-facturar.
    // EXCEPCION: la nota de credito. Anular la venta es justo lo que puso los
    // items en 'void', asi que ese filtro dejaria la nota sin una sola linea
    // (Alanube exige entre 1 y 1000). La nota declara lo mismo que declaro el
    // comprobante que anula.
    if (!isCreditNoteType(doc.ncf_type)) {
      query = query.neq("status", "void");
    }

    const { data: itemRows, error: itemsErr } = await query;

    if (itemsErr) {
      console.error("load order_items failed:", itemsErr);
      return null;
    }
    items = (itemRows ?? []) as OrderItem[];
  }

  // Datos propios de la nota de credito, en su propia consulta por la razon
  // de arriba: una factura normal ni los pide.
  if (isCreditNoteType(doc.ncf_type)) {
    const { data: noteRow, error: noteErr } = await supabase
      .from("fiscal_documents")
      .select("modification_code, modification_reason")
      .eq("id", doc.id)
      .maybeSingle();

    if (noteErr) {
      console.error("load credit note fields failed:", noteErr);
      return null;
    }
    if (noteRow) {
      doc.modification_code = (noteRow as Record<string, unknown>)
        .modification_code as number | null;
      doc.modification_reason = (noteRow as Record<string, unknown>)
        .modification_reason as string | null;
    }
  }

  // El comprobante que la nota anula: su e-NCF y su fecha van dentro de la
  // nota (informationReference).
  let modifiedDoc: ModifiedDocumentRef | null = null;
  if (isCreditNoteType(doc.ncf_type) && doc.related_document_id) {
    const { data: refRow, error: refErr } = await supabase
      .from("fiscal_documents")
      .select("ncf_number, issued_at")
      .eq("id", doc.related_document_id)
      .maybeSingle();

    if (refErr) {
      console.error("load referenced document failed:", refErr);
      return null;
    }
    if (refRow) {
      modifiedDoc = refRow as ModifiedDocumentRef;
    }
  }

  return { doc, settings: settingsRes.data as Settings, sender, items, modifiedDoc };
}

async function submitOne(
  supabase: SupabaseClient,
  alanube: AlanubeClient,
  outbox: OutboxRow,
): Promise<{ ok: true } | { ok: false; retryable: boolean; error: string }> {
  const ctx = await loadContext(supabase, outbox);
  if (!ctx) {
    return { ok: false, retryable: false, error: "context load failed" };
  }
  const { doc, settings, sender, items, modifiedDoc } = ctx;

  if (doc.alanube_document_id) {
    console.log(`doc ${doc.id} already submitted (alanube_id=${doc.alanube_document_id})`);
    return { ok: true };
  }

  if (!doc.is_electronic) {
    return { ok: false, retryable: false, error: "doc is not electronic" };
  }
  if (settings.mode === "physical") {
    return { ok: false, retryable: false, error: "settings.mode=physical, should not be in queue" };
  }

  const path = getEndpointForNcfType(doc.ncf_type);
  if (!path) {
    return {
      ok: false,
      retryable: false,
      error: `unsupported ncf_type=${doc.ncf_type}: no Alanube endpoint mapped`,
    };
  }

  // La DGII exige la fecha de vencimiento de la secuencia en todos los tipos
  // menos E32. Sin ella el comprobante vuelve rechazado con el codigo 145, asi
  // que se para AQUI: un e-NCF rechazado es un numero quemado y un cliente sin
  // factura valida.
  const sequenceDueDate = await loadSequenceDueDate(supabase, outbox.business_id, doc);
  const needsDueDate = doc.ncf_type !== "E32" && !isCreditNoteType(doc.ncf_type);
  if (needsDueDate && !sequenceDueDate) {
    return {
      ok: false,
      retryable: true,
      error:
        `La secuencia ${doc.ncf_type} no tiene fecha de vencimiento cargada ` +
        `(ncf_sequences.expiration_date). La DGII la valida contra la autorizacion ` +
        `del rango y rechazaria el comprobante con el codigo 145. Carga la fecha de ` +
        `la autorizacion en Ajustes > Comprobantes fiscales y reintenta.`,
    };
  }

  // Una nota sin el comprobante referenciado no es emitible: la DGII no sabria
  // que esta anulando. Es reintentable porque el enlace se arregla con un
  // UPDATE, no re-emitiendo.
  if (isCreditNoteType(doc.ncf_type) && !modifiedDoc) {
    return {
      ok: false,
      retryable: true,
      error:
        "La nota de credito no tiene el comprobante que anula " +
        "(fiscal_documents.related_document_id). No se puede declarar sin el.",
    };
  }

  const ecfBreakdown = await computeEcfBreakdown(supabase, doc.order_id, items);
  const payload = buildAlanubePayload(
    doc,
    sender,
    items,
    ecfBreakdown,
    settings.alanube_company_id,
    sequenceDueDate,
    modifiedDoc,
  );
  const idemKey = doc.idempotency_key ?? doc.id;

  let resp: AlanubeSubmitResponse;
  try {
    resp = await alanube.request<AlanubeSubmitResponse>({
      method: "POST",
      path,
      body: payload,
      idempotencyKey: idemKey,
      companyId: settings.alanube_company_id,
    });
  } catch (e) {
    const err = e as AlanubeError;
    const bodyStr = JSON.stringify(err.body ?? "");
    const isDgiiTransient =
      bodyStr.includes("AEP2009") ||
      bodyStr.includes("DGII service") ||
      bodyStr.includes("network path") ||
      bodyStr.includes("timed out");
    const retryable = err.isRetryable || isDgiiTransient;

    console.error(
      `Alanube error for doc ${doc.id}: status=${err.status} retryable=${retryable} (orig=${err.isRetryable}, dgii_transient=${isDgiiTransient}) body=${bodyStr}`,
    );
    return { ok: false, retryable, error: `${err.message} | ${bodyStr}` };
  }

  const mappedStatus = mapAlanubeStatus(resp.status);

  const { error: updErr } = await supabase
    .from("fiscal_documents")
    .update({
      alanube_document_id: resp.id ?? resp.trackId ?? null,
      ecf_tracking_number: resp.trackId ?? null,
      ecf_security_code: resp.securityCode ?? null,
      ecf_signed_at: resp.signedAt ?? null,
      ecf_status: mappedStatus,
      submitted_at: new Date().toISOString(),
      public_url: resp.publicUrl ?? null,
      xml_url: resp.xmlUrl ?? null,
      pdf_url: resp.pdfUrl ?? null,
      last_error: null,
    })
    .eq("id", doc.id);

  if (updErr) {
    console.error(`Failed to persist Alanube response for doc ${doc.id}:`, updErr);
    return { ok: false, retryable: true, error: `persist failed: ${updErr.message}` };
  }

  await supabase.from("fiscal_document_status_events").insert({
    fiscal_document_id: doc.id,
    previous_status: "pending",
    new_status: mappedStatus,
    source: "api_response",
    note: `Alanube id=${resp.id ?? resp.trackId ?? "unknown"}; raw_status=${resp.status ?? "n/a"}`,
  });

  console.log(`doc ${doc.id} submitted OK, alanube_id=${resp.id ?? resp.trackId}`);
  return { ok: true };
}

function mapAlanubeStatus(raw: string | undefined): "pending" | "sent" | "accepted" | "rejected" {
  if (!raw) return "sent";
  const s = raw.toLowerCase();
  if (s.includes("accept") || s.includes("aprob")) return "accepted";
  if (s.includes("reject") || s.includes("rechaz") || s.includes("error")) return "rejected";
  if (s.includes("pending") || s.includes("pendient")) return "pending";
  return "sent";
}

async function completeOutbox(
  supabase: SupabaseClient,
  outbox: OutboxRow,
  result: { ok: true } | { ok: false; retryable: boolean; error: string },
) {
  if (result.ok) {
    await supabase
      .from("alanube_emit_outbox")
      .update({ status: "done", error: null, next_attempt_at: null })
      .eq("id", outbox.id);
    return;
  }

  const isDead = !result.retryable || outbox.attempts >= MAX_ATTEMPTS;
  if (isDead) {
    await supabase
      .from("alanube_emit_outbox")
      .update({ status: "failed", error: result.error.slice(0, 2000) })
      .eq("id", outbox.id);

    await supabase
      .from("fiscal_documents")
      .update({ last_error: result.error.slice(0, 2000), ecf_status: "rejected" })
      .eq("id", outbox.fiscal_document_id);
  } else {
    await supabase
      .from("alanube_emit_outbox")
      .update({
        status: "pending",
        error: result.error.slice(0, 2000),
        next_attempt_at: nextAttemptAt(outbox.attempts),
      })
      .eq("id", outbox.id);
  }
}

// Reclamar una sola row de outbox por fiscal_document_id. Mismo patron de
// claim atomico que claimBatch (UPDATE...WHERE status='pending') para evitar
// que dos invocaciones simultaneas (ej. el trigger sync + el cron) procesen
// el mismo doc en paralelo.
async function claimSingle(
  supabase: SupabaseClient,
  fiscalDocumentId: string,
): Promise<OutboxRow | null> {
  const now = new Date().toISOString();
  const { data: candidate, error } = await supabase
    .from("alanube_emit_outbox")
    .select("id, fiscal_document_id, business_id, settings_id, attempts")
    .eq("fiscal_document_id", fiscalDocumentId)
    .eq("status", "pending")
    .order("created_at", { ascending: true })
    .limit(1)
    .maybeSingle();

  if (error) {
    console.error("claimSingle select failed:", error);
    return null;
  }
  if (!candidate) return null;

  const { data: row, error: updErr } = await supabase
    .from("alanube_emit_outbox")
    .update({
      status: "processing",
      attempts: candidate.attempts + 1,
      last_attempt_at: now,
    })
    .eq("id", candidate.id)
    .eq("status", "pending")
    .select("id, fiscal_document_id, business_id, settings_id, attempts")
    .maybeSingle();

  if (updErr) {
    console.error(`claimSingle update failed for ${candidate.id}:`, updErr);
    return null;
  }
  return row as OutboxRow | null;
}

// Lee del fiscal_documents los campos que el caller (POS) necesita para
// imprimir el ticket inmediatamente sin tener que hacer otro round-trip.
async function loadDocSnapshotForResponse(
  supabase: SupabaseClient,
  fiscalDocumentId: string,
): Promise<Record<string, unknown> | null> {
  const { data, error } = await supabase
    .from("fiscal_documents")
    .select(
      "id, ecf_status, ecf_security_code, ecf_signed_at, alanube_document_id, public_url, last_error",
    )
    .eq("id", fiscalDocumentId)
    .maybeSingle();
  if (error) {
    console.error("loadDocSnapshotForResponse error:", error);
    return null;
  }
  return data as Record<string, unknown> | null;
}

Deno.serve(async (req: Request) => {
  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  let alanube: AlanubeClient;
  try {
    alanube = createAlanubeClient();
  } catch (e) {
    return new Response(
      JSON.stringify({ ok: false, error: e instanceof Error ? e.message : String(e) }),
      { status: 500, headers: { "Content-Type": "application/json" } },
    );
  }

  // Parse opcional del body. Si trae fiscal_document_id, modo sync per-doc:
  // procesa solo ese y devuelve el snapshot del doc para que el POS arme
  // el ticket. Sin body → modo batch (drena la queue, lo que dispara el cron).
  let targetDocId: string | null = null;
  try {
    if (req.method === "POST") {
      const ct = req.headers.get("content-type") ?? "";
      if (ct.includes("application/json")) {
        const raw = await req.text();
        if (raw.length > 0) {
          const body = JSON.parse(raw) as Record<string, unknown>;
          const id = body.fiscal_document_id;
          if (typeof id === "string" && id.length > 0) targetDocId = id;
        }
      }
    }
  } catch (e) {
    console.error("body parse error (continuando en modo batch):", e);
  }

  const startedAt = Date.now();

  // ─── Modo sync per-doc ──────────────────────────────────────────────────
  if (targetDocId !== null) {
    const claimed = await claimSingle(supabase, targetDocId);
    if (!claimed) {
      // No hay outbox row 'pending' — puede ser que ya se proceso (otro
      // invocador gano el race) o que el trigger no creo la row. Devolvemos
      // el snapshot actual del doc para que el caller decida.
      const snapshot = await loadDocSnapshotForResponse(supabase, targetDocId);
      return new Response(
        JSON.stringify({
          ok: snapshot !== null,
          mode: "sync",
          claimed: false,
          fiscal_document_id: targetDocId,
          doc: snapshot,
          duration_ms: Date.now() - startedAt,
        }, null, 2),
        { headers: { "Content-Type": "application/json" } },
      );
    }

    let result: { ok: true } | { ok: false; retryable: boolean; error: string };
    try {
      result = await submitOne(supabase, alanube, claimed);
    } catch (e) {
      const errMsg = e instanceof Error ? e.message : String(e);
      console.error(`sync: unexpected error for outbox ${claimed.id}:`, e);
      result = { ok: false, retryable: true, error: errMsg };
    }
    await completeOutbox(supabase, claimed, result);
    const snapshot = await loadDocSnapshotForResponse(supabase, targetDocId);

    return new Response(
      JSON.stringify({
        ok: result.ok,
        mode: "sync",
        claimed: true,
        fiscal_document_id: targetDocId,
        doc: snapshot,
        ...(result.ok ? {} : { retryable: result.retryable, error: result.error }),
        duration_ms: Date.now() - startedAt,
      }, null, 2),
      { headers: { "Content-Type": "application/json" } },
    );
  }

  // ─── Modo batch (cron / fallback) ───────────────────────────────────────
  const claimed = await claimBatch(supabase);
  const results: Array<{ outbox_id: string; doc_id: string; ok: boolean; retryable?: boolean; error?: string }> = [];

  for (const row of claimed) {
    try {
      const r = await submitOne(supabase, alanube, row);
      await completeOutbox(supabase, row, r);
      results.push({
        outbox_id: row.id,
        doc_id: row.fiscal_document_id,
        ok: r.ok,
        ...(r.ok ? {} : { retryable: r.retryable, error: r.error }),
      });
    } catch (e) {
      const errMsg = e instanceof Error ? e.message : String(e);
      console.error(`unexpected error processing outbox ${row.id}:`, e);
      await completeOutbox(supabase, row, { ok: false, retryable: true, error: errMsg });
      results.push({ outbox_id: row.id, doc_id: row.fiscal_document_id, ok: false, retryable: true, error: errMsg });
    }
  }

  return new Response(
    JSON.stringify({
      ok: true,
      mode: "batch",
      claimed: claimed.length,
      results,
      duration_ms: Date.now() - startedAt,
      runtime: { deno: Deno.version.deno },
    }, null, 2),
    { headers: { "Content-Type": "application/json" } },
  );
});
