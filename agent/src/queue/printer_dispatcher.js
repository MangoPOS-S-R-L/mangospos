// Sprint 4 — Dispatcher concurrente por impresora.
//
// PROBLEMA:
//   El worker secuencial procesaba 1 job a la vez. Friday-night, si caían
//   5 tickets de cocina simultáneos para 2 impresoras distintas (caliente
//   y bar), el 5to esperaba ~25s aunque la bar printer estuviera ociosa.
//
// SOLUCIÓN:
//   Una cola en memoria POR impresora. El worker claim varios jobs de
//   la nube por tick y los DESPACHA a la cola correspondiente. Cada cola
//   corre serialmente (ESC/POS no tolera 2 sockets simultáneos al mismo
//   dispositivo), pero las colas distintas corren en paralelo.
//
// LÍMITES:
//   - MAX_CONCURRENT_PRINTERS: tope global de impresoras activas
//     simultáneamente. Default 8 — más que eso típicamente significa
//     que algo está stuck.
//   - QUEUE_TTL_MS: una cola sin actividad > 5min se borra del Map
//     para no leakear memoria.
//
// IDEMPOTENCIA:
//   Si el mismo job llega 2 veces al dispatcher (race en claim), la BD
//   ya garantiza que solo el primer claim devolvió el row. Aquí no
//   re-validamos — confiamos en fn_claim_next_print_job (SKIP LOCKED).

const { logger } = require('../config');
const { processPrintJob } = require('../print/job_processor');
const cloudStore = require('./cloud_store');

const MAX_CONCURRENT_PRINTERS = 8;
const QUEUE_TTL_MS = 5 * 60 * 1000;

// Map<printerKey, { busy, queue: [{ job, printerCfg }], lastActiveAt, runner }>
const queues = new Map();

let cleanupTimer = null;

/**
 * Clave estable para identificar una impresora física.
 * - Si el job apunta a un printer_id (UUID en BD), usar eso.
 * - Si solo trae ip+port (modo legacy / network directo), usar ip:port.
 * - Si no trae nada, usar un fallback único — el job se procesará serial
 *   pero al menos no romperá el dispatcher.
 */
const printerKeyFor = (job, printerCfg) => {
    if (job && job.printer_id) return `id:${job.printer_id}`;
    if (printerCfg) {
        if (printerCfg.device_path) return `path:${printerCfg.device_path}`;
        if (printerCfg.mac) return `mac:${printerCfg.mac}`;
        if (printerCfg.ip) {
            return `net:${printerCfg.ip}:${printerCfg.port || 9100}`;
        }
    }
    return 'unknown';
};

/**
 * Loop interno que vacía la cola de UNA impresora. Corre hasta que la
 * cola esté vacía. Cuando termina, marca busy=false y queda esperando
 * que dispatch() lo re-arranque si llega otro job.
 *
 * Si processPrintJob falla, llamamos cloudStore.complete(false) para que
 * la BD aplique backoff/failover. Si tiene éxito, complete(true). No
 * lanzamos excepciones afuera — el runner siempre termina limpiamente.
 */
const runPrinterQueue = async (key) => {
    const pq = queues.get(key);
    if (!pq) return;

    while (pq.queue.length > 0) {
        const { job, printerCfg } = pq.queue.shift();
        const jobId = job.id;
        pq.lastActiveAt = Date.now();

        const internalJob = {
            id: jobId,
            printer: printerCfg,
            content: { type: 'raw_hex', dataHex: job.data_hex },
        };

        try {
            await processPrintJob(internalJob);
            await cloudStore.complete(jobId, true);
            logger.info(`[dispatcher:${key}] done ${jobId}`);
        } catch (err) {
            const msg = err && err.message ? err.message : String(err);
            await cloudStore.complete(jobId, false, msg);
            logger.error(`[dispatcher:${key}] failed ${jobId}: ${msg}`);
        }
    }

    pq.busy = false;
    pq.lastActiveAt = Date.now();
};

/**
 * Encola un job para una impresora. Si la cola estaba ociosa, arranca
 * runPrinterQueue (no-await, dejamos correr en background). Si ya está
 * corriendo, el runner verá el nuevo item al loopear.
 *
 * @returns {boolean} true si se aceptó el dispatch, false si se rechazó
 *   por exceder MAX_CONCURRENT_PRINTERS (el caller debe re-encolar el
 *   job o esperar al próximo tick).
 */
const dispatch = (job, printerCfg) => {
    const key = printerKeyFor(job, printerCfg);
    let pq = queues.get(key);

    if (!pq) {
        // Nueva impresora — chequear tope de concurrencia global.
        const activeCount = Array.from(queues.values()).filter((q) => q.busy).length;
        if (activeCount >= MAX_CONCURRENT_PRINTERS) {
            logger.warn(
                `[dispatcher] tope MAX_CONCURRENT_PRINTERS=${MAX_CONCURRENT_PRINTERS} ` +
                `alcanzado; job ${job.id} rechazado, BD lo reasigna en próximo tick`,
            );
            return false;
        }
        pq = {
            busy: false,
            queue: [],
            lastActiveAt: Date.now(),
        };
        queues.set(key, pq);
    }

    pq.queue.push({ job, printerCfg });
    pq.lastActiveAt = Date.now();

    if (!pq.busy) {
        pq.busy = true;
        // Fire-and-forget. Errores ya capturados dentro de runPrinterQueue.
        runPrinterQueue(key).catch((err) => {
            logger.error(
                `[dispatcher:${key}] runner crasheó (no deberia): ${err.message}`,
            );
            pq.busy = false;
        });
    }
    return true;
};

/**
 * Limpia entradas de impresoras inactivas (sin jobs hace > QUEUE_TTL_MS).
 * Liberamos memoria sin afectar correctness — si llega un job nuevo para
 * esa impresora, dispatch() la re-crea.
 */
const cleanup = () => {
    const cutoff = Date.now() - QUEUE_TTL_MS;
    let removed = 0;
    for (const [key, pq] of queues.entries()) {
        if (!pq.busy && pq.queue.length === 0 && pq.lastActiveAt < cutoff) {
            queues.delete(key);
            removed++;
        }
    }
    if (removed > 0) {
        logger.debug(`[dispatcher] cleanup: ${removed} cola(s) inactivas removidas`);
    }
};

/**
 * Snapshot del estado del dispatcher. Útil para diagnóstico vía HTTP
 * /status del agent.
 */
const stats = () => {
    let active = 0;
    let pending = 0;
    const printers = [];
    for (const [key, pq] of queues.entries()) {
        if (pq.busy) active++;
        pending += pq.queue.length;
        printers.push({
            key,
            busy: pq.busy,
            queueLength: pq.queue.length,
            lastActiveAt: new Date(pq.lastActiveAt).toISOString(),
        });
    }
    return {
        activePrinters: active,
        queuedJobs: pending,
        knownPrinters: queues.size,
        max: MAX_CONCURRENT_PRINTERS,
        printers,
    };
};

/**
 * Total de jobs en cola (memoria) + impresoras activas. Sirve para que
 * el tick del worker sepa si conviene esperar (todas las colas saturadas)
 * o seguir claiming.
 */
const inFlightCount = () => {
    let count = 0;
    for (const pq of queues.values()) {
        if (pq.busy) count++;
    }
    return count;
};

const start = () => {
    if (cleanupTimer) return;
    cleanupTimer = setInterval(cleanup, QUEUE_TTL_MS);
    logger.info('[dispatcher] Iniciado.');
};

const stop = async () => {
    if (cleanupTimer) {
        clearInterval(cleanupTimer);
        cleanupTimer = null;
    }
    // Esperar a que todas las colas drenen. Max 10s para no bloquear
    // shutdown si una impresora cuelga.
    const deadline = Date.now() + 10_000;
    while (inFlightCount() > 0 && Date.now() < deadline) {
        await new Promise((r) => setTimeout(r, 100));
    }
    if (inFlightCount() > 0) {
        logger.warn(
            `[dispatcher] stop: ${inFlightCount()} impresora(s) aún activas tras 10s, ` +
            'forzando salida (jobs serán reclamados por reclaimStale)',
        );
    }
};

module.exports = {
    dispatch,
    stats,
    inFlightCount,
    start,
    stop,
    MAX_CONCURRENT_PRINTERS,
};
