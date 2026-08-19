// emit-document: procesa alanube_emit_outbox.
// Disparado por cron (cada 60s) o manualmente por curl.
// Cada invocación procesa hasta BATCH_SIZE docs pendientes.

import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import { createAlanubeClient, AlanubeClient, AlanubeError } from "../_shared/alanube-client.ts";
import { r2, roundAndReconcile } from "../_shared/dgii-rounding.ts";

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

interface FiscalDocument {
  id: string;
  business_id: string;
  order_id: string | null;
  ncf_type: string;
  ncf_number: string;
  customer_rnc: string | null;
  customer_name: string;
  customer_address: string | null;
  subtotal: number | null;
  discount: number | null;
  tax_exempt: number | null;
  taxable_amount: number | null;
  itbis_amount: number | null;
  service_fee: number | null;
  tip: number | null;
  total: number | null;
  is_electronic: boolean;
  alanube_document_id: string | null;
  issued_at: string | null;
  idempotency_key: string | null;
}

interface Settings {
  alanube_company_id: string;
  environment: string;
  mode: string;
}

interface Sender {
  rnc: string;
  companyName: string;
  tradename?: string;
  address: string;
  branchOffice?: string;
  mail?: string;
}

interface OrderItem {
  id: string;
  product_id: string | null;
  product_name: string | null;
  sku: string | null;
  quantity: number;
  unit_price: number;
  tax_rate: number;
  tax: number | null;
  subtotal: number | null;
  discounts: number | null;
}

interface TaxLineRow {
  order_item_id: string;
  tax_rate: number | null;
  amount: number | null;
  // PostgREST devuelve la relacion FK como objeto cuando es many-to-one
  // (order_item_tax_lines.tax_id → taxes.id, cada line apunta a 1 tax) y
  // como array si la cardinalidad se detecta diferente. Manejamos ambos
  // shapes en runtime para ser robustos a cambios de schema/PostgREST.
  taxes:
    | { include_in_ecf: boolean | null }
    | { include_in_ecf: boolean | null }[]
    | null;
}

interface EcfTaxBreakdown {
  itbisAmount: number;
  taxableAmount: number;
  effectiveRatePct: number;
}

function getEndpointForNcfType(ncfType: string): string | null {
  switch (ncfType) {
    case "E31": return "/fiscal-invoices";
    case "E32": return "/invoices";
    case "E44": return "/special-regimes";
    case "E45": return "/gubernamentals";
    default: return null;
  }
}

function billingIndicatorFromTaxRate(rate: number | null | undefined): 1 | 2 | 3 | 4 {
  if (rate == null || rate === 0) return 4;
  const pct = rate > 1 ? rate : rate * 100;
  if (pct >= 17 && pct <= 19) return 1;
  if (pct >= 15 && pct <= 17) return 2;
  if (pct === 0) return 3;
  return 4;
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

  const { data, error } = await supabase
    .from("order_item_tax_lines")
    .select("order_item_id, tax_rate, amount, taxes(include_in_ecf)")
    .in("order_item_id", itemIds);

  if (error) {
    console.error("computeEcfBreakdown: failed to load tax_lines:", error);
    return null;
  }

  const rows = (data ?? []) as TaxLineRow[];
  if (rows.length === 0) return null;

  const itemEcfTax = new Map<string, number>();
  const itemEcfRateNumerator = new Map<string, number>();
  const itemEcfRateDenominator = new Map<string, number>();

  for (const r of rows) {
    // PostgREST many-to-one: r.taxes es un objeto. PostgREST one-to-many u
    // otros casos puede devolverlo como array. Manejamos ambos para
    // robustez. Default `true` cuando el lookup falle (no romper docs
    // legacy sin la columna include_in_ecf).
    const taxesField = r.taxes;
    const include =
      (Array.isArray(taxesField)
        ? taxesField[0]?.include_in_ecf
        : taxesField?.include_in_ecf) ??
      true;
    if (!include) continue;
    const amt = Number(r.amount ?? 0);
    if (amt <= 0) continue;
    const rate = Number(r.tax_rate ?? 0);
    itemEcfTax.set(r.order_item_id, (itemEcfTax.get(r.order_item_id) ?? 0) + amt);
    itemEcfRateNumerator.set(
      r.order_item_id,
      (itemEcfRateNumerator.get(r.order_item_id) ?? 0) + rate * amt,
    );
    itemEcfRateDenominator.set(
      r.order_item_id,
      (itemEcfRateDenominator.get(r.order_item_id) ?? 0) + amt,
    );
  }

  let itbisAmount = 0;
  let taxableAmount = 0;
  let weightedRateNum = 0;
  let weightedRateDen = 0;

  for (const it of items) {
    const ecfTax = itemEcfTax.get(it.id) ?? 0;
    if (ecfTax <= 0) continue;
    itbisAmount += ecfTax;
    taxableAmount += Number(it.subtotal ?? 0);
    weightedRateNum += itemEcfRateNumerator.get(it.id) ?? 0;
    weightedRateDen += itemEcfRateDenominator.get(it.id) ?? 0;
  }

  if (itbisAmount <= 0) return null;

  const effectiveRatePct = weightedRateDen > 0
    ? Math.round(weightedRateNum / weightedRateDen)
    : 18;

  return {
    itbisAmount: Number(itbisAmount.toFixed(2)),
    taxableAmount: Number(taxableAmount.toFixed(2)),
    effectiveRatePct,
  };
}

function buildAlanubePayload(
  doc: FiscalDocument,
  sender: Sender,
  items: OrderItem[],
  ecfBreakdown: EcfTaxBreakdown | null,
): Record<string, unknown> {
  const stampDate = (doc.issued_at ?? new Date().toISOString()).slice(0, 10);
  const isE31OrCreditDoc = doc.ncf_type === "E31";
  const totalAbove250k = Number(doc.total ?? 0) >= 250_000;
  const buyerRequired = isE31OrCreditDoc || (doc.ncf_type === "E32" && totalAbove250k);

  const idDoc: Record<string, unknown> = {
    encf: doc.ncf_number,
    paymentType: 1,
    incomeType: 1,
  };
  if (doc.ncf_type !== "E32") {
    const oneYearAhead = new Date();
    oneYearAhead.setFullYear(oneYearAhead.getFullYear() + 1);
    idDoc.sequenceDueDate = oneYearAhead.toISOString().slice(0, 10);
  }

  const senderPayload: Record<string, unknown> = {
    rnc: sender.rnc,
    companyName: sender.companyName,
    address: sender.address,
    stampDate,
  };
  if (sender.tradename) senderPayload.tradename = sender.tradename;
  if (sender.branchOffice) senderPayload.branchOffice = sender.branchOffice;
  if (sender.mail) senderPayload.mail = sender.mail;

  let buyer: Record<string, unknown> | undefined;
  if (buyerRequired || doc.customer_rnc || (doc.customer_name && doc.customer_name !== "Consumidor Final")) {
    buyer = { companyName: doc.customer_name || "Consumidor Final" };
    if (doc.customer_rnc) buyer.rnc = doc.customer_rnc;
    if (doc.customer_address) buyer.address = doc.customer_address;
  }

  const amountOf = (it: OrderItem): number =>
    Number(it.subtotal ?? Number(it.quantity ?? 1) * Number(it.unit_price ?? 0));

  // DGII rechaza lineas en cero o negativas (AP10073). Las lineas negativas
  // vienen del modelo de ofertas, que mete la unidad gratis como linea en
  // negativo. Un descuento va en el campo de descuento de la linea, nunca
  // como una linea aparte, asi que aqui simplemente no se declaran.
  const billable = items.filter((it) => amountOf(it) > 0);

  const itbis = ecfBreakdown?.itbisAmount ?? Number(doc.itbis_amount ?? 0);
  const taxable = ecfBreakdown?.taxableAmount ?? Number(doc.taxable_amount ?? 0);
  const exempt = Number(doc.tax_exempt ?? 0);
  const itbisRate = Math.round(ecfBreakdown?.effectiveRatePct ?? 18);

  // Las lineas se reconcilian contra su propia suma redondeada, NO contra
  // `taxable`. Cuando todo el pedido esta gravado las dos cifras son la
  // misma (taxable es toFixed(2) de esa suma). Pero si el negocio tiene
  // productos sin impuesto vinculado en menu_item_taxes, `taxable` solo
  // cuenta los gravados y quedaria por debajo de la suma de lineas: forzar
  // el ajuste contra ese numero deformaria montos que estan bien. La
  // diferencia entre ambos es la porcion exenta y va en `exemptAmount`.
  const reconcileTarget = r2(
    billable.reduce((acc, it) => acc + amountOf(it), 0),
  );

  const amounts = roundAndReconcile(billable.map(amountOf), reconcileTarget);

  const itemDetails = billable.length > 0
    ? billable.map((it, idx) => ({
        lineNumber: idx + 1,
        billingIndicator: billingIndicatorFromTaxRate(it.tax_rate),
        itemName: (it.product_name ?? "Producto").slice(0, 80),
        goodServiceIndicator: 1,
        quantityItem: Number(it.quantity ?? 1),
        unitPriceItem: r2(Number(it.unit_price ?? 0)),
        itemAmount: amounts[idx],
      }))
    : [{
        lineNumber: 1,
        billingIndicator: billingIndicatorFromTaxRate(0.18),
        itemName: "Venta general",
        goodServiceIndicator: 1,
        quantityItem: 1,
        unitPriceItem: r2(Number(doc.total ?? 0)),
        itemAmount: r2(Number(doc.total ?? 0)),
      }];

  const declaredTotal = ecfBreakdown != null
    ? r2(taxable + itbis + exempt)
    : Number(doc.total ?? 0);

  const totals: Record<string, unknown> = {
    totalAmount: r2(declaredTotal),
  };
  if (taxable > 0) {
    totals.totalTaxedAmount = r2(taxable);
    totals.i1AmountTaxed = r2(taxable);
    totals.itbisS1 = itbisRate;
    totals.itbis1Total = r2(itbis);
    totals.itbisTotal = r2(itbis);
  }
  if (exempt > 0) totals.exemptAmount = r2(exempt);

  const payload: Record<string, unknown> = {
    idDoc,
    sender: senderPayload,
    totals,
    itemDetails,
  };
  if (buyer) payload.buyer = buyer;

  return payload;
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

async function loadContext(
  supabase: SupabaseClient,
  outbox: OutboxRow,
): Promise<{ doc: FiscalDocument; settings: Settings; sender: Sender; items: OrderItem[] } | null> {
  const [docRes, settingsRes, fiscalSettingsRes, businessRes] = await Promise.all([
    supabase
      .from("fiscal_documents")
      .select(
        "id, business_id, order_id, ncf_type, ncf_number, customer_rnc, customer_name, customer_address, subtotal, discount, tax_exempt, taxable_amount, itbis_amount, service_fee, tip, total, is_electronic, alanube_document_id, issued_at, idempotency_key",
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
    const { data: itemRows, error: itemsErr } = await supabase
      .from("order_items")
      .select(
        "id, product_id, product_name, sku, quantity, unit_price, tax_rate, tax, subtotal, discounts",
      )
      .eq("order_id", doc.order_id)
      // Un item anulado no se vendio: declararlo a DGII es sobre-facturar.
      .neq("status", "void");

    if (itemsErr) {
      console.error("load order_items failed:", itemsErr);
      return null;
    }
    items = (itemRows ?? []) as OrderItem[];
  }

  return { doc, settings: settingsRes.data as Settings, sender, items };
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
  const { doc, settings, sender, items } = ctx;

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

  const ecfBreakdown = await computeEcfBreakdown(supabase, doc.order_id, items);
  const payload = buildAlanubePayload(doc, sender, items, ecfBreakdown);
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
