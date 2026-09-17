// ecf-document-links: enlaces para abrir un comprobante electronico ya emitido
// (consulta en la DGII, PDF y XML firmado).
//
// POST /functions/v1/ecf-document-links
//   { fiscal_document_id: uuid }
//
// Response 200:
//   { ncf_number, ncf_type, ecf_status, legal_status, stamp_url, pdf_url, xml_url }
//
// El PDF y el XML se piden a Alanube en cada llamada porque son enlaces de S3
// que vencen. La URL de consulta DGII no vence: si el documento no la tenia
// guardada (emit-document la buscaba con un nombre de campo equivocado), se
// guarda en `public_url` de paso, para que la reimpresion del ticket la use en
// el QR.
//
// Errores:
//   400 invalid_request   401 unauthorized   403 forbidden   404 not_found
//   409 not_electronic    — comprobante de papel
//   409 not_sent          — nunca llego a Alanube (sin alanube_document_id)
//   409 not_configured    — el negocio no tiene empresa en Alanube
//   502 alanube_error

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import { AlanubeError, createAlanubeClient } from "../_shared/alanube-client.ts";
import { corsPreflight, errorResponse, jsonResponse } from "../_shared/responses.ts";
import { alanubeDocumentPath, parseDocumentLinks } from "../_shared/ecf-documents.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL");
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

interface DocRow {
  id: string;
  business_id: string;
  ncf_type: string;
  ncf_number: string;
  is_electronic: boolean | null;
  alanube_document_id: string | null;
  ecf_status: string | null;
  public_url: string | null;
  last_error: string | null;
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

  let body: { fiscal_document_id?: string };
  try {
    body = await req.json();
  } catch {
    return errorResponse(400, "invalid_request", "El body debe ser JSON");
  }
  const docId = body.fiscal_document_id?.trim() ?? "";
  if (!UUID_RE.test(docId)) {
    return errorResponse(400, "invalid_request", "fiscal_document_id debe ser un UUID");
  }

  const userClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: authHeader } },
  });
  const { data: userData, error: userErr } = await userClient.auth.getUser();
  if (userErr || !userData?.user) {
    return errorResponse(401, "unauthorized", "No se pudo resolver el usuario del JWT");
  }
  const userId = userData.user.id;

  const service = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const { data: docData, error: docErr } = await service
    .from("fiscal_documents")
    .select("id, business_id, ncf_type, ncf_number, is_electronic, alanube_document_id, ecf_status, public_url, last_error")
    .eq("id", docId)
    .maybeSingle();
  if (docErr) return errorResponse(500, "db_error", "No se pudo leer el comprobante", docErr.message);
  if (!docData) return errorResponse(404, "not_found", "El comprobante no existe");
  const doc = docData as DocRow;

  // Mismo criterio que fn_issue_credit_note: acceso al negocio del
  // comprobante. Va con service_role porque el usuario ya viene explicito y
  // asi no depende de que `authenticated` tenga EXECUTE sobre la funcion.
  // El operador de MangoPOS tambien puede verlo.
  const { data: hasAccess, error: accessErr } = await service.rpc("user_has_business_access", {
    _user_id: userId,
    _business_id: doc.business_id,
  });
  if (accessErr) return errorResponse(500, "rpc_error", "No se pudo verificar el acceso", accessErr.message);
  if (hasAccess !== true) {
    const { data: isOperator } = await userClient.rpc("is_platform_operator", { uid: userId });
    if (isOperator !== true) {
      return errorResponse(403, "forbidden", "Sin acceso al negocio de este comprobante");
    }
  }

  if (doc.is_electronic !== true) {
    return errorResponse(409, "not_electronic", "Este comprobante es de papel: no tiene documento electronico.");
  }
  if (!doc.alanube_document_id) {
    return errorResponse(
      409,
      "not_sent",
      "Esta factura electronica todavia no llego a la DGII, asi que no hay documento que abrir.",
      { ecf_status: doc.ecf_status, last_error: doc.last_error },
    );
  }

  const { data: settings, error: settingsErr } = await service
    .from("business_alanube_settings")
    .select("alanube_company_id")
    .eq("business_id", doc.business_id)
    .maybeSingle();
  if (settingsErr) return errorResponse(500, "db_error", "No se pudo leer la configuracion", settingsErr.message);
  const companyId = (settings as { alanube_company_id: string } | null)?.alanube_company_id;
  if (!companyId) {
    return errorResponse(409, "not_configured", "El negocio no tiene su empresa configurada en Alanube.");
  }

  const path = alanubeDocumentPath(doc.ncf_type, doc.alanube_document_id, companyId);
  if (!path) {
    return errorResponse(409, "not_electronic", `El tipo ${doc.ncf_type} no se emite por Alanube.`);
  }

  let links;
  try {
    const alanube = createAlanubeClient();
    links = parseDocumentLinks(await alanube.request<unknown>({ method: "GET", path }));
  } catch (e) {
    const status = e instanceof AlanubeError ? e.status : 0;
    return errorResponse(
      502,
      "alanube_error",
      status === 404
        ? "Alanube no encuentra este documento."
        : `No se pudo consultar el documento en Alanube${status ? ` (${status})` : ""}.`,
    );
  }

  const stampUrl = links.stamp_url ?? doc.public_url;
  if (links.stamp_url && !doc.public_url) {
    const { error: updErr } = await service
      .from("fiscal_documents")
      .update({ public_url: links.stamp_url })
      .eq("id", doc.id)
      .is("public_url", null);
    if (updErr) console.error(`ecf-document-links: no se guardo public_url de ${doc.id}:`, updErr.message);
  }

  return jsonResponse({
    ncf_number: doc.ncf_number,
    ncf_type: doc.ncf_type,
    ecf_status: doc.ecf_status,
    legal_status: links.legal_status,
    stamp_url: stampUrl,
    pdf_url: links.pdf_url,
    xml_url: links.xml_url,
  });
});
