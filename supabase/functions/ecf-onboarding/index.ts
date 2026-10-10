// ecf-onboarding: alta de facturacion electronica hecha por un operador de
// MangoPOS desde el panel (mangopos_administrador). El cliente no toca nada:
// entrega sus datos y su certificado, y el operador hace los pasos.
//
// POST /functions/v1/ecf-onboarding
//   { action, business_id, ...params }
//
// Acciones:
//   status            → todo lo que pinta la seccion del panel
//   save_data         { data: TaxpayerInput } — borrador, puede ir incompleto
//   sync_fiscal       → copia RNC y razon social a fiscal_settings (lo que lee la POS)
//   find_company      → empresas asociadas en Alanube con el RNC del negocio
//   link_company      { alanube_company_id } — vincula una que ya existe
//   register_company  { certificate: { filename, content_base64, password } }
//   save_sequence     { sequence: SequenceInput } — desde el PDF de la DGII
//   set_ecf_enabled   { enabled } — el mismo switch "Modalidad e-CF" de la POS
//
// Certificacion ante la DGII (clientes que aun no son emisores electronicos):
//   postulation_info  → datos del proveedor + URLs de la empresa
//   sign_document     { kind: postulation|declaration|roles, xml: { filename, content_base64 } }
//   import_test_set   { file: { filename, content_base64 }, set_kind? } — un Excel
//                     (.xlsx, o .csv de una hoja) del portal de certificacion de
//                     la DGII: el de pruebas de datos e-CF (`ecf`) o el de
//                     aprobaciones comerciales (`acecf`), que se reconoce solo.
//                     Reemplaza los casos cargados de ese tipo.
//   send_test_set     { certificate, set_kind? } — firma con el .p12 del cliente
//                     y manda a CerteCF los casos pendientes, en lotes de ~30 s:
//                     si responde `more: true`, el panel vuelve a llamar. El
//                     certificado no se guarda.
//   generate_simulation_set → paso 4 ("Pruebas de simulacion e-CF"): arma los e-CF
//                     con el set de datos aceptado como modelo, los datos reales
//                     del emisor y e-NCF nuevos. Se manda con send_test_set
//                     { set_kind: "sim" }.
//   check_test_set    { certificate?, set_kind? } — consulta los trackId en la DGII
//   test_case_xml     { case_id } → XML firmado de un caso (los E32 < 250 mil
//                     se suben a mano en el portal de la DGII) y, si es un e-CF,
//                     los datos de su representacion impresa (`print`)
//   set_dgii_authorized { authorized } — el operador marca que la DGII lo aprobo
//   list_requests     → solicitudes hechas desde la POS (sin business_id)
//   reveal_ofv_password → usuario y clave de la Oficina Virtual que mando el
//                       cliente (queda en noc_audit_log; si no se puede
//                       auditar, no se muestra)
//
// Solicitud del CLIENTE desde la POS (owner/admin del negocio, o operador):
//   request_status    → en que va su facturacion electronica
//   submit_request    { data, details, certificate, contact_name, contact_phone,
//                       already_authorized, accept_terms }
//                     → guarda la solicitud y registra la empresa en Alanube
//                     `details` (telefono, representante legal, sucursales,
//                     tipos de e-CF, usuario/clave OFV) es opcional para no
//                     romper POS viejas; si viene, se exige completo.
//
// La activacion (`business_alanube_settings`) NO vive aqui: la hace
// `provision-ecf`, que corre el preflight. El panel la llama directo.
//
// Todo lo demas es solo para operadores de MangoPOS (`is_platform_operator`).
// Se escribe con service_role y queda en `noc_audit_log`. El certificado y su contrasena
// viajan a Alanube en la misma peticion y no se guardan ni se registran.
// La clave de la Oficina Virtual SI se guarda (el operador la necesita para la
// certificacion), cifrada con AES-GCM y la llave `ECF_CREDENTIALS_KEY` del
// entorno: la BD sola no la revela.

import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import { AlanubeClient, AlanubeError, createAlanubeClient } from "../_shared/alanube-client.ts";
import { corsPreflight, errorResponse, jsonResponse } from "../_shared/responses.ts";
import { environmentFromBaseUrl, normalizeRnc, normalizeText } from "../_shared/ecf-preflight.ts";
import { importSecretKey, openSecret, sealSecret } from "../_shared/secret-box.ts";
import { DgiiCertificationClient, DgiiError, DgiiResult } from "../_shared/dgii-certification.ts";
import { canonicalSeed, DgiiSigner, loadSigner, securityCode, SignerError, signXml } from "../_shared/dgii-signer.ts";
import { buildSimulationCases, encfNumber, SimulationTemplate } from "../_shared/ecf-simulation.ts";
import { buildPrintModel } from "../_shared/ecf-print.ts";
import {
  buildAcecfXml,
  buildEcfXml,
  buildRfceXml,
  DgiiMessage,
  dgiiTimestamp,
  isAdjustmentNote,
  isFinalStatus,
  parseApprovalSet,
  parseTestSet,
  readTestSetFile,
  sendOrder,
  TestCaseStatus,
  TestSetCase,
  TestSetField,
  TestSetKind,
} from "../_shared/ecf-test-set.ts";
import {
  AssociatedCompany,
  buildCompanyPayload,
  buildWebhooks,
  CertificateInput,
  companiesMatchingRnc,
  defaultNcfTypeFor,
  EnablingXmlInput,
  ExistingSequence,
  hasUsableEcfSequence,
  missingForClientRequest,
  ONBOARDING_SEQUENCE_TYPES,
  parseAssociatedPage,
  parseProviderInfo,
  planSequenceWrite,
  Branch,
  RequestDetailsInput,
  requestStage,
  SIGNED_AT_COLUMN,
  SequenceInput,
  suggestEcfTypes,
  summarizeCompany,
  TaxpayerData,
  TaxpayerInput,
  validateCertificate,
  validateEnablingXml,
  validateRequestContact,
  validateRequestDetails,
  validateTaxpayer,
} from "../_shared/ecf-onboarding.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL");
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

const WEBHOOK_PATH = "/functions/v1/alanube-webhook";
// SUPABASE_URL dentro del contenedor es la direccion interna (kong); Alanube
// necesita la publica.
const WEBHOOK_URL = Deno.env.get("ALANUBE_WEBHOOK_URL") ??
  `https://supabase.mangopos.do${WEBHOOK_PATH}`;

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const ASSOCIATED_PAGE_SIZE = 50;
const ASSOCIATED_MAX_PAGES = 40;

const ONBOARDING_COLUMNS =
  "business_id, rnc, legal_name, trade_name, fiscal_address, province, municipality, email, " +
  "alanube_company_id, company_linked_via, company_linked_at, " +
  "postulation_signed_at, declaration_signed_at, roles_signed_at, dgii_authorized_at, " +
  "requested_at, contact_name, contact_phone, already_authorized, " +
  "phone, legal_rep_name, branches, ecf_types, ofv_user, ofv_password_updated_at, " +
  "test_set_filename, test_set_loaded_at, approval_set_filename, approval_set_loaded_at, " +
  "simulation_set_generated_at, simulation_sequences, " +
  "dgii_test_token_expires_at, created_at, updated_at";
// `ofv_password_enc` (la clave cifrada) NO va en ONBOARDING_COLUMNS: solo la lee
// reveal_ofv_password. Tampoco `dgii_test_token_enc`: solo la usa el set de pruebas.

const TEST_CASE_COLUMNS =
  "id, kind, position, case_id, ecf_type, encf, total, via, modifies, status, track_id, security_code, " +
  "messages, sent_at, checked_at";

/**
 * Tiempo de trabajo de cada `send_test_set` (y de cada `check_test_set`). El
 * gateway corta a los 60 s: el panel vuelve a llamar mientras la respuesta
 * traiga `more: true`. Se revisa antes de cada llamada a la DGII, que puede
 * tardar hasta 20 s más.
 */
const TEST_SET_SEND_BUDGET_MS = 30_000;
/** Espera entre consultas a la DGII despues de mandar. */
const TEST_SET_POLL_INTERVAL_MS = 4_000;

/** Acciones que puede usar el dueño/admin del negocio desde la POS. */
const CLIENT_ACTIONS = new Set(["request_status", "submit_request"]);
const CLIENT_ROLES = new Set(["owner", "admin"]);

interface RequestBody {
  action?: string;
  business_id?: string;
  data?: TaxpayerInput;
  details?: RequestDetailsInput;
  alanube_company_id?: string;
  certificate?: CertificateInput;
  sequence?: SequenceInput;
  enabled?: boolean;
  kind?: string;
  xml?: Omit<EnablingXmlInput, "kind">;
  file?: { filename?: string; content_base64?: string };
  set_kind?: string;
  case_id?: string;
  authorized?: boolean;
  contact_name?: string;
  contact_phone?: string;
  already_authorized?: boolean;
  accept_terms?: boolean;
}

interface OnboardingRow extends TaxpayerData {
  business_id: string;
  alanube_company_id: string | null;
  company_linked_via: string | null;
  company_linked_at: string | null;
  postulation_signed_at: string | null;
  declaration_signed_at: string | null;
  roles_signed_at: string | null;
  dgii_authorized_at: string | null;
  requested_at: string | null;
  contact_name: string | null;
  contact_phone: string | null;
  already_authorized: boolean | null;
  phone: string | null;
  legal_rep_name: string | null;
  branches: Branch[] | null;
  ecf_types: string[] | null;
  ofv_user: string | null;
  ofv_password_updated_at: string | null;
  test_set_filename: string | null;
  test_set_loaded_at: string | null;
  approval_set_filename: string | null;
  approval_set_loaded_at: string | null;
  simulation_set_generated_at: string | null;
  simulation_sequences: Record<string, number> | null;
  dgii_test_token_expires_at: string | null;
}

interface TestCaseRow {
  id: string;
  kind: TestSetKind;
  position: number;
  case_id: string;
  ecf_type: string;
  encf: string;
  total: number | string | null;
  via: "ecf" | "rfce" | "acecf";
  modifies: string | null;
  status: TestCaseStatus;
  track_id: string | null;
  security_code: string | null;
  messages: DgiiMessage[] | null;
  sent_at: string | null;
  checked_at: string | null;
}

interface Ctx {
  service: SupabaseClient;
  userId: string;
  businessId: string;
  body: RequestBody;
}

Deno.serve(async (req: Request) => {
  const pre = corsPreflight(req);
  if (pre) return pre;
  if (req.method !== "POST") return errorResponse(405, "method_not_allowed", "Use POST");
  if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
    return errorResponse(500, "config_error", "Faltan SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY.");
  }

  const authHeader = req.headers.get("Authorization");
  if (!authHeader?.startsWith("Bearer ")) {
    return errorResponse(401, "unauthorized", "Falta el Bearer token");
  }

  let body: RequestBody;
  try {
    body = await req.json();
  } catch {
    return errorResponse(400, "invalid_request", "El body debe ser JSON");
  }

  // list_requests es la unica accion que no es de un negocio.
  const needsBusiness = body.action !== "list_requests";
  const businessId = body.business_id?.trim() ?? "";
  if (needsBusiness && !UUID_RE.test(businessId)) {
    return errorResponse(400, "invalid_request", "business_id debe ser un UUID");
  }

  // ── Autorizacion ────────────────────────────────────────────────────────
  // Operador de MangoPOS: todo. Dueño/admin del negocio: solo su solicitud.
  const userClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: authHeader } },
  });
  const { data: userData, error: userErr } = await userClient.auth.getUser();
  if (userErr || !userData?.user) {
    return errorResponse(401, "unauthorized", "No se pudo resolver el usuario del JWT");
  }
  const { data: isOperator, error: opErr } = await userClient.rpc("is_platform_operator", {
    uid: userData.user.id,
  });
  if (opErr) {
    return errorResponse(500, "rpc_error", "No se pudo verificar el operador", opErr.message);
  }
  if (isOperator !== true) {
    if (!CLIENT_ACTIONS.has(body.action ?? "")) {
      return errorResponse(403, "forbidden", "Solo un operador de MangoPOS puede hacer el alta e-CF.");
    }
    const { data: role, error: roleErr } = await userClient.rpc("user_business_role", {
      _user_id: userData.user.id,
      _business_id: businessId,
    });
    if (roleErr) {
      return errorResponse(500, "rpc_error", "No se pudo resolver el rol", roleErr.message);
    }
    if (!CLIENT_ROLES.has(role as string)) {
      return errorResponse(
        403,
        "forbidden",
        "Solo el dueño o un administrador del negocio puede solicitar la facturación electrónica.",
      );
    }
  }

  const service = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  if (!needsBusiness) {
    try {
      return await actionListRequests(service);
    } catch (e) {
      if (e instanceof HttpError) return errorResponse(e.status, e.code, e.message, e.detail);
      return errorResponse(500, "internal_error", e instanceof Error ? e.message : String(e));
    }
  }

  const { data: biz, error: bizErr } = await service
    .from("businesses")
    .select("id")
    .eq("id", businessId)
    .maybeSingle();
  if (bizErr) return errorResponse(500, "db_error", "No se pudo leer el negocio", bizErr.message);
  if (!biz) return errorResponse(404, "business_not_found", "El negocio no existe");

  const ctx: Ctx = { service, userId: userData.user.id, businessId, body };

  try {
    switch (body.action) {
      case "status":
        return await actionStatus(ctx);
      case "save_data":
        return await actionSaveData(ctx);
      case "sync_fiscal":
        return await actionSyncFiscal(ctx);
      case "find_company":
        return await actionFindCompany(ctx);
      case "link_company":
        return await actionLinkCompany(ctx);
      case "register_company":
        return await actionRegisterCompany(ctx);
      case "save_sequence":
        return await actionSaveSequence(ctx);
      case "set_ecf_enabled":
        return await actionSetEcfEnabled(ctx);
      case "postulation_info":
        return await actionPostulationInfo(ctx);
      case "sign_document":
        return await actionSignDocument(ctx);
      case "import_test_set":
        return await actionImportTestSet(ctx);
      case "send_test_set":
        return await actionSendTestSet(ctx);
      case "check_test_set":
        return await actionCheckTestSet(ctx);
      case "test_case_xml":
        return await actionTestCaseXml(ctx);
      case "generate_simulation_set":
        return await actionGenerateSimulationSet(ctx);
      case "set_dgii_authorized":
        return await actionSetDgiiAuthorized(ctx);
      case "request_status":
        return await actionRequestStatus(ctx);
      case "submit_request":
        return await actionSubmitRequest(ctx);
      case "reveal_ofv_password":
        return await actionRevealOfvPassword(ctx);
      default:
        return errorResponse(400, "invalid_request", `Accion desconocida: ${body.action ?? "(vacia)"}`);
    }
  } catch (e) {
    if (e instanceof HttpError) return errorResponse(e.status, e.code, e.message, e.detail);
    console.error(`ecf-onboarding ${body.action} fallo:`, e);
    return errorResponse(500, "internal_error", e instanceof Error ? e.message : String(e));
  }
});

// ── Acciones ─────────────────────────────────────────────────────────────

async function actionStatus(ctx: Ctx): Promise<Response> {
  const { service, businessId } = ctx;
  const [bizRes, onboarding, fsRes, seqRes, settingsRes] = await Promise.all([
    service
      .from("businesses")
      .select("id, business_name, branch_name, address")
      .eq("id", businessId)
      .maybeSingle(),
    loadOnboarding(service, businessId),
    service
      .from("fiscal_settings")
      .select("rnc, business_legal_name, ecf_enabled, default_ncf_type")
      .eq("business_id", businessId)
      .maybeSingle(),
    service
      .from("ncf_sequences")
      .select("id, ncf_type, range_start, range_end, current_number, expiration_date, is_active, authorized_by")
      .eq("business_id", businessId)
      .in("ncf_type", ONBOARDING_SEQUENCE_TYPES)
      .order("ncf_type"),
    service
      .from("business_alanube_settings")
      .select("id, alanube_company_id, environment, mode, certification_status, webhooks_configured, updated_at")
      .eq("business_id", businessId)
      .maybeSingle(),
  ]);
  for (const r of [bizRes, fsRes, seqRes, settingsRes]) {
    if (r.error) throw new HttpError(500, "db_error", "No se pudo leer el estado", r.error.message);
  }

  const fiscal = fsRes.data as
    | { rnc: string | null; business_legal_name: string | null; ecf_enabled: boolean | null; default_ncf_type: string | null }
    | null;
  const settings = settingsRes.data as { alanube_company_id: string } | null;

  // Tropella se activo antes de que existiera esta tabla: su ULID solo esta
  // en business_alanube_settings.
  const companyId = onboarding?.alanube_company_id ?? settings?.alanube_company_id ?? null;
  let company: ReturnType<typeof summarizeCompany> & { webhooks_ok: boolean } | null = null;
  let companyError: string | null = null;
  // Los sets solo interesan mientras la certificacion esta en curso.
  const certifying = !!onboarding && !onboarding.dgii_authorized_at;
  const [, testSet, approvalSet, simulationSet] = await Promise.all([
    (async () => {
      if (!companyId) return;
      try {
        const raw = await getCompany(alanubeOrThrow(), companyId);
        company = {
          ...summarizeCompany(raw),
          webhooks_ok: JSON.stringify(raw.webhooks ?? {}).includes(WEBHOOK_PATH),
        };
      } catch (e) {
        companyError = describeAlanubeError(e, "consultar la empresa");
      }
    })(),
    certifying && onboarding?.test_set_loaded_at
      ? testSetSummary(service, businessId, onboarding, "ecf")
      : Promise.resolve(null),
    certifying && onboarding?.approval_set_loaded_at
      ? testSetSummary(service, businessId, onboarding, "acecf")
      : Promise.resolve(null),
    certifying && onboarding?.simulation_set_generated_at
      ? testSetSummary(service, businessId, onboarding, "sim")
      : Promise.resolve(null),
  ]);

  return jsonResponse({
    business: bizRes.data,
    onboarding,
    fiscal,
    fiscal_sync: onboarding
      ? {
        rnc_matches: normalizeRnc(onboarding.rnc) === normalizeRnc(fiscal?.rnc),
        legal_name_matches: normalizeText(onboarding.legal_name) === normalizeText(fiscal?.business_legal_name),
      }
      : null,
    sequences: seqRes.data ?? [],
    alanube_settings: settingsRes.data,
    company,
    company_error: companyError,
    test_set: testSet,
    approval_set: approvalSet,
    simulation_set: simulationSet,
    environment: environmentFromBaseUrl(Deno.env.get("ALANUBE_BASE_URL") ?? ""),
  });
}

async function actionSaveData(ctx: Ctx): Promise<Response> {
  const { service, businessId, userId, body } = ctx;
  const v = validateTaxpayer(body.data ?? {});
  if (!v.ok) throw new HttpError(422, "invalid_data", v.errors.join(" "), v.errors);

  const current = await loadOnboarding(service, businessId);
  await assertRncMatchesLinkedCompany(service, businessId, current, v.value.rnc);

  const saved = await upsertOnboarding(service, businessId, userId, current, { ...v.value });
  await audit(service, userId, businessId, "save_data", { before: current, after: v.value });
  return jsonResponse({ ok: true, onboarding: saved });
}

async function actionSyncFiscal(ctx: Ctx): Promise<Response> {
  const { service, businessId, userId } = ctx;
  const onboarding = await loadOnboarding(service, businessId);
  if (!onboarding?.rnc || !onboarding.legal_name) {
    throw new HttpError(409, "incomplete_data", "Guarda primero el RNC y la razon social.");
  }
  // Este RNC se imprime en todos los comprobantes de la POS, electronicos o no.
  await assertRncMatchesLinkedCompany(service, businessId, onboarding, onboarding.rnc);

  const { data: before, error: readErr } = await service
    .from("fiscal_settings")
    .select("rnc, business_legal_name")
    .eq("business_id", businessId)
    .maybeSingle();
  if (readErr) throw new HttpError(500, "db_error", "No se pudo leer fiscal_settings", readErr.message);

  // Solo RNC y razon social: ecf_enabled y el predefinido los maneja el
  // switch, y un upsert completo los pisaria.
  const write = before
    ? service
      .from("fiscal_settings")
      .update({ rnc: onboarding.rnc, business_legal_name: onboarding.legal_name })
      .eq("business_id", businessId)
    : service
      .from("fiscal_settings")
      .insert({ business_id: businessId, rnc: onboarding.rnc, business_legal_name: onboarding.legal_name });
  const { error } = await write;
  if (error) throw new HttpError(500, "db_error", "No se pudo actualizar fiscal_settings", error.message);

  await audit(service, userId, businessId, "sync_fiscal", {
    before,
    after: { rnc: onboarding.rnc, business_legal_name: onboarding.legal_name },
  });
  return jsonResponse({ ok: true });
}

async function actionFindCompany(ctx: Ctx): Promise<Response> {
  const { service, businessId } = ctx;
  const rnc = await resolveRnc(service, businessId);
  if (!rnc) throw new HttpError(409, "incomplete_data", "El negocio no tiene RNC para buscar.");

  const matches = companiesMatchingRnc(await listAssociated(alanubeOrThrow()), rnc);
  const assigned = await assignedBusinesses(service, matches.map((m) => m.id));

  return jsonResponse({
    rnc,
    matches: matches.map((m) => ({
      ...summarizeCompany(m),
      assigned_to_business_id: assigned.get(m.id) ?? null,
    })),
  });
}

async function actionLinkCompany(ctx: Ctx): Promise<Response> {
  const { service, businessId, userId, body } = ctx;
  const companyId = body.alanube_company_id?.trim() ?? "";
  if (companyId.length === 0) {
    throw new HttpError(400, "invalid_request", "alanube_company_id es obligatorio");
  }

  const current = await loadOnboarding(service, businessId);
  if (current?.alanube_company_id && current.alanube_company_id !== companyId) {
    throw new HttpError(
      409,
      "already_linked",
      `Este negocio ya esta vinculado a la empresa ${current.alanube_company_id} de Alanube.`,
    );
  }
  const { data: activeSettings, error: settingsErr } = await service
    .from("business_alanube_settings")
    .select("alanube_company_id")
    .eq("business_id", businessId)
    .maybeSingle();
  if (settingsErr) throw new HttpError(500, "db_error", "No se pudo leer la activacion", settingsErr.message);
  const activeId = (activeSettings as { alanube_company_id: string } | null)?.alanube_company_id;
  if (activeId && activeId !== companyId) {
    throw new HttpError(
      409,
      "already_linked",
      `Este negocio ya esta activado con la empresa ${activeId} de Alanube.`,
    );
  }
  const owner = (await assignedBusinesses(service, [companyId])).get(companyId);
  if (owner && owner !== businessId) {
    throw new HttpError(409, "company_already_assigned", "Esa empresa de Alanube ya es de otro negocio.", {
      assigned_to_business_id: owner,
    });
  }

  const rnc = current?.rnc ?? await resolveRnc(service, businessId);
  if (!rnc) throw new HttpError(409, "incomplete_data", "Guarda primero el RNC del negocio.");

  let company: AssociatedCompany & Record<string, unknown>;
  try {
    company = await getCompany(alanubeOrThrow(), companyId);
  } catch (e) {
    if (e instanceof AlanubeError && e.status === 404) {
      throw new HttpError(404, "company_not_found", "Alanube no tiene una empresa con ese ID.");
    }
    throw new HttpError(502, "alanube_error", describeAlanubeError(e, "consultar la empresa"));
  }

  // Vincular el ULID de otro contribuyente firmaria sus comprobantes con un
  // certificado ajeno. Este chequeo no se salta.
  if (normalizeRnc(company.identification) !== normalizeRnc(rnc)) {
    throw new HttpError(
      409,
      "rnc_mismatch",
      `Esa empresa de Alanube es del RNC ${company.identification ?? "(sin RNC)"} ` +
        `(${company.name ?? "sin nombre"}), no del ${rnc}.`,
    );
  }

  // Lo que falte en el borrador se completa con lo que Alanube ya tiene.
  const merged: TaxpayerData = {
    rnc: normalizeRnc(rnc),
    legal_name: current?.legal_name ?? str(company.name),
    trade_name: current?.trade_name ?? str(company.tradeName),
    fiscal_address: current?.fiscal_address ?? str(company.address),
    province: current?.province ?? str(company.province),
    municipality: current?.municipality ?? str(company.municipality),
    email: current?.email ?? str(company.email),
  };
  const saved = await upsertOnboarding(service, businessId, userId, current, {
    ...merged,
    alanube_company_id: companyId,
    company_linked_via: "existing",
    company_linked_at: new Date().toISOString(),
  });
  await audit(service, userId, businessId, "link_company", { alanube_company_id: companyId });
  return jsonResponse({ ok: true, onboarding: saved, company: summarizeCompany(company) });
}

async function actionRegisterCompany(ctx: Ctx): Promise<Response> {
  const current = await loadOnboarding(ctx.service, ctx.businessId);
  const { saved, created } = await registerCompany(ctx, current);
  return jsonResponse({ ok: true, onboarding: saved, company: summarizeCompany(created) });
}

/**
 * Da de alta la empresa en Alanube con el certificado de `ctx.body.certificate`
 * y guarda el ULID. La usan el operador (register_company) y la solicitud del
 * cliente (submit_request). Lanza HttpError con codigo: incomplete_data,
 * already_linked, invalid_certificate, company_exists, alanube_rejected...
 */
async function registerCompany(
  ctx: Ctx,
  current: OnboardingRow | null,
): Promise<{ saved: OnboardingRow; created: AssociatedCompany & Record<string, unknown> }> {
  const { service, businessId, userId, body } = ctx;

  const data = validateTaxpayer(current ?? {}, { forRegistration: true });
  if (!data.ok) throw new HttpError(409, "incomplete_data", data.errors.join(" "), data.errors);

  if (current?.alanube_company_id) {
    throw new HttpError(409, "already_linked", "Este negocio ya tiene su empresa en Alanube.");
  }
  const { data: settings } = await service
    .from("business_alanube_settings")
    .select("alanube_company_id")
    .eq("business_id", businessId)
    .maybeSingle();
  if (settings) {
    throw new HttpError(409, "already_linked", "Este negocio ya esta activado con una empresa de Alanube.", {
      alanube_company_id: (settings as { alanube_company_id: string }).alanube_company_id,
    });
  }

  const cert = validateCertificate(body.certificate ?? {});
  if (!cert.ok) throw new HttpError(422, "invalid_certificate", cert.errors.join(" "), cert.errors);

  const secret = Deno.env.get("ALANUBE_WEBHOOK_SECRET");
  if (!secret) {
    throw new HttpError(500, "config_error", "El servidor no tiene ALANUBE_WEBHOOK_SECRET.");
  }

  const alanube = alanubeOrThrow();

  // Dar de alta dos veces el mismo RNC deja dos empresas en la cuenta y el
  // riesgo de vincular la que no tiene el certificado bueno.
  const existing = companiesMatchingRnc(await listAssociated(alanube), data.value.rnc);
  if (existing.length > 0) {
    throw new HttpError(
      409,
      "company_exists",
      "Ya hay una empresa con ese RNC en Alanube. Vinculala en vez de crear otra.",
      { matches: existing.map(summarizeCompany) },
    );
  }

  let created: AssociatedCompany & Record<string, unknown>;
  try {
    const res = await alanube.request<Record<string, unknown>>({
      method: "POST",
      path: "/company",
      body: buildCompanyPayload(data.value, cert.value, buildWebhooks(WEBHOOK_URL, secret)),
      // Alanube prueba el webhook durante el alta.
      timeoutMs: 60_000,
    });
    created = unwrapCompany(res);
  } catch (e) {
    if (e instanceof AlanubeError && e.status >= 400 && e.status < 500) {
      throw new HttpError(422, "alanube_rejected", describeAlanubeError(e, "dar de alta la empresa"), e.body);
    }
    throw new HttpError(502, "alanube_error", describeAlanubeError(e, "dar de alta la empresa"));
  }

  if (!created.id) {
    throw new HttpError(502, "alanube_error", "Alanube respondio sin ID de empresa. Revisa en el portal si se creo.");
  }

  try {
    const saved = await upsertOnboarding(service, businessId, userId, current, {
      alanube_company_id: created.id,
      company_linked_via: "registered",
      company_linked_at: new Date().toISOString(),
    });
    await audit(service, userId, businessId, "register_company", {
      alanube_company_id: created.id,
      certificate_file: body.certificate?.filename ?? null,
      certificate_issuer: created.certificate?.issuerName ?? null,
      certificate_end_date: created.certificate?.endDate ?? null,
    });
    return { saved, created };
  } catch (e) {
    // La empresa YA existe en Alanube: sin el ID en la respuesta el operador
    // no tendria como vincularla.
    throw new HttpError(
      500,
      "db_error",
      `La empresa se creo en Alanube (ID ${created.id}) pero no se pudo guardar. ` +
        `Vinculala con ese ID.`,
      { alanube_company_id: created.id, cause: e instanceof Error ? e.message : String(e) },
    );
  }
}

async function actionSaveSequence(ctx: Ctx): Promise<Response> {
  const { service, businessId, userId, body } = ctx;
  const input = body.sequence ?? {};
  const type = (input.ncf_type ?? "").trim().toUpperCase();

  // Por tipo y sin filtrar la serie: una fila vieja con otra `serie` haria que
  // el insert creara una segunda secuencia del mismo tipo.
  const { data: rows, error: readErr } = ONBOARDING_SEQUENCE_TYPES.includes(type)
    ? await service
      .from("ncf_sequences")
      .select("id, serie, range_start, range_end, current_number, expiration_date, authorized_by")
      .eq("business_id", businessId)
      .eq("ncf_type", type)
    : { data: [], error: null };
  if (readErr) throw new HttpError(500, "db_error", "No se pudo leer la secuencia", readErr.message);
  if ((rows ?? []).length > 1) {
    throw new HttpError(
      409,
      "duplicate_sequences",
      `El negocio tiene ${rows!.length} secuencias ${type}. Deja una sola en la POS antes de cargar la autorizacion.`,
    );
  }
  const existing = (rows ?? [])[0] ?? null;

  const today = new Date().toLocaleDateString("en-CA", { timeZone: "America/Santo_Domingo" });
  const plan = planSequenceWrite(input, existing as ExistingSequence | null, today);
  if (!plan.ok) throw new HttpError(422, "invalid_sequence", plan.errors.join(" "), plan.errors);

  const w = plan.value;
  const { error } = w.kind === "insert"
    ? await service.from("ncf_sequences").insert({ business_id: businessId, ...w.row })
    : await service.from("ncf_sequences").update(w.patch).eq("id", w.id);
  if (error) throw new HttpError(500, "db_error", "No se pudo guardar la secuencia", error.message);

  await audit(service, userId, businessId, "save_sequence", {
    ncf_type: type,
    before: existing,
    write: w,
  });
  return jsonResponse({ ok: true, kind: w.kind });
}

async function actionSetEcfEnabled(ctx: Ctx): Promise<Response> {
  const { service, businessId, userId, body } = ctx;
  if (typeof body.enabled !== "boolean") {
    throw new HttpError(400, "invalid_request", "enabled debe ser true o false");
  }
  const enabled = body.enabled;

  const [fsRes, settingsRes] = await Promise.all([
    service
      .from("fiscal_settings")
      .select("rnc, ecf_enabled, default_ncf_type")
      .eq("business_id", businessId)
      .maybeSingle(),
    service
      .from("business_alanube_settings")
      .select("mode")
      .eq("business_id", businessId)
      .maybeSingle(),
  ]);
  if (fsRes.error || settingsRes.error) {
    throw new HttpError(500, "db_error", "No se pudo leer la configuracion", fsRes.error?.message ?? settingsRes.error?.message);
  }
  const fs = fsRes.data as { rnc: string | null; ecf_enabled: boolean | null; default_ncf_type: string | null } | null;
  if (!fs) throw new HttpError(409, "no_fiscal_settings", "El negocio no tiene configuracion fiscal.");

  // Encender sin provision-ecf es el limbo de Tropella: la POS emite serie E y
  // el trigger no tiene a quien mandarla.
  const mode = (settingsRes.data as { mode: string } | null)?.mode;
  if (enabled && (!mode || mode === "physical")) {
    throw new HttpError(
      409,
      "not_provisioned",
      "Falta activar la empresa (verificacion y activacion) antes de encender la modalidad e-CF.",
    );
  }

  const newDefault = defaultNcfTypeFor(fs.default_ncf_type, enabled);
  if (enabled) {
    const { data: seqs, error: seqErr } = await service
      .from("ncf_sequences")
      .select("range_end, current_number, is_active")
      .eq("business_id", businessId)
      .eq("ncf_type", newDefault);
    if (seqErr) throw new HttpError(500, "db_error", "No se pudo leer las secuencias", seqErr.message);
    const usable = ((seqs ?? []) as Array<{ range_end: number; current_number: number; is_active: boolean | null }>)
      .some((q) => q.is_active === true && Number(q.current_number) < Number(q.range_end));
    if (!usable) {
      throw new HttpError(
        409,
        "no_sequence",
        `No hay secuencia ${newDefault} activa con numeros: la primera venta fallaria.`,
      );
    }
  }
  const { error } = await service
    .from("fiscal_settings")
    .update({ ecf_enabled: enabled, default_ncf_type: newDefault })
    .eq("business_id", businessId);
  if (error) throw new HttpError(500, "db_error", "No se pudo cambiar la modalidad", error.message);

  await audit(service, userId, businessId, "set_ecf_enabled", {
    before: { ecf_enabled: fs.ecf_enabled, default_ncf_type: fs.default_ncf_type },
    after: { ecf_enabled: enabled, default_ncf_type: newDefault },
  });
  return jsonResponse({ ok: true, ecf_enabled: enabled, default_ncf_type: newDefault });
}

// ── Certificacion ante la DGII ───────────────────────────────────────────

async function actionPostulationInfo(ctx: Ctx): Promise<Response> {
  const { service, businessId } = ctx;
  const companyId = await requireCompanyId(service, businessId);
  const alanube = alanubeOrThrow();

  const [providerRes, companyRes] = await Promise.allSettled([
    alanube.request<unknown>({ method: "GET", path: "/provider-info" }),
    getCompany(alanube, companyId),
  ]);

  if (providerRes.status === "rejected") {
    throw new HttpError(502, "alanube_error", describeAlanubeError(providerRes.reason, "consultar los datos del proveedor"));
  }

  // Sin URLs la pantalla igual sirve: se informa y sigue.
  let companyUrls: ReturnType<typeof summarizeCompany>["company_urls"] = null;
  let companyError: string | null = null;
  if (companyRes.status === "fulfilled") {
    companyUrls = summarizeCompany(companyRes.value).company_urls;
  } else {
    companyError = describeAlanubeError(companyRes.reason, "consultar la empresa");
  }

  return jsonResponse({
    provider: parseProviderInfo(providerRes.value),
    company_urls: companyUrls,
    company_error: companyError,
  });
}

async function actionSignDocument(ctx: Ctx): Promise<Response> {
  const { service, businessId, userId, body } = ctx;
  const xml = validateEnablingXml({ ...(body.xml ?? {}), kind: body.kind });
  if (!xml.ok) throw new HttpError(422, "invalid_xml", xml.errors.join(" "), xml.errors);

  const companyId = await requireCompanyId(service, businessId);

  const form = new FormData();
  form.append("xml", new Blob([new Uint8Array(xml.value.bytes)], { type: "application/xml" }), xml.value.filename);

  let signedUrl: string | null = null;
  try {
    const res = await alanubeOrThrow().request<{ signedDocumentUrl?: unknown }>({
      method: "POST",
      path: `/sign-document/idCompany/${encodeURIComponent(companyId)}`,
      form,
      timeoutMs: 60_000,
    });
    signedUrl = typeof res?.signedDocumentUrl === "string" ? res.signedDocumentUrl : null;
  } catch (e) {
    if (e instanceof HttpError) throw e;
    const status = e instanceof AlanubeError && e.status >= 400 && e.status < 500 ? 422 : 502;
    throw new HttpError(status, "alanube_error", describeAlanubeError(e, "firmar el documento"), e instanceof AlanubeError ? e.body : undefined);
  }
  if (!signedUrl) {
    throw new HttpError(502, "alanube_error", "Alanube firmo pero no devolvio el enlace del XML firmado.");
  }

  const current = await loadOnboarding(service, businessId);
  const signedAt = new Date().toISOString();
  await upsertOnboarding(service, businessId, userId, current, {
    [SIGNED_AT_COLUMN[xml.value.kind]]: signedAt,
  } as Partial<OnboardingRow>);
  await audit(service, userId, businessId, "sign_document", {
    kind: xml.value.kind,
    filename: xml.value.filename,
    bytes: xml.value.bytes.length,
  });

  return jsonResponse({ ok: true, kind: xml.value.kind, signed_at: signedAt, signed_document_url: signedUrl });
}

// ── Set de pruebas de la DGII ────────────────────────────────────────────
//
// La DGII entrega el set en su portal de certificacion; aqui se carga, se
// firma con el .p12 del cliente y se manda a CerteCF. Alanube no participa.

const BASE64_FILE_RE = /^[A-Za-z0-9+/]+={0,2}$/;

function decodeUpload(file: RequestBody["file"]): { filename: string; bytes: Uint8Array } {
  const filename = (file?.filename ?? "").trim();
  const content = (file?.content_base64 ?? "").replace(/^data:[^,]*,/, "").replace(/\s+/g, "");
  if (!filename) throw new HttpError(422, "invalid_file", "Falta el nombre del archivo.");
  if (!content || content.length % 4 !== 0 || !BASE64_FILE_RE.test(content)) {
    throw new HttpError(422, "invalid_file", "El contenido del archivo no es base64 valido.");
  }
  return { filename, bytes: Uint8Array.from(atob(content), (c) => c.charCodeAt(0)) };
}

function testSetDbError(error: { code?: string; message: string }, what: string): HttpError {
  if (error.code === "42P01" || error.code === "PGRST205") {
    return new HttpError(500, "migration_missing", "Falta aplicar la migracion 20261008_0003_ecf_test_set.sql.");
  }
  if (error.code === "42703" || error.code === "PGRST204") {
    return new HttpError(500, "migration_missing", "Falta aplicar la migracion 20261009_0002_ecf_test_set_approvals.sql.");
  }
  if (error.code === "23514") {
    return new HttpError(500, "migration_missing", "Falta aplicar la migracion 20261009_0003_ecf_simulation_set.sql.");
  }
  if (error.code === "PGRST202" || error.code === "42883") {
    return new HttpError(
      500,
      "migration_missing",
      "Falta aplicar la migracion 20261009_0006_ecf_test_set_atomic_replace.sql.",
    );
  }
  return new HttpError(500, "db_error", what, error.message);
}

function setKindOf(raw: unknown): TestSetKind {
  if (raw === undefined || raw === null || raw === "ecf") return "ecf";
  if (raw === "acecf" || raw === "sim") return raw;
  throw new HttpError(400, "invalid_request", "set_kind debe ser ecf, acecf o sim");
}

const SET_NAMES: Record<TestSetKind, string> = {
  ecf: "el set de pruebas de e-CF",
  acecf: "las aprobaciones comerciales",
  sim: "la simulacion de e-CF",
};

interface TestCaseWithData extends TestCaseRow {
  fields: TestSetField[];
  summary_fields: TestSetField[] | null;
}

async function loadTestCases(
  service: SupabaseClient,
  businessId: string,
  kind: TestSetKind,
): Promise<TestCaseWithData[]> {
  const { data, error } = await service
    .from("ecf_test_set_cases")
    .select(`${TEST_CASE_COLUMNS}, fields, summary_fields`)
    .eq("business_id", businessId)
    .eq("kind", kind)
    .order("position");
  if (error) throw testSetDbError(error, "No se pudo leer el set de pruebas");
  return (data ?? []) as unknown as TestCaseWithData[];
}

async function testSetSummary(
  service: SupabaseClient,
  businessId: string,
  onboarding: OnboardingRow | null,
  kind: TestSetKind,
) {
  const { data, error } = await service
    .from("ecf_test_set_cases")
    .select(TEST_CASE_COLUMNS)
    .eq("business_id", businessId)
    .eq("kind", kind)
    .order("position");
  if (error) throw testSetDbError(error, "No se pudo leer el set de pruebas");
  const expires = onboarding?.dgii_test_token_expires_at ?? null;
  return {
    kind,
    filename: (kind === "ecf"
      ? onboarding?.test_set_filename
      : kind === "acecf"
      ? onboarding?.approval_set_filename
      : null) ?? null,
    loaded_at: (kind === "ecf"
      ? onboarding?.test_set_loaded_at
      : kind === "acecf"
      ? onboarding?.approval_set_loaded_at
      : onboarding?.simulation_set_generated_at) ?? null,
    // Mientras no venza, "Consultar" no pide el certificado.
    session_expires_at: expires && new Date(expires).getTime() > Date.now() ? expires : null,
    cases: ((data ?? []) as unknown as TestCaseRow[]).map((c) => ({
      ...c,
      total: c.total === null ? null : Number(c.total),
    })),
  };
}

async function updateTestCase(
  service: SupabaseClient,
  c: TestCaseRow,
  patch: Partial<TestCaseRow> & { signed_xml?: string | null },
): Promise<void> {
  const { error } = await service.from("ecf_test_set_cases").update(patch).eq("id", c.id);
  if (error) throw testSetDbError(error, `No se pudo guardar el resultado de ${c.encf}`);
  Object.assign(c, patch);
}

function fieldValue(fields: TestSetField[], column: string): string | null {
  const c = column.toLowerCase();
  return fields.find(([k]) => k.toLowerCase() === c)?.[1].trim() ?? null;
}

/** Nombre que pide la DGII: RNC de quien firma (emisor, o comprador en el ACECF) + e-NCF. */
function dgiiFilename(c: TestCaseWithData): string {
  const rnc = fieldValue(c.fields, c.via === "acecf" ? "RNCComprador" : "RNCEmisor") ?? "";
  return `${rnc.replace(/\D/g, "")}${c.encf}.xml`;
}

function dgiiErrorMessages(e: unknown): DgiiMessage[] {
  if (e instanceof DgiiError && e.messages.length > 0) return e.messages;
  return [{ code: e instanceof DgiiError && e.status > 0 ? String(e.status) : null, message: errorText(e) }];
}

function errorText(e: unknown): string {
  return e instanceof Error ? e.message : String(e);
}

async function signerOrThrow(cert: { content: string; password: string }): Promise<DgiiSigner> {
  let signer: DgiiSigner;
  try {
    signer = await loadSigner(Uint8Array.from(atob(cert.content), (ch) => ch.charCodeAt(0)), cert.password);
  } catch (e) {
    throw new HttpError(422, "invalid_certificate", e instanceof SignerError ? e.message : errorText(e));
  }
  if (signer.notAfter.getTime() < Date.now()) {
    throw new HttpError(
      422,
      "certificate_expired",
      `El certificado vencio el ${signer.notAfter.toISOString().slice(0, 10)}. La DGII no acepta firmas con el vencido.`,
    );
  }
  return signer;
}

function tokenContext(businessId: string): string {
  return `${businessId}:dgii-test-token`;
}

/** Semilla firmada → token de CerteCF. Se guarda cifrado para "Consultar". */
async function authenticateDgii(
  dgii: DgiiCertificationClient,
  signer: DgiiSigner,
  service: SupabaseClient,
  businessId: string,
): Promise<string> {
  let token;
  try {
    const seed = await dgii.getSeed();
    token = await dgii.validateSeed(await signXml(canonicalSeed(seed), signer));
  } catch (e) {
    if (e instanceof SignerError) throw new HttpError(502, "dgii_error", e.message);
    throw new HttpError(502, "dgii_error", `No se pudo autenticar con la DGII: ${errorText(e)}`, e instanceof DgiiError ? e.body : undefined);
  }
  try {
    const sealed = await sealSecret(await credentialsKeyOrThrow(), token.token, tokenContext(businessId));
    const { error } = await service
      .from("ecf_onboarding")
      .update({ dgii_test_token_enc: sealed, dgii_test_token_expires_at: token.expiresAt.toISOString() })
      .eq("business_id", businessId);
    if (error) console.error("ecf-onboarding: no se guardo el token de la DGII:", error.message);
  } catch (e) {
    // Sin llave igual se manda; solo que "Consultar" pedira el certificado.
    console.error("ecf-onboarding: no se guardo el token de la DGII:", errorText(e));
  }
  return token.token;
}

/** La DGII ya no acepta el token guardado (401): el proximo envio se autentica de nuevo. */
async function forgetDgiiTokenOn401(e: unknown, service: SupabaseClient, businessId: string): Promise<void> {
  if (!(e instanceof DgiiError) || e.status !== 401) return;
  await service
    .from("ecf_onboarding")
    .update({ dgii_test_token_enc: null, dgii_test_token_expires_at: null })
    .eq("business_id", businessId);
}

async function storedDgiiToken(service: SupabaseClient, businessId: string): Promise<string | null> {
  const { data, error } = await service
    .from("ecf_onboarding")
    .select("dgii_test_token_enc, dgii_test_token_expires_at")
    .eq("business_id", businessId)
    .maybeSingle();
  if (error) return null;
  const row = data as { dgii_test_token_enc: string | null; dgii_test_token_expires_at: string | null } | null;
  // Un minuto de margen: que no venza a mitad de la consulta.
  if (!row?.dgii_test_token_enc || !row.dgii_test_token_expires_at) return null;
  if (new Date(row.dgii_test_token_expires_at).getTime() < Date.now() + 60_000) return null;
  try {
    return await openSecret(await credentialsKeyOrThrow(), row.dgii_test_token_enc, tokenContext(businessId));
  } catch {
    return null;
  }
}

/** Firma y manda un caso. Devuelve por que hay que parar, o null para seguir. */
async function sendTestCase(
  c: TestCaseWithData,
  signer: DgiiSigner,
  dgii: DgiiCertificationClient,
  token: string,
  service: SupabaseClient,
  businessId: string,
): Promise<string | null> {
  const now = new Date().toISOString();
  let signed: string;
  let result: DgiiResult;
  let code: string;
  try {
    if (c.via === "acecf") {
      signed = await signXml(buildAcecfXml(c.fields), signer);
      code = securityCode(signed);
      result = await dgii.sendCommercialApproval(token, dgiiFilename(c), signed);
    } else {
      signed = await signXml(buildEcfXml(c.fields, dgiiTimestamp()), signer);
      code = securityCode(signed);
      result = c.via === "rfce"
        ? await dgii.sendSummary(token, dgiiFilename(c), await signXml(buildRfceXml(c.summary_fields ?? [], code), signer))
        : await dgii.sendEcf(token, dgiiFilename(c), signed);
    }
  } catch (e) {
    await forgetDgiiTokenOn401(e, service, businessId);
    await updateTestCase(service, c, {
      status: "error",
      messages: dgiiErrorMessages(e),
      signed_xml: null,
      sent_at: now,
      checked_at: now,
    });
    return `${c.encf}: ${errorText(e)}`;
  }
  await updateTestCase(service, c, {
    status: result.status,
    track_id: result.trackId,
    security_code: code,
    signed_xml: signed,
    messages: result.messages,
    sent_at: now,
    checked_at: isFinalStatus(result.status) ? now : null,
  });
  if (result.status === "rejected") {
    return `La DGII rechazo ${c.encf}: hay que reiniciar el set en el portal de la DGII y cargar el archivo nuevo.`;
  }
  return null;
}

/**
 * Consulta los trackId pendientes mientras quede tiempo. Devuelve cuantos
 * siguen en proceso (incluye los que no alcanzo a consultar).
 */
async function refreshTrackIds(
  cases: TestCaseRow[],
  dgii: DgiiCertificationClient,
  token: string,
  service: SupabaseClient,
  businessId: string,
  outOfTime: () => boolean,
): Promise<number> {
  let open = 0;
  for (const c of cases) {
    if (c.status !== "sent" || !c.track_id) continue;
    // Cada consulta puede tardar hasta 20 s: sin este corte, unas pocas lentas
    // pasan los 60 s del gateway. Lo que falta lo consulta el siguiente lote.
    if (outOfTime()) {
      open++;
      continue;
    }
    try {
      const r = await dgii.trackStatus(token, c.track_id);
      const now = new Date().toISOString();
      await updateTestCase(service, c, {
        status: r.status,
        messages: r.messages.length > 0 ? r.messages : c.messages,
        checked_at: now,
      });
      if (r.status === "sent") open++;
    } catch (e) {
      console.error(`ecf-onboarding: consulta de ${c.encf} fallo:`, errorText(e));
      if (e instanceof DgiiError && e.status === 401) {
        await forgetDgiiTokenOn401(e, service, businessId);
        throw new HttpError(409, "dgii_session_expired", "La sesion con la DGII vencio: elige el certificado otra vez.");
      }
      open++;
    }
  }
  return open;
}

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

/** Casos como los recibe fn_ecf_replace_test_set_cases. */
function testCaseRows(cases: TestSetCase[]) {
  return cases.map((c) => ({
    position: c.position,
    case_id: c.case_id,
    ecf_type: c.ecf_type,
    encf: c.encf,
    total: c.total,
    via: c.via,
    modifies: c.modifies,
    fields: c.fields,
    summary_fields: c.summary_fields,
    issuer_rnc: c.issuer_rnc ?? null,
  }));
}

async function actionImportTestSet(ctx: Ctx): Promise<Response> {
  const { service, businessId, userId, body } = ctx;
  const expected = body.set_kind === undefined ? null : setKindOf(body.set_kind);
  const { filename, bytes } = decodeUpload(body.file);
  let file;
  try {
    file = await readTestSetFile(filename, bytes);
  } catch (e) {
    throw new HttpError(422, "invalid_file", errorText(e));
  }
  const kind = file.kind;
  if (expected && expected !== kind) {
    throw new HttpError(
      422,
      "wrong_test_set",
      `Ese archivo es ${SET_NAMES[kind]}, no ${SET_NAMES[expected]}. Cargalo en su paso.`,
    );
  }
  const parsed = file.kind === "acecf" ? parseApprovalSet(file.rows) : parseTestSet(file.sheets);
  if (!parsed.ok) throw new HttpError(422, "invalid_test_set", parsed.errors.join(" "), parsed.errors);
  const cases = parsed.value;

  // La DGII arma el set para un RNC: el de otro contribuyente no sirve.
  const rnc = await resolveRnc(service, businessId);
  if (!rnc) throw new HttpError(409, "incomplete_data", "Guarda primero el RNC del contribuyente.");
  const fileRnc = cases[0].signer_rnc;
  if (normalizeRnc(fileRnc) !== normalizeRnc(rnc)) {
    throw new HttpError(
      409,
      "rnc_mismatch",
      `El archivo es del RNC ${fileRnc || "(sin RNC)"} y este negocio tiene el ${rnc}.`,
    );
  }

  // Borrar y guardar en una sola transaccion: si el set nuevo no entra, el
  // anterior queda como estaba.
  const { error: replaceErr } = await service.rpc("fn_ecf_replace_test_set_cases", {
    p_business_id: businessId,
    p_kind: kind,
    p_cases: testCaseRows(cases),
  });
  if (replaceErr) throw testSetDbError(replaceErr, "No se pudo guardar el set de pruebas");

  const current = await loadOnboarding(service, businessId);
  const loadedAt = new Date().toISOString();
  const saved = await upsertOnboarding(
    service,
    businessId,
    userId,
    current,
    kind === "ecf"
      ? { test_set_filename: filename, test_set_loaded_at: loadedAt }
      : { approval_set_filename: filename, approval_set_loaded_at: loadedAt },
  );
  await audit(service, userId, businessId, "import_test_set", {
    kind,
    filename,
    cases: cases.length,
    summaries: cases.filter((c) => c.via === "rfce").length,
    rfce_sheet: file.kind === "ecf" ? file.sheets.rfce !== null : null,
    replaced: (kind === "ecf" ? current?.test_set_filename : current?.approval_set_filename) ?? null,
  });
  return jsonResponse({ ok: true, kind, test_set: await testSetSummary(service, businessId, saved, kind) });
}

async function actionSendTestSet(ctx: Ctx): Promise<Response> {
  const { service, businessId, userId, body } = ctx;
  const kind = setKindOf(body.set_kind);
  const cert = validateCertificate(body.certificate ?? {});
  if (!cert.ok) throw new HttpError(422, "invalid_certificate", cert.errors.join(" "), cert.errors);

  const cases = await loadTestCases(service, businessId, kind);
  if (cases.length === 0) {
    throw new HttpError(409, "no_test_set", `Primero carga el archivo de ${SET_NAMES[kind]} de la DGII.`);
  }
  const rejected = cases.find((c) => c.status === "rejected");
  if (rejected) {
    throw new HttpError(
      409,
      "test_set_rejected",
      `La DGII rechazo ${rejected.encf}: reinicia el set en el portal de la DGII y carga el archivo nuevo.`,
    );
  }
  const pending = sendOrder(cases.filter((c) => c.status === "pending" || c.status === "error"));
  if (pending.length === 0) {
    throw new HttpError(409, "nothing_to_send", `Ya se mando todo ${SET_NAMES[kind]}.`);
  }

  const started = Date.now();
  const outOfTime = () => Date.now() - started > TEST_SET_SEND_BUDGET_MS;
  const signer = await signerOrThrow(cert.value);
  const dgii = new DgiiCertificationClient();
  // Los lotes siguientes reusan la sesion de la DGII (dura ~1 h).
  const token = await storedDgiiToken(service, businessId) ??
    await authenticateDgii(dgii, signer, service, businessId);

  const byEncf = new Map(cases.map((c) => [c.encf, c]));
  let sent = 0;

  /** Manda en orden hasta que algo obligue a parar o se acabe el tiempo. */
  const sendAll = async (list: TestCaseWithData[]): Promise<{ stop: string | null; timedOut: boolean }> => {
    for (const c of list) {
      if (outOfTime()) return { stop: null, timedOut: true };
      const stop = await sendTestCase(c, signer, dgii, token, service, businessId);
      sent++;
      if (stop) return { stop, timedOut: false };
    }
    return { stop: null, timedOut: false };
  };

  // Primero los comprobantes; las notas despues de que la DGII acepte lo que
  // modifican. Las aprobaciones comerciales no esperan nada.
  const notes = kind === "acecf" ? [] : pending.filter((c) => isAdjustmentNote(c.ecf_type));
  const referenceReady = (n: TestCaseWithData) => {
    const ref = n.modifies ? byEncf.get(n.modifies) : undefined;
    return !ref || ref.status === "accepted" || ref.status === "conditional";
  };
  const referenceRejected = (n: TestCaseWithData) => {
    const ref = n.modifies ? byEncf.get(n.modifies) : undefined;
    return ref?.status === "rejected" || ref?.status === "error";
  };

  let run = await sendAll(pending.filter((c) => !notes.includes(c)));
  let stopped = run.stop;
  let more = run.timedOut;
  if (!stopped && !more && notes.length > 0) {
    while (!notes.every(referenceReady) && !notes.some(referenceRejected) && !outOfTime()) {
      await sleep(TEST_SET_POLL_INTERVAL_MS);
      await refreshTrackIds(cases, dgii, token, service, businessId, outOfTime);
    }
    run = await sendAll(notes.filter(referenceReady));
    stopped = run.stop;
    more = run.timedOut;
    const blocked = notes.filter((n) => n.status === "pending" && referenceRejected(n));
    if (!stopped && blocked.length > 0) {
      stopped = `No se mandaron ${blocked.map((n) => n.encf).join(", ")}: el comprobante que modifican no fue aceptado.`;
    } else if (!stopped && notes.some((n) => n.status === "pending")) {
      more = true; // Todavia en proceso en la DGII: el siguiente lote las manda.
    }
  }

  // Lo recien mandado suele quedar listo en segundos.
  while (cases.some((c) => c.status === "sent") && !outOfTime()) {
    await sleep(TEST_SET_POLL_INTERVAL_MS);
    await refreshTrackIds(cases, dgii, token, service, businessId, outOfTime);
  }

  await audit(service, userId, businessId, "send_test_set", {
    kind,
    sent,
    more,
    stopped,
    certificate_subject: signer.subject,
    statuses: Object.fromEntries(cases.map((c) => [c.encf, c.status])),
  });
  const onboarding = await loadOnboarding(service, businessId);
  return jsonResponse({
    ok: true,
    sent,
    more: more && !stopped,
    stopped_reason: stopped,
    test_set: await testSetSummary(service, businessId, onboarding, kind),
  });
}

async function actionCheckTestSet(ctx: Ctx): Promise<Response> {
  const { service, businessId, body } = ctx;
  // Solo los e-CF quedan "en proceso": el resumen y la aprobacion comercial responden en el acto.
  const kind = setKindOf(body.set_kind);
  if (kind === "acecf") throw new HttpError(400, "invalid_request", "Las aprobaciones comerciales no se consultan.");
  const cases = await loadTestCases(service, businessId, kind);
  if (cases.some((c) => c.status === "sent" && c.track_id)) {
    const started = Date.now();
    const outOfTime = () => Date.now() - started > TEST_SET_SEND_BUDGET_MS;
    const dgii = new DgiiCertificationClient();
    let token = await storedDgiiToken(service, businessId);
    if (!token) {
      if (!body.certificate) {
        throw new HttpError(
          409,
          "dgii_session_expired",
          "La sesion con la DGII vencio: elige el certificado otra vez para consultar.",
        );
      }
      const cert = validateCertificate(body.certificate);
      if (!cert.ok) throw new HttpError(422, "invalid_certificate", cert.errors.join(" "), cert.errors);
      token = await authenticateDgii(dgii, await signerOrThrow(cert.value), service, businessId);
    }
    await refreshTrackIds(cases, dgii, token, service, businessId, outOfTime);
  }
  const onboarding = await loadOnboarding(service, businessId);
  return jsonResponse({ ok: true, test_set: await testSetSummary(service, businessId, onboarding, kind) });
}

async function actionTestCaseXml(ctx: Ctx): Promise<Response> {
  const { service, businessId, body } = ctx;
  const id = body.case_id?.trim() ?? "";
  if (!UUID_RE.test(id)) throw new HttpError(400, "invalid_request", "case_id debe ser un UUID");
  const { data, error } = await service
    .from("ecf_test_set_cases")
    .select("encf, case_id, via, fields, signed_xml")
    .eq("business_id", businessId)
    .eq("id", id)
    .maybeSingle();
  if (error) throw testSetDbError(error, "No se pudo leer el comprobante");
  const row = data as
    | { encf: string; case_id: string; via: string; fields: TestSetField[]; signed_xml: string | null }
    | null;
  if (!row) throw new HttpError(404, "not_found", "Ese comprobante no es del set cargado.");
  if (!row.signed_xml) throw new HttpError(409, "not_signed", `${row.encf} todavia no se ha firmado.`);
  let print = null;
  if (row.via !== "acecf") {
    try {
      print = buildPrintModel(row.fields, row.signed_xml);
    } catch (e) {
      console.error(`ecf-onboarding: RI de ${row.encf} fallo:`, errorText(e));
    }
  }
  return jsonResponse({
    filename: `${row.case_id.endsWith(row.encf) ? row.case_id : row.encf}.xml`,
    xml: row.signed_xml,
    print,
  });
}

/**
 * Paso 4: e-CF de simulacion con el set de datos aceptado como modelo. Volver a
 * generar reemplaza los casos y SIEMPRE usa e-NCF nuevos.
 */
async function actionGenerateSimulationSet(ctx: Ctx): Promise<Response> {
  const { service, businessId, userId } = ctx;
  const onboarding = await loadOnboarding(service, businessId);
  if (!onboarding?.rnc || !onboarding.legal_name || !onboarding.fiscal_address) {
    throw new HttpError(409, "incomplete_data", "Faltan el RNC, la razon social o la direccion fiscal del contribuyente.");
  }
  const templates = await loadTestCases(service, businessId, "ecf");
  if (templates.length === 0) {
    throw new HttpError(
      409,
      "no_test_set",
      "La simulacion se arma con el set de pruebas de e-CF que acepto la DGII: cargalo primero (paso 2).",
    );
  }
  const current = await loadTestCases(service, businessId, "sim");

  // Primer numero libre por tipo: despues de todo lo ya usado, aunque se haya borrado.
  const next: Record<string, number> = {};
  const bump = (type: string, n: number) => {
    next[type] = Math.max(next[type] ?? 1, n + 1);
  };
  for (const c of [...templates, ...current]) bump(c.ecf_type, encfNumber(c.encf));
  for (const [type, n] of Object.entries(onboarding.simulation_sequences ?? {})) bump(type, Number(n));

  const built = buildSimulationCases(
    templates as unknown as SimulationTemplate[],
    {
      rnc: normalizeRnc(onboarding.rnc),
      legalName: onboarding.legal_name,
      tradeName: onboarding.trade_name ?? null,
      address: onboarding.fiscal_address,
      province: onboarding.province ?? null,
      municipality: onboarding.municipality ?? null,
      phone: onboarding.phone ?? onboarding.contact_phone ?? null,
      email: onboarding.email ?? null,
    },
    dgiiTimestamp().slice(0, 10),
    next,
  );
  if (!built.ok) throw new HttpError(422, "invalid_simulation", built.errors.join(" "), built.errors);
  const { cases, lastNumbers } = built.value;

  // Reservar los numeros y reemplazar los casos en una transaccion, con la fila
  // del alta bloqueada: si otra simulacion reservo numeros mientras se armaba
  // esta, se aborta sin tocar nada (si no, las dos usarian los mismos e-NCF).
  const sequences: Record<string, number> = { ...(onboarding.simulation_sequences ?? {}) };
  for (const [type, n] of Object.entries(lastNumbers)) sequences[type] = Math.max(sequences[type] ?? 0, n);
  const { error: replaceErr } = await service.rpc("fn_ecf_replace_simulation_set", {
    p_business_id: businessId,
    p_user_id: userId,
    p_expected_sequences: onboarding.simulation_sequences ?? {},
    p_sequences: sequences,
    p_cases: testCaseRows(cases),
  });
  if (replaceErr) {
    if (replaceErr.message?.includes("SIMULATION_CONFLICT")) {
      throw new HttpError(
        409,
        "simulation_conflict",
        "Se genero otra simulacion al mismo tiempo. Vuelve a tocar Generar.",
      );
    }
    throw testSetDbError(replaceErr, "No se pudo guardar la simulacion");
  }
  const saved = await loadOnboarding(service, businessId);

  await audit(service, userId, businessId, "generate_simulation_set", {
    cases: cases.length,
    encf: cases.map((c) => c.encf),
    replaced: current.map((c) => ({ encf: c.encf, status: c.status })),
  });
  return jsonResponse({ ok: true, kind: "sim", test_set: await testSetSummary(service, businessId, saved, "sim") });
}

async function actionSetDgiiAuthorized(ctx: Ctx): Promise<Response> {
  const { service, businessId, userId, body } = ctx;
  if (typeof body.authorized !== "boolean") {
    throw new HttpError(400, "invalid_request", "authorized debe ser true o false");
  }
  const current = await loadOnboarding(service, businessId);
  const value = body.authorized ? new Date().toISOString() : null;
  const saved = await upsertOnboarding(service, businessId, userId, current, { dgii_authorized_at: value });
  await audit(service, userId, businessId, "set_dgii_authorized", {
    before: current?.dgii_authorized_at ?? null,
    after: value,
  });
  return jsonResponse({ ok: true, onboarding: saved });
}

// ── Solicitud del cliente (POS) ──────────────────────────────────────────

function todayInSantoDomingo(): string {
  return new Date().toLocaleDateString("en-CA", { timeZone: "America/Santo_Domingo" });
}

async function actionRequestStatus(ctx: Ctx): Promise<Response> {
  const { service, businessId } = ctx;
  const [onboarding, settingsRes, fsRes, seqRes, bizRes] = await Promise.all([
    loadOnboarding(service, businessId),
    service
      .from("business_alanube_settings")
      .select("alanube_company_id, mode")
      .eq("business_id", businessId)
      .maybeSingle(),
    service
      .from("fiscal_settings")
      .select("rnc, business_legal_name, ecf_enabled")
      .eq("business_id", businessId)
      .maybeSingle(),
    service
      .from("ncf_sequences")
      .select("ncf_type, range_end, current_number, expiration_date, is_active")
      .eq("business_id", businessId),
    service.from("businesses").select("phone").eq("id", businessId).maybeSingle(),
  ]);
  for (const r of [settingsRes, fsRes, seqRes, bizRes]) {
    if (r.error) throw new HttpError(500, "db_error", "No se pudo leer el estado", r.error.message);
  }
  const settings = settingsRes.data as { alanube_company_id: string; mode: string } | null;
  const fiscal = fsRes.data as { rnc: string | null; business_legal_name: string | null; ecf_enabled: boolean | null } | null;

  const stage = requestStage({
    requested: !!onboarding?.requested_at,
    hasCompany: !!(onboarding?.alanube_company_id || settings?.alanube_company_id),
    dgiiAuthorized: !!onboarding?.dgii_authorized_at,
    usableSequences: hasUsableEcfSequence(
      (seqRes.data ?? []) as Parameters<typeof hasUsableEcfSequence>[0],
      todayInSantoDomingo(),
    ),
    provisioned: !!settings && settings.mode !== "physical",
    ecfEnabled: fiscal?.ecf_enabled === true,
  });

  // Solo lo que el cliente mismo mando: nada de ULID, set de pruebas ni errores
  // de Alanube.
  return jsonResponse({
    stage,
    requested_at: onboarding?.requested_at ?? null,
    contact_name: onboarding?.contact_name ?? null,
    contact_phone: onboarding?.contact_phone ?? null,
    already_authorized: onboarding?.already_authorized ?? null,
    data: {
      rnc: onboarding?.rnc ?? fiscal?.rnc ?? null,
      legal_name: onboarding?.legal_name ?? fiscal?.business_legal_name ?? null,
      trade_name: onboarding?.trade_name ?? null,
      fiscal_address: onboarding?.fiscal_address ?? null,
      province: onboarding?.province ?? null,
      municipality: onboarding?.municipality ?? null,
      email: onboarding?.email ?? null,
    },
    // La clave de la OFV nunca vuelve: solo si ya hay una guardada.
    details: {
      phone: onboarding?.phone ?? str((bizRes.data as { phone: unknown } | null)?.phone),
      legal_rep_name: onboarding?.legal_rep_name ?? null,
      branches: onboarding?.branches ?? [],
      ecf_types: onboarding?.ecf_types ??
        suggestEcfTypes((seqRes.data ?? []) as Parameters<typeof suggestEcfTypes>[0]),
      ofv_user: onboarding?.ofv_user ?? null,
      ofv_password_saved: !!onboarding?.ofv_password_updated_at,
    },
  });
}

async function actionSubmitRequest(ctx: Ctx): Promise<Response> {
  const { service, businessId, userId, body } = ctx;

  const current = await loadOnboarding(service, businessId);
  const data = validateTaxpayer(body.data ?? {}, { forRegistration: true });
  const contact = validateRequestContact(body);
  const cert = validateCertificate(body.certificate ?? {});
  // POS viejas no mandan `details`: se les sigue aceptando la solicitud.
  const details = body.details
    ? validateRequestDetails(body.details, { hasSavedOfvPassword: !!current?.ofv_password_updated_at })
    : null;
  const errors = [
    ...(data.ok ? [] : data.errors),
    ...(data.ok && details ? missingForClientRequest(data.value) : []),
    ...(details && !details.ok ? details.errors : []),
    ...(contact.ok ? [] : contact.errors),
    ...(cert.ok ? [] : cert.errors),
    ...(body.accept_terms === true ? [] : ["Falta autorizar a MangoPOS a registrar tu certificado."]),
  ];
  if (errors.length > 0 || !data.ok || !contact.ok || (details && !details.ok)) {
    throw new HttpError(422, "invalid_request", errors.join(" "), errors);
  }

  // Sin la llave no se guarda nada: mejor fallar antes que perder la clave o
  // registrar la empresa sin ella.
  const newOfvPassword = details?.value.ofv_password ?? null;
  const ofvKey = newOfvPassword ? await credentialsKeyOrThrow() : null;

  const { data: settings, error: settingsErr } = await service
    .from("business_alanube_settings")
    .select("mode")
    .eq("business_id", businessId)
    .maybeSingle();
  if (settingsErr) throw new HttpError(500, "db_error", "No se pudo leer la activacion", settingsErr.message);
  if (settings && (settings as { mode: string }).mode !== "physical") {
    throw new HttpError(409, "already_active", "Tu negocio ya tiene la facturación electrónica activada.");
  }

  if (current?.alanube_company_id) {
    throw new HttpError(
      409,
      "already_in_progress",
      "Tu solicitud ya está en proceso y tu empresa ya está registrada. MangoPOS te contactará.",
    );
  }

  // La solicitud queda guardada aunque el alta en Alanube falle: MangoPOS la ve
  // en el panel y le da seguimiento.
  const now = new Date().toISOString();
  const d = details?.value ?? null;
  const saved = await upsertOnboarding(service, businessId, userId, current, {
    ...data.value,
    ...contact.value,
    already_authorized: body.already_authorized === true,
    ...(d
      ? {
        phone: d.phone,
        legal_rep_name: d.legal_rep_name,
        branches: d.branches,
        ecf_types: d.ecf_types,
        ofv_user: d.ofv_user,
      }
      : {}),
    ...(newOfvPassword && ofvKey
      ? {
        ofv_password_enc: await sealSecret(ofvKey, newOfvPassword, businessId),
        ofv_password_updated_at: now,
      }
      : {}),
    // Un reintento (contraseña equivocada, por ejemplo) no cambia quien ni
    // cuando lo pidio.
    ...(current?.requested_at ? {} : { requested_at: now, requested_by: userId }),
  } as OnboardingWrite);
  await audit(service, userId, businessId, "submit_request", {
    already_authorized: body.already_authorized === true,
    contact_name: contact.value.contact_name,
    certificate_file: body.certificate?.filename ?? null,
    legal_rep_name: d?.legal_rep_name ?? null,
    ecf_types: d?.ecf_types ?? null,
    branches: d?.branches.length ?? null,
    ofv_password_changed: !!newOfvPassword,
  });

  try {
    await registerCompany(ctx, saved);
    return jsonResponse({ ok: true, company_registered: true, stage: "certification" });
  } catch (e) {
    if (!(e instanceof HttpError)) throw e;
    if (e.code === "company_exists") {
      // Ya registrada (otro intento o un operador): se vincula desde el panel.
      return jsonResponse({
        ok: true,
        company_registered: false,
        stage: "company",
        message: "Tu RNC ya estaba registrado con nuestro proveedor. MangoPOS lo revisa y te contacta.",
      });
    }
    if (e.code === "alanube_rejected") {
      // Casi siempre: contraseña equivocada o un archivo que no es el
      // certificado de firma. El detalle tecnico va aparte, no en el mensaje.
      throw new HttpError(
        422,
        "certificate_rejected",
        "No se pudo registrar tu certificado. Revisa que sea tu certificado de firma digital (.p12) " +
          "y que la contraseña sea la correcta. Tu solicitud quedó guardada.",
        { cause: e.message },
      );
    }
    throw e;
  }
}

async function actionRevealOfvPassword(ctx: Ctx): Promise<Response> {
  const { service, businessId, userId } = ctx;
  const { data, error } = await service
    .from("ecf_onboarding")
    .select("ofv_user, ofv_password_enc")
    .eq("business_id", businessId)
    .maybeSingle();
  if (error) throw new HttpError(500, "db_error", "No se pudo leer la solicitud", error.message);
  const row = data as { ofv_user: string | null; ofv_password_enc: string | null } | null;
  if (!row?.ofv_password_enc) {
    throw new HttpError(404, "not_found", "El cliente no ha enviado la clave de la Oficina Virtual.");
  }

  const key = await credentialsKeyOrThrow();
  let password: string;
  try {
    password = await openSecret(key, row.ofv_password_enc, businessId);
  } catch {
    throw new HttpError(
      500,
      "decrypt_failed",
      "No se pudo descifrar la clave. ¿Cambio ECF_CREDENTIALS_KEY? Pidele al cliente que la envie de nuevo.",
    );
  }

  // Ver una clave del cliente siempre deja rastro.
  if (!(await audit(service, userId, businessId, "reveal_ofv_password", {}))) {
    throw new HttpError(500, "audit_failed", "No se pudo registrar la consulta; la clave no se muestra.");
  }
  return jsonResponse({ ofv_user: row.ofv_user, ofv_password: password });
}

async function actionListRequests(service: SupabaseClient): Promise<Response> {
  const { data, error } = await service
    .from("ecf_onboarding")
    .select(
      "business_id, rnc, legal_name, requested_at, contact_name, contact_phone, already_authorized, " +
        "alanube_company_id, dgii_authorized_at",
    )
    .not("requested_at", "is", null)
    .order("requested_at", { ascending: false })
    .limit(200);
  if (error) throw new HttpError(500, "db_error", "No se pudieron leer las solicitudes", error.message);

  const rows = (data ?? []) as unknown as Array<{
    business_id: string;
    rnc: string | null;
    legal_name: string | null;
    requested_at: string;
    contact_name: string | null;
    contact_phone: string | null;
    already_authorized: boolean | null;
    alanube_company_id: string | null;
    dgii_authorized_at: string | null;
  }>;
  if (rows.length === 0) return jsonResponse({ requests: [] });

  const ids = rows.map((r) => r.business_id);
  const [bizRes, settingsRes, fsRes, seqRes] = await Promise.all([
    service.from("businesses").select("id, business_name").in("id", ids),
    service.from("business_alanube_settings").select("business_id, alanube_company_id, mode").in("business_id", ids),
    service.from("fiscal_settings").select("business_id, ecf_enabled").in("business_id", ids),
    service
      .from("ncf_sequences")
      .select("business_id, ncf_type, range_end, current_number, expiration_date, is_active")
      .in("business_id", ids),
  ]);
  for (const r of [bizRes, settingsRes, fsRes, seqRes]) {
    if (r.error) throw new HttpError(500, "db_error", "No se pudieron leer las solicitudes", r.error.message);
  }

  const names = new Map((bizRes.data ?? []).map((b: { id: string; business_name: string }) => [b.id, b.business_name]));
  const settingsBy = new Map(
    (settingsRes.data ?? []).map((s: { business_id: string; alanube_company_id: string; mode: string }) => [s.business_id, s]),
  );
  const ecfBy = new Map(
    (fsRes.data ?? []).map((f: { business_id: string; ecf_enabled: boolean | null }) => [f.business_id, f.ecf_enabled === true]),
  );
  const seqBy = new Map<string, Parameters<typeof hasUsableEcfSequence>[0]>();
  for (const q of (seqRes.data ?? []) as Array<Parameters<typeof hasUsableEcfSequence>[0][number] & { business_id: string }>) {
    const list = seqBy.get(q.business_id) ?? [];
    list.push(q);
    seqBy.set(q.business_id, list);
  }
  const today = todayInSantoDomingo();

  return jsonResponse({
    requests: rows.map((r) => {
      const settings = settingsBy.get(r.business_id);
      return {
        business_id: r.business_id,
        business_name: names.get(r.business_id) ?? null,
        rnc: r.rnc,
        legal_name: r.legal_name,
        requested_at: r.requested_at,
        contact_name: r.contact_name,
        contact_phone: r.contact_phone,
        already_authorized: r.already_authorized,
        stage: requestStage({
          requested: true,
          hasCompany: !!(r.alanube_company_id || settings?.alanube_company_id),
          dgiiAuthorized: !!r.dgii_authorized_at,
          usableSequences: hasUsableEcfSequence(seqBy.get(r.business_id) ?? [], today),
          provisioned: !!settings && settings.mode !== "physical",
          ecfEnabled: ecfBy.get(r.business_id) === true,
        }),
      };
    }),
  });
}

// ── Helpers ──────────────────────────────────────────────────────────────

class HttpError extends Error {
  constructor(
    public status: number,
    public code: string,
    message: string,
    public detail?: unknown,
  ) {
    super(message);
  }
}

function str(v: unknown): string | null {
  return typeof v === "string" && v.trim().length > 0 ? v.trim() : null;
}

let credentialsKey: Promise<CryptoKey> | null = null;

function credentialsKeyOrThrow(): Promise<CryptoKey> {
  const raw = Deno.env.get("ECF_CREDENTIALS_KEY");
  if (!raw) {
    throw new HttpError(
      500,
      "config_error",
      "El servidor no tiene ECF_CREDENTIALS_KEY para guardar la clave de la Oficina Virtual.",
    );
  }
  credentialsKey ??= importSecretKey(raw).catch((e) => {
    credentialsKey = null;
    throw new HttpError(500, "config_error", `ECF_CREDENTIALS_KEY invalida: ${e instanceof Error ? e.message : e}`);
  });
  return credentialsKey;
}

function alanubeOrThrow(): AlanubeClient {
  try {
    return createAlanubeClient();
  } catch (e) {
    throw new HttpError(
      500,
      "config_error",
      "El servidor no tiene configurado Alanube (ALANUBE_BASE_URL / ALANUBE_JWT).",
      e instanceof Error ? e.message : String(e),
    );
  }
}

/** Algunas respuestas de Alanube envuelven la empresa en `company`. */
function unwrapCompany(body: unknown): AssociatedCompany & Record<string, unknown> {
  const b = (body ?? {}) as Record<string, unknown>;
  const inner = b.company;
  return (inner && typeof inner === "object" ? inner : b) as AssociatedCompany & Record<string, unknown>;
}

async function getCompany(alanube: AlanubeClient, id: string) {
  // OJO: /companies/{id}. `GET /companies` a secas devuelve siempre la principal.
  const res = await alanube.request<unknown>({
    method: "GET",
    path: `/companies/${encodeURIComponent(id)}`,
  });
  return unwrapCompany(res);
}

/** ULID de la empresa del negocio (borrador o activacion previa), o 409. */
async function requireCompanyId(service: SupabaseClient, businessId: string): Promise<string> {
  const onboarding = await loadOnboarding(service, businessId);
  if (onboarding?.alanube_company_id) return onboarding.alanube_company_id;
  const { data, error } = await service
    .from("business_alanube_settings")
    .select("alanube_company_id")
    .eq("business_id", businessId)
    .maybeSingle();
  if (error) throw new HttpError(500, "db_error", "No se pudo leer la activacion", error.message);
  const id = (data as { alanube_company_id: string } | null)?.alanube_company_id;
  if (!id) throw new HttpError(409, "no_company", "Primero vincula o da de alta la empresa en Alanube.");
  return id;
}

async function listAssociated(alanube: AlanubeClient): Promise<AssociatedCompany[]> {
  const all: AssociatedCompany[] = [];
  let from: string | null = null;
  for (let page = 0; page < ASSOCIATED_MAX_PAGES; page++) {
    const query = `limit=${ASSOCIATED_PAGE_SIZE}` + (from ? `&from=${encodeURIComponent(from)}` : "");
    let res: unknown;
    try {
      res = await alanube.request<unknown>({ method: "GET", path: `/companies/associated?${query}` });
    } catch (e) {
      throw new HttpError(502, "alanube_error", describeAlanubeError(e, "listar las empresas asociadas"));
    }
    const { companies, next } = parseAssociatedPage(res);
    all.push(...companies);
    if (!next) return all;
    from = next;
  }
  return all;
}

function describeAlanubeError(e: unknown, what: string): string {
  if (e instanceof HttpError) return e.message;
  if (!(e instanceof AlanubeError)) return `No se pudo ${what}: ${e instanceof Error ? e.message : String(e)}`;
  if (e.status === 0) return `No se pudo ${what}: Alanube no respondio (${e.message}).`;
  const b = e.body as { message?: unknown; errors?: unknown; code?: unknown } | null;
  const detail = b?.message ?? b?.errors;
  const text = Array.isArray(detail) ? detail.join("; ") : typeof detail === "string" ? detail : "";
  const code = typeof b?.code === "string" ? ` ${b.code}` : "";
  return `Alanube respondio ${e.status}${code} al ${what}${text ? `: ${text}` : "."}`;
}

async function loadOnboarding(service: SupabaseClient, businessId: string): Promise<OnboardingRow | null> {
  const { data, error } = await service
    .from("ecf_onboarding")
    .select(ONBOARDING_COLUMNS)
    .eq("business_id", businessId)
    .maybeSingle();
  if (error) {
    if (error.code === "42P01" || error.code === "PGRST205") {
      throw new HttpError(
        500,
        "migration_missing",
        "Falta aplicar la migracion 20260917_0002_ecf_onboarding.sql.",
      );
    }
    if (error.code === "42703") {
      throw new HttpError(
        500,
        "migration_missing",
        "Faltan migraciones de ecf_onboarding (20260917_0003, 20260917_0006, 20261008_0001, 20261008_0003, 20261009_0002 y/o 20261009_0003).",
      );
    }
    throw new HttpError(500, "db_error", "No se pudo leer el alta e-CF", error.message);
  }
  return data as unknown as OnboardingRow | null;
}

/** Lo que se escribe: la fila mas la clave cifrada, que nunca se lee de vuelta. */
type OnboardingWrite = Partial<OnboardingRow> & { ofv_password_enc?: string };

async function upsertOnboarding(
  service: SupabaseClient,
  businessId: string,
  userId: string,
  current: OnboardingRow | null,
  patch: OnboardingWrite,
): Promise<OnboardingRow> {
  const write = current
    ? service
      .from("ecf_onboarding")
      .update({ ...patch, updated_by: userId })
      .eq("business_id", businessId)
    : service
      .from("ecf_onboarding")
      .insert({ ...patch, business_id: businessId, created_by: userId, updated_by: userId });
  const { data, error } = await write.select(ONBOARDING_COLUMNS).single();
  if (error) {
    if (error.code === "23505") {
      throw new HttpError(409, "company_already_assigned", "Esa empresa de Alanube ya es de otro negocio.");
    }
    throw new HttpError(500, "db_error", "No se pudo guardar el alta e-CF", error.message);
  }
  return data as unknown as OnboardingRow;
}

/**
 * Con una empresa ya vinculada (en el borrador o activada antes del panel), el
 * RNC no puede ser otro que el de esa empresa en Alanube: sus comprobantes se
 * firman con ese certificado.
 */
async function assertRncMatchesLinkedCompany(
  service: SupabaseClient,
  businessId: string,
  current: OnboardingRow | null,
  rnc: string | null,
): Promise<void> {
  if (current?.alanube_company_id && current.rnc && normalizeRnc(current.rnc) === normalizeRnc(rnc)) {
    return;
  }
  let companyId = current?.alanube_company_id ?? null;
  if (!companyId) {
    const { data, error } = await service
      .from("business_alanube_settings")
      .select("alanube_company_id")
      .eq("business_id", businessId)
      .maybeSingle();
    if (error) throw new HttpError(500, "db_error", "No se pudo leer la activacion", error.message);
    companyId = (data as { alanube_company_id: string } | null)?.alanube_company_id ?? null;
  }
  if (!companyId) return;

  let company: AssociatedCompany;
  try {
    company = await getCompany(alanubeOrThrow(), companyId);
  } catch (e) {
    throw new HttpError(
      502,
      "alanube_error",
      `No se pudo confirmar el RNC contra la empresa vinculada: ${describeAlanubeError(e, "consultar la empresa")}`,
    );
  }
  if (normalizeRnc(company.identification) !== normalizeRnc(rnc)) {
    throw new HttpError(
      409,
      "rnc_locked",
      `Este negocio esta vinculado a la empresa de Alanube con RNC ${company.identification ?? "(sin RNC)"}. ` +
        `No se puede poner otro RNC.`,
    );
  }
}

async function resolveRnc(service: SupabaseClient, businessId: string): Promise<string | null> {
  const onboarding = await loadOnboarding(service, businessId);
  if (onboarding?.rnc) return onboarding.rnc;
  const { data } = await service
    .from("fiscal_settings")
    .select("rnc")
    .eq("business_id", businessId)
    .maybeSingle();
  const rnc = normalizeRnc((data as { rnc: string | null } | null)?.rnc);
  return rnc.length > 0 ? rnc : null;
}

/** ULID → business_id que ya lo usa, mirando las dos tablas que lo guardan. */
async function assignedBusinesses(service: SupabaseClient, ids: string[]): Promise<Map<string, string>> {
  const out = new Map<string, string>();
  if (ids.length === 0) return out;
  const [a, b] = await Promise.all([
    service.from("business_alanube_settings").select("business_id, alanube_company_id").in("alanube_company_id", ids),
    service.from("ecf_onboarding").select("business_id, alanube_company_id").in("alanube_company_id", ids),
  ]);
  for (const r of [a, b]) {
    if (r.error) throw new HttpError(500, "db_error", "No se pudo verificar la empresa", r.error.message);
    for (const row of (r.data ?? []) as Array<{ business_id: string; alanube_company_id: string }>) {
      out.set(row.alanube_company_id, row.business_id);
    }
  }
  return out;
}

/** Best-effort: una falla de auditoria no deshace el paso ya hecho. Devuelve si
 *  quedo registrada. */
async function audit(
  service: SupabaseClient,
  userId: string,
  businessId: string,
  action: string,
  payload: unknown,
): Promise<boolean> {
  const { error } = await service.from("noc_audit_log").insert({
    user_id: userId,
    action: `ecf.onboarding.${action}`,
    target_resource: "ecf_onboarding",
    target_id: businessId,
    business_id: businessId,
    payload,
  });
  if (error) console.error(`ecf-onboarding: auditoria ${action} fallo:`, error.message);
  return !error;
}
