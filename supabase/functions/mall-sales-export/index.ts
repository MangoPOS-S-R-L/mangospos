// mall-sales-export — envío diario del acumulado de ventas por hora al SFTP
// de la plaza comercial (formato Ágora Santiago Center, manual §6.6).
//
// POST /functions/v1/mall-sales-export
// Auth: Bearer <SUPABASE_SERVICE_ROLE_KEY> (server-to-server, la invoca el cron).
// Body (todo opcional):
//   { business_id?: uuid, date?: "YYYY-MM-DD", force?: boolean }
//
// POR QUÉ EXISTE (2026-08-16): el envío vivía SOLO en el hook de cierre de caja
// de la app, con dos consecuencias verificadas contra el SFTP real:
//   1. `sendOnCashClose` usaba `DateTime.now()`, así que un cierre después de
//      medianoche subía el archivo del día NUEVO y dejaba el anterior congelado
//      en el último cierre de la tarde. El 14 y 15-ago se reportó ~1/3 de la
//      venta real (faltaban las horas 18-23, que son ~65% del día).
//   2. El archivo salía con el formato del build instalado en la tablet, así que
//      la corrección BRUTO/NETO del 13-ago no llegó a la plaza.
// Moviendo el envío al servidor los dos desaparecen: corre siempre a la misma
// hora aunque la tablet esté apagada, y el formato es el del servidor.
//
// MODO CRON (sin body): recorre las configs habilitadas y sube el DÍA ANTERIOR
// en hora local del negocio, una vez pasada RUN_AFTER_LOCAL_HOUR. Es idempotente
// contra `mall_sales_export_log`: si ese día ya se subió OK, no repite. Como el
// cron corre cada hora, un fallo de red reintenta solo en la siguiente vuelta.
//
// MODO MANUAL (business_id + date): sube ese día concreto, sin importar la hora
// ni si ya se había enviado. Sirve para backfills.

import SftpClient from "npm:ssh2-sftp-client@11.0.0";
import { Buffer } from "node:buffer";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.7";
import { corsPreflight, errorResponse, jsonResponse } from "../_shared/responses.ts";
import { buildCsv, buildFileName, type MallHourlyRow } from "./csv.ts";

/**
 * Hora local por defecto a partir de la cual el día anterior se considera
 * cerrable. Cada negocio puede cambiarla desde la app (`send_hour_local`);
 * esto solo aplica si la columna no existe todavía o viene nula.
 */
const DEFAULT_SEND_HOUR_LOCAL = 1;

/** Techo por operación SFTP; el cron reintenta en la vuelta siguiente. */
const SFTP_TIMEOUT_MS = 45_000;

const DEFAULT_TZ = "America/Santo_Domingo";

interface RequestBody {
  business_id?: string;
  date?: string;
  force?: boolean;
}

interface ExportConfigRow {
  business_id: string;
  enabled: boolean;
  host: string;
  port: number;
  username: string;
  password: string;
  remote_dir: string;
  client_code: string;
  file_prefix: string;
  exchange_rate: number | string;
  /** Hora local (0-23) del envío diario. Puede faltar si no se aplicó 0002. */
  send_hour_local?: number | string | null;
}

function isUuid(s: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(s);
}

function isIsoDate(s: string): boolean {
  return /^\d{4}-\d{2}-\d{2}$/.test(s);
}

function toNumber(v: unknown): number {
  if (typeof v === "number") return v;
  const n = Number(v);
  return Number.isFinite(n) ? n : 0;
}

/**
 * Fecha y hora locales del negocio. La RPC ya resuelve el día en la TZ del
 * negocio; acá solo necesitamos saber QUÉ día pedirle y si ya pasó la hora
 * de corte. Si la TZ es inválida cae a Santo Domingo (UTC-4, sin horario de
 * verano), que es donde están todos los negocios con esto activo.
 */
function localParts(tz: string, at: Date): { date: string; hour: number } {
  try {
    const fmt = new Intl.DateTimeFormat("en-CA", {
      timeZone: tz,
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
      hour: "2-digit",
      hourCycle: "h23",
    });
    const p: Record<string, string> = {};
    for (const part of fmt.formatToParts(at)) {
      if (part.type !== "literal") p[part.type] = part.value;
    }
    return { date: `${p.year}-${p.month}-${p.day}`, hour: Number(p.hour) };
  } catch {
    const shifted = new Date(at.getTime() - 4 * 3600_000);
    return {
      date: shifted.toISOString().slice(0, 10),
      hour: shifted.getUTCHours(),
    };
  }
}

function addDaysIso(dateIso: string, days: number): string {
  const d = new Date(`${dateIso}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + days);
  return d.toISOString().slice(0, 10);
}

function withTimeout<T>(p: Promise<T>, ms: number, label: string): Promise<T> {
  return Promise.race([
    p,
    new Promise<T>((_, reject) =>
      setTimeout(() => reject(new Error(`Tiempo de espera agotado ${label}.`)), ms)
    ),
  ]);
}

function normalizedDir(remoteDir: string): string {
  let dir = (remoteDir ?? "").trim();
  if (dir === "") return "/";
  if (dir.length > 1 && dir.endsWith("/")) dir = dir.slice(0, -1);
  return dir;
}

function friendlyError(e: unknown): string {
  const msg = e instanceof Error ? e.message : String(e);
  if (/All configured authentication methods failed|authentication/i.test(msg)) {
    return "Autenticación rechazada: verifica usuario y contraseña.";
  }
  if (/ENOTFOUND|EAI_AGAIN|getaddrinfo/i.test(msg)) {
    return `No se pudo resolver el host del servidor SFTP. (${msg})`;
  }
  if (/ECONNREFUSED|ETIMEDOUT|EHOSTUNREACH|Tiempo de espera/i.test(msg)) {
    return `No se pudo conectar al servidor SFTP. (${msg})`;
  }
  return msg;
}

/** Sube el contenido sobrescribiendo el archivo remoto por completo. */
async function upload(
  config: ExportConfigRow,
  fileName: string,
  content: string,
): Promise<number> {
  const sftp = new SftpClient();
  const bytes = Buffer.from(content, "utf8");
  try {
    await withTimeout(
      sftp.connect({
        host: config.host.trim(),
        port: config.port ?? 22,
        username: config.username.trim(),
        password: config.password,
        readyTimeout: 20_000,
      }),
      SFTP_TIMEOUT_MS,
      `conectando a ${config.host}`,
    );
    const dir = normalizedDir(config.remote_dir);
    const path = dir === "/" ? `/${fileName}` : `${dir}/${fileName}`;
    await withTimeout(
      sftp.put(bytes, path),
      SFTP_TIMEOUT_MS,
      `subiendo ${fileName}`,
    );
    return bytes.length;
  } finally {
    try {
      await sftp.end();
    } catch {
      // el cierre no debe tapar el error real de arriba
    }
  }
}

Deno.serve(async (req) => {
  const pre = corsPreflight(req);
  if (pre) return pre;
  if (req.method !== "POST") {
    return errorResponse(405, "method_not_allowed", "Usa POST.");
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceKey) {
    return errorResponse(
      500,
      "missing_env",
      "Faltan SUPABASE_URL o SUPABASE_SERVICE_ROLE_KEY en el runtime.",
    );
  }

  // Server-to-server: solo el service_role puede invocarla (la config trae
  // credenciales SFTP en claro).
  if (req.headers.get("Authorization") !== `Bearer ${serviceKey}`) {
    return errorResponse(401, "unauthorized", "Se requiere el service_role.");
  }

  let body: RequestBody = {};
  try {
    const raw = await req.text();
    if (raw.trim() !== "") body = JSON.parse(raw) as RequestBody;
  } catch {
    return errorResponse(400, "bad_json", "Body inválido.");
  }
  if (body.business_id && !isUuid(body.business_id)) {
    return errorResponse(400, "bad_business_id", "business_id no es un uuid.");
  }
  if (body.date && !isIsoDate(body.date)) {
    return errorResponse(400, "bad_date", "date debe ser YYYY-MM-DD.");
  }

  const manual = Boolean(body.date);
  const force = body.force === true || manual;

  const sb = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  // `*` a propósito: si la function se despliega antes que la migración que
  // agrega `send_hour_local`, una lista explícita rompería con "column does not
  // exist". Con `*` simplemente llega lo que haya y se cae al default.
  let query = sb
    .from("business_sales_export_config")
    .select("*")
    .eq("enabled", true);
  if (body.business_id) query = query.eq("business_id", body.business_id);

  const { data: configs, error: configErr } = await query;
  if (configErr) {
    return errorResponse(500, "config_read_failed", configErr.message);
  }

  const now = new Date();
  const results: Array<Record<string, unknown>> = [];

  for (const config of (configs ?? []) as unknown as ExportConfigRow[]) {
    const businessId = config.business_id;
    const incomplete = config.host?.trim() === "" ||
      config.username?.trim() === "" ||
      (config.password ?? "") === "";
    if (incomplete) {
      results.push({ business_id: businessId, skipped: "config_incompleta" });
      continue;
    }

    // La TZ del negocio decide qué día toca; la RPC usa la misma fuente.
    const { data: settings } = await sb
      .from("business_settings")
      .select("timezone")
      .eq("business_id", businessId)
      .maybeSingle();
    const tz = (settings?.timezone as string | null)?.trim() || DEFAULT_TZ;
    const local = localParts(tz, now);

    let targetDate: string;
    if (body.date) {
      targetDate = body.date;
    } else {
      const rawHour = config.send_hour_local;
      const parsedHour = rawHour === null || rawHour === undefined
        ? NaN
        : Number(rawHour);
      const sendHour = Number.isInteger(parsedHour) &&
          parsedHour >= 0 && parsedHour <= 23
        ? parsedHour
        : DEFAULT_SEND_HOUR_LOCAL;

      if (local.hour < sendHour) {
        results.push({
          business_id: businessId,
          skipped: `aún no son las ${sendHour}:00 locales (${local.hour}:00 en ${tz})`,
        });
        continue;
      }
      targetDate = addDaysIso(local.date, -1);
    }

    // Idempotencia: si ese día ya subió OK, no repetimos. Un fallo previo sí
    // se reintenta, que es lo que hace útil el cron horario.
    if (!force) {
      const { data: done } = await sb
        .from("mall_sales_export_log")
        .select("id")
        .eq("business_id", businessId)
        .eq("file_date", targetDate)
        .eq("ok", true)
        .limit(1);
      if (done && done.length > 0) {
        results.push({
          business_id: businessId,
          file_date: targetDate,
          skipped: "ya enviado",
        });
        continue;
      }
    }

    const fileName = buildFileName(config.file_prefix ?? "Ventas", targetDate);
    let ok = false;
    let errorMsg: string | null = null;
    let bytes = 0;
    let rowCount = 0;

    try {
      const { data: rpcRows, error: rpcErr } = await sb.rpc(
        "fn_mall_sales_by_hour",
        { _business_id: businessId, _date: targetDate },
      );
      if (rpcErr) throw new Error(`fn_mall_sales_by_hour: ${rpcErr.message}`);

      const rows: MallHourlyRow[] = (rpcRows ?? []).map((
        r: Record<string, unknown>,
      ) => ({
        hour: toNumber(r.sale_hour),
        txCount: toNumber(r.tx_count),
        totalItems: toNumber(r.total_items),
        totalGross: toNumber(r.total_gross),
        totalTax: toNumber(r.total_tax),
        totalNet: toNumber(r.total_net),
      }));
      rowCount = rows.length;

      const content = buildCsv({
        config: {
          clientCode: config.client_code ?? "",
          filePrefix: config.file_prefix ?? "Ventas",
          exchangeRate: toNumber(config.exchange_rate) || 1,
        },
        dateIso: targetDate,
        rows,
      });

      bytes = await upload(config, fileName, content);
      ok = true;
    } catch (e) {
      errorMsg = friendlyError(e);
    }

    // La bitácora es append-only: deja ver reintentos y fallos silenciosos,
    // que es justo lo que faltaba cuando el envío vivía en el cierre de caja.
    await sb.from("mall_sales_export_log").insert({
      business_id: businessId,
      file_date: targetDate,
      file_name: fileName,
      bytes,
      row_count: rowCount,
      ok,
      error: errorMsg,
      source: manual ? "manual" : "cron",
    });

    // Espejo en la config para la pantalla de Ajustes de la app.
    await sb
      .from("business_sales_export_config")
      .update(
        ok
          ? { last_sent_at: new Date().toISOString(), last_error: null }
          : { last_error: errorMsg },
      )
      .eq("business_id", businessId);

    results.push({
      business_id: businessId,
      file_date: targetDate,
      file_name: fileName,
      rows: rowCount,
      bytes,
      ok,
      error: errorMsg,
    });
  }

  return jsonResponse({ processed: results.length, results });
});
