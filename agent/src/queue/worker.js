// Worker de la cola — Sprint 4: dispatch concurrente por impresora.
//
// HISTORIAL:
//   - Sprint 1.2 (legado, ahora reemplazado en cloud): worker secuencial
//     que procesaba 1 job a la vez. 5 tickets simultáneos para 2
//     impresoras = ~25s de cola aunque la 2da impresora estuviera
//     ociosa.
//   - Sprint 4: para CLOUD jobs el worker claim varios jobs por tick
//     (MAX_CLAIM_PER_TICK) y los DESPACHA al `printer_dispatcher`, que
//     mantiene una cola POR impresora. Cada impresora corre serial
//     (ESC/POS no tolera 2 sockets simultáneos), pero las impresoras
//     distintas corren en paralelo.
//   - SQLITE fallback sigue siendo serial (legacy, bajo volumen).
//
// FUENTES (en orden de prioridad):
//
//   1. CLOUD QUEUE (Supabase print_jobs vía fn_claim_next_print_job)
//      — fuente de verdad cuando CLOUD_WORKER_ENABLED y haya conexión.
//      Cada tick claim hasta MAX_CLAIM_PER_TICK jobs y los dispatch al
//      printer_dispatcher (paralelo por impresora).
//
//   2. SQLITE LOCAL (queue/store.js)
//      — legacy / fallback secuencial. Cubre:
//        a) CLOUD_WORKER_ENABLED=false (rollout gradual: agent corriendo
//           viejo, frontend aún POST a /print).
//        b) Supabase no responde (offline temporario): el job ya entró
//           via HTTP /print (que también escribe SQLite local).
//
// Reclaim stale: cada RECLAIM_INTERVAL_MS llamamos fn_reclaim_stale_print_jobs
// para recuperar jobs en 'printing' con claim viejo (>60s sin ACK).

const { logger, CLOUD_WORKER_ENABLED } = require('../config');
const sqliteQueue = require('./store');
const cloudStore = require('./cloud_store');
const printerDispatcher = require('./printer_dispatcher');
const { processPrintJob } = require('../print/job_processor');

const POLL_INTERVAL_MS = 500;
const PRUNE_INTERVAL_MS = 60 * 60 * 1000; // 1h
const RECLAIM_INTERVAL_MS = 60 * 1000; // 60s

// Sprint 4 — cuántos jobs claimar por tick. Más alto = más throughput
// inicial pero más jobs marcados 'printing' simultáneamente si el
// agent crashea. 5 es balance razonable para LANs con varias
// impresoras.
const MAX_CLAIM_PER_TICK = 5;

let running = false;
let stopRequested = false;
let pruneTimer = null;
let reclaimTimer = null;

/**
 * Resuelve la config completa de la impresora destino de un job.
 *
 * Si el job apunta a un printer_id (UUID en BD), consulta `printers`
 * para traer vid/pid/device_path/encoding. Para network sin printer_id,
 * arma config básica con ip+port del row.
 */
const resolvePrinterCfg = async (jobRow) => {
    let printerCfg = {
        type: 'network',
        ip: jobRow.ip,
        port: jobRow.port || 9100,
    };
    if (jobRow.printer_id) {
        const fetched = await cloudStore.fetchPrinter(jobRow.printer_id);
        if (fetched) {
            printerCfg = {
                type: fetched.type || 'network',
                ip: fetched.ip_address || jobRow.ip,
                port: fetched.port || jobRow.port || 9100,
                name: fetched.name,
                device_path: fetched.device_path,
                mac: fetched.mac,
                encoding: fetched.encoding,
                paper_width: fetched.paper_width,
            };
        }
    }
    return printerCfg;
};

/**
 * Sprint 4 — Claim hasta MAX_CLAIM_PER_TICK jobs y los despacha al
 * dispatcher por impresora. Las impresoras procesan en paralelo.
 *
 * @returns {number} jobs claimados este tick (0 si la cola está vacía).
 */
const tickCloud = async () => {
    let claimed = 0;
    while (claimed < MAX_CLAIM_PER_TICK) {
        const jobRow = await cloudStore.claimNext();
        if (!jobRow) break;

        const jobId = jobRow.id;
        logger.info(
            `[worker] CLOUD claim ${jobId} (kind=${jobRow.kind || 'unknown'}, ` +
            `area=${jobRow.area_code || '-'}, retry=${jobRow.retry_count || 0})`,
        );

        const printerCfg = await resolvePrinterCfg(jobRow);
        const accepted = printerDispatcher.dispatch(jobRow, printerCfg);

        if (!accepted) {
            // Dispatcher rechazó por tope global. Liberamos el claim
            // para que otro agent (o nosotros en el próximo tick cuando
            // bajen los counters) lo tome.
            await cloudStore.complete(
                jobId,
                false,
                'agent saturado: tope de impresoras concurrentes alcanzado',
            );
            logger.warn(`[worker] dispatcher rechazó ${jobId}, devuelto a la cola`);
            // No incrementamos claimed para no salir del while; pero
            // tampoco insistimos si el tope sigue alcanzado — el ACK
            // failure ya cambió retry/next_retry_at, así que en el
            // próximo claimNext probablemente saltemos al siguiente.
            break;
        }
        claimed++;
    }
    return claimed;
};

/**
 * Procesa un job de la cola SQLite local (legacy/fallback).
 */
const tickSqlite = async () => {
    const job = sqliteQueue.nextQueued();
    if (!job) return false;

    sqliteQueue.markPrinting(job.jobId);
    logger.info(`[worker] SQLITE procesando ${job.jobId} (ticket ${job.ticketId})`);

    try {
        const internalJob = {
            id: job.jobId,
            ...job.payload,
        };
        await processPrintJob(internalJob);
        sqliteQueue.markDone(job.jobId);
        logger.info(`[worker] SQLITE done ${job.jobId}`);
    } catch (err) {
        const msg = err?.message || String(err);
        sqliteQueue.markFailed(job.jobId, msg);
        logger.error(`[worker] SQLITE failed ${job.jobId}: ${msg}`);
    }
    return true;
};

/**
 * Un tick: prueba cloud primero, después SQLite. Cloud dispatchea al
 * pool (no-bloqueante); SQLite procesa serial inline (legacy).
 *
 * @returns {boolean} true si despachó/procesó al menos un job.
 */
const tick = async () => {
    let did = false;
    if (cloudStore.isEnabled()) {
        const claimed = await tickCloud();
        if (claimed > 0) did = true;
    }
    // Sprint 4 — SQLite sigue serial. Solo lo tocamos si el dispatcher
    // está ocioso, para no pelearnos por las mismas impresoras físicas.
    if (printerDispatcher.inFlightCount() === 0) {
        const processed = await tickSqlite();
        if (processed) did = true;
    }
    return did;
};

const loop = async () => {
    while (!stopRequested) {
        try {
            const processed = await tick();
            if (!processed) {
                await new Promise((r) => setTimeout(r, POLL_INTERVAL_MS));
            }
        } catch (err) {
            logger.error(`[worker] loop error: ${err.message}`);
            await new Promise((r) => setTimeout(r, POLL_INTERVAL_MS));
        }
    }
    running = false;
    logger.info('[worker] Stopped.');
};

const start = () => {
    if (running) return;
    sqliteQueue.init();
    if (CLOUD_WORKER_ENABLED) {
        cloudStore.init();
    }
    printerDispatcher.start();
    running = true;
    stopRequested = false;
    logger.info(
        `[worker] Iniciando. cloud=${cloudStore.isEnabled()} sqlite=enabled ` +
        `max_claim_per_tick=${MAX_CLAIM_PER_TICK} ` +
        `max_concurrent_printers=${printerDispatcher.MAX_CONCURRENT_PRINTERS}`,
    );
    loop();

    // Prune diario de jobs viejos en SQLite (estado terminal).
    pruneTimer = setInterval(() => {
        try { sqliteQueue.pruneOld(7); } catch (e) {
            logger.warn(`[worker] prune error: ${e.message}`);
        }
    }, PRUNE_INTERVAL_MS);

    // Reclaim stale jobs cada 60s (cloud queue).
    reclaimTimer = setInterval(async () => {
        if (!cloudStore.isEnabled()) return;
        try {
            const n = await cloudStore.reclaimStale(60);
            if (n > 0) {
                logger.info(`[worker] CLOUD reclaim: ${n} jobs huerfanos reseteados`);
            }
        } catch (e) {
            logger.warn(`[worker] reclaim error: ${e.message}`);
        }
    }, RECLAIM_INTERVAL_MS);
};

const stop = async () => {
    stopRequested = true;
    if (pruneTimer) {
        clearInterval(pruneTimer);
        pruneTimer = null;
    }
    if (reclaimTimer) {
        clearInterval(reclaimTimer);
        reclaimTimer = null;
    }
    // Esperar a que el loop termine la iteración actual (max 1 tick).
    let waited = 0;
    while (running && waited < 5000) {
        await new Promise((r) => setTimeout(r, 100));
        waited += 100;
    }
    // Drain del dispatcher (hasta 10s, ver módulo).
    await printerDispatcher.stop();
    sqliteQueue.close();
};

const isRunning = () => running;

/**
 * Snapshot de estado para el endpoint HTTP /status. Sprint 4: incluye
 * el detalle por impresora del dispatcher concurrente.
 */
const stats = () => ({
    running,
    cloudEnabled: cloudStore.isEnabled(),
    dispatcher: printerDispatcher.stats(),
});

module.exports = { start, stop, isRunning, stats };
