// Sprint 1.2 — Adapter para la cola persistente en Supabase.
//
// Reemplaza progresivamente al store SQLite local. El agente sigue
// soportando SQLite (worker fallback) hasta que el frontend migre
// completamente a "escribir directo a Supabase".
//
// Responsabilidades:
//   - claimNext(): wrap de RPC fn_claim_next_print_job. Atomic, SKIP LOCKED.
//   - complete(jobId, success, error): wrap de RPC fn_complete_print_job.
//     Si success → status=printed. Si failure → calcula backoff y deja el
//     job listo para retry o terminal a los 5 intentos.
//   - reclaimStale(): wrap de RPC fn_reclaim_stale_print_jobs(60). Llamar
//     periódicamente para recuperar jobs huérfanos.
//
// Resiliencia:
//   - Si Supabase no responde (sin internet, RLS fallido, server caído),
//     todos los métodos retornan null/false sin lanzar. El worker hace
//     fallback a la cola SQLite local sin interrumpir.

const { createClient } = require('@supabase/supabase-js');
const {
    logger,
    SUPABASE_URL,
    SUPABASE_KEY,
    AGENT_UUID,
    CLOUD_WORKER_ENABLED,
} = require('../config');

let client = null;

const isEnabled = () => CLOUD_WORKER_ENABLED && !!client;

const init = () => {
    if (!CLOUD_WORKER_ENABLED) return false;
    if (client) return true;
    try {
        client = createClient(SUPABASE_URL, SUPABASE_KEY, {
            auth: { persistSession: false, autoRefreshToken: false },
        });
        logger.info(
            `[cloud_store] Inicializado. AGENT_UUID=${AGENT_UUID} URL=${SUPABASE_URL.replace(/^https?:\/\//, '')}`,
        );
        return true;
    } catch (err) {
        logger.error(`[cloud_store] Falló init: ${err.message}`);
        client = null;
        return false;
    }
};

/**
 * Toma el siguiente job procesable para este agent. Atomic via RPC con
 * FOR UPDATE SKIP LOCKED (dos agents concurrentes no toman el mismo job).
 *
 * @returns {object|null} El row de print_jobs claimed, o null si no hay
 *   jobs o si Supabase no responde.
 */
const claimNext = async () => {
    if (!isEnabled()) return null;
    try {
        const { data, error } = await client.rpc('fn_claim_next_print_job', {
            p_agent_id: AGENT_UUID,
        });
        if (error) {
            logger.warn(`[cloud_store] claimNext error: ${error.message}`);
            return null;
        }
        // RPC retorna NULL cuando no hay jobs (la función devuelve setof
        // pero con un solo row o NULL). Supabase JS lo serializa como
        // `null` (singular) o array.
        if (!data) return null;
        if (Array.isArray(data)) return data.length > 0 ? data[0] : null;
        return data;
    } catch (err) {
        logger.warn(`[cloud_store] claimNext excepcion: ${err.message}`);
        return null;
    }
};

/**
 * ACK: marca el job como printed (success) o failed (con backoff
 * exponencial). El backoff lo calcula la BD, el agent solo reporta.
 *
 * @param {string} jobId — UUID del job
 * @param {boolean} success
 * @param {string|null} errorMessage — solo si success=false
 * @returns {boolean} true si la BD aceptó el ACK, false si no.
 */
const complete = async (jobId, success, errorMessage = null) => {
    if (!isEnabled()) return false;
    try {
        const { error } = await client.rpc('fn_complete_print_job', {
            p_job_id: jobId,
            p_success: success,
            p_error: errorMessage,
        });
        if (error) {
            logger.warn(`[cloud_store] complete error: ${error.message}`);
            return false;
        }
        return true;
    } catch (err) {
        logger.warn(`[cloud_store] complete excepcion: ${err.message}`);
        return false;
    }
};

/**
 * Recupera jobs huérfanos: agent crasheó después de claim sin ACK.
 * Llamar cada 60s desde el worker loop.
 *
 * @param {number} maxAgeSeconds — default 60s.
 * @returns {number} cantidad de jobs reclamados, o 0 si error.
 */
const reclaimStale = async (maxAgeSeconds = 60) => {
    if (!isEnabled()) return 0;
    try {
        const { data, error } = await client.rpc(
            'fn_reclaim_stale_print_jobs',
            { p_max_age_seconds: maxAgeSeconds },
        );
        if (error) {
            logger.warn(`[cloud_store] reclaimStale error: ${error.message}`);
            return 0;
        }
        return data || 0;
    } catch (err) {
        logger.warn(`[cloud_store] reclaimStale excepcion: ${err.message}`);
        return 0;
    }
};

/**
 * Convierte un row de print_jobs (formato Supabase) al payload que
 * espera processPrintJob() (formato legacy).
 *
 * El job de Supabase trae:
 *   - id, data_hex, ip, port, printer_id, area_code, kind
 *
 * processPrintJob espera:
 *   - { id, printer: { type, ip, port, name, ... }, content: { type, dataHex } }
 *
 * Para impresoras de red, usamos `ip` y `port` directo del row.
 * Para USB/Bluetooth, necesitamos resolver `printer_id` → printers table.
 * Por ahora la resolución la hace el worker; este helper solo arma el
 * shape básico cuando es network y deja printer_id para casos USB.
 *
 * @param {object} jobRow
 * @returns {object} payload listo para processPrintJob
 */
const buildLegacyJobPayload = (jobRow) => ({
    id: jobRow.id,
    cloudJobId: jobRow.id,
    idempotencyKey: jobRow.idempotency_key,
    kind: jobRow.kind,
    areaCode: jobRow.area_code,
    printerId: jobRow.printer_id,
    printer: {
        type: 'network', // default; el worker resuelve USB en runtime via printerId
        ip: jobRow.ip,
        port: jobRow.port || 9100,
    },
    content: {
        type: 'raw_hex',
        dataHex: jobRow.data_hex,
    },
});

/**
 * Fetch de impresora por id. Necesario cuando el job apunta a USB/BT
 * y el worker tiene que resolver vid/pid o device_path.
 *
 * @param {string} printerId
 * @returns {object|null}
 */
const fetchPrinter = async (printerId) => {
    if (!isEnabled() || !printerId) return null;
    try {
        const { data, error } = await client
            .from('printers')
            .select('*')
            .eq('id', printerId)
            .maybeSingle();
        if (error) {
            logger.warn(`[cloud_store] fetchPrinter error: ${error.message}`);
            return null;
        }
        return data;
    } catch (err) {
        logger.warn(`[cloud_store] fetchPrinter excepcion: ${err.message}`);
        return null;
    }
};

module.exports = {
    init,
    isEnabled,
    claimNext,
    complete,
    reclaimStale,
    fetchPrinter,
    buildLegacyJobPayload,
};
