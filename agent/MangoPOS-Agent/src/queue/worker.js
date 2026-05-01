// PRD 7 Fase 1.1 — Worker secuencial de la cola.
//
// Loop simple: poll → si hay queued → markPrinting → processPrintJob →
// markDone/markFailed → repeat. Exactamente UNA operación de impresión
// activa a la vez (PRD §6.2 RF-07).
//
// Sin reintentos en esta fase (Fase 2 agrega backoff exponencial).
// Sin paralelismo: un solo worker garantiza que dos comandos ESC/POS
// nunca se entrelacen en la misma impresora.

const { logger } = require('../config');
const queue = require('./store');
const { processPrintJob } = require('../print/job_processor');

const POLL_INTERVAL_MS = 250;
const PRUNE_INTERVAL_MS = 60 * 60 * 1000; // 1h

let running = false;
let stopRequested = false;
let pruneTimer = null;

const tick = async () => {
    const job = queue.nextQueued();
    if (!job) return false;

    queue.markPrinting(job.jobId);
    logger.info(`[worker] Procesando ${job.jobId} (ticket ${job.ticketId})`);

    try {
        // El payload del job contiene la estructura legacy de processPrintJob
        // (printer + content). Lo desempaquetamos y le ponemos el id que
        // necesita el orquestador para sus logs.
        const internalJob = {
            id: job.jobId,
            ...job.payload,
        };
        await processPrintJob(internalJob);
        queue.markDone(job.jobId);
        logger.info(`[worker] Done ${job.jobId}`);
    } catch (err) {
        const msg = err?.message || String(err);
        queue.markFailed(job.jobId, msg);
        logger.error(`[worker] Failed ${job.jobId}: ${msg}`);
    }
    return true;
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
    queue.init();
    running = true;
    stopRequested = false;
    logger.info('[worker] Iniciando worker secuencial de impresion.');
    loop();

    // Prune diario de jobs viejos en estado terminal.
    pruneTimer = setInterval(() => {
        try { queue.pruneOld(7); } catch (e) {
            logger.warn(`[worker] prune error: ${e.message}`);
        }
    }, PRUNE_INTERVAL_MS);
};

const stop = async () => {
    stopRequested = true;
    if (pruneTimer) {
        clearInterval(pruneTimer);
        pruneTimer = null;
    }
    // Esperar a que el loop termine la iteración actual (max 1 tick).
    let waited = 0;
    while (running && waited < 5000) {
        await new Promise((r) => setTimeout(r, 100));
        waited += 100;
    }
    queue.close();
};

const isRunning = () => running;

module.exports = { start, stop, isRunning };
