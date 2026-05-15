// PRD 7 Fase 1.1 — Cola persistente SQLite (better-sqlite3 sync API).
//
// Schema directo del PRD §8.3. Persistencia en `<baseDir>/queue.db` para
// que reinicios del agente no pierdan trabajos pendientes.
//
// Idempotencia: si llega un job con un `ticket_id` que ya existe en la
// tabla, devolvemos el job original sin re-encolar (PRD §6.5 RF-19).
//
// Recuperación al inicio: cualquier job en estado `printing` cuando el
// agente arranca se considera huérfano (la instancia previa cayó en
// medio del print) y se devuelve a `queued` para reintentar (PRD §10
// hito Fase 2).

const path = require('path');
const fs = require('fs');
const Database = require('better-sqlite3');
const { randomUUID } = require('crypto');
const { logger, baseDir, isPkg } = require('../config');

const DB_PATH = path.join(baseDir, 'queue.db');

// Cuando el binario se empaqueta con `pkg`, los modulos nativos (.node)
// NO pueden cargarse desde el snapshot virtual (C:\snapshot\...). Hay
// que enviarles un path real en disco. El instalador deja
// better_sqlite3.node junto al .exe del agente (baseDir).
const resolveNativeBinding = () => {
    if (!isPkg) return null;
    const candidate = path.join(baseDir, 'better_sqlite3.node');
    return fs.existsSync(candidate) ? candidate : null;
};

let db = null;

const SCHEMA = `
CREATE TABLE IF NOT EXISTS jobs (
  job_id        TEXT PRIMARY KEY,
  ticket_id     TEXT NOT NULL UNIQUE,
  device_id     TEXT,
  type          TEXT,
  priority      TEXT NOT NULL DEFAULT 'normal',
  payload       TEXT NOT NULL,
  status        TEXT NOT NULL,
  attempts      INTEGER NOT NULL DEFAULT 0,
  last_error    TEXT,
  enqueued_at   INTEGER NOT NULL,
  started_at    INTEGER,
  finished_at   INTEGER
);

CREATE INDEX IF NOT EXISTS idx_jobs_status_enqueued ON jobs(status, enqueued_at);
CREATE INDEX IF NOT EXISTS idx_jobs_ticket_id      ON jobs(ticket_id);
`;

const init = () => {
    if (db) return db;
    logger.info(`[queue] Abriendo cola SQLite en ${DB_PATH}`);
    const nativeBinding = resolveNativeBinding();
    const dbOpts = nativeBinding ? { nativeBinding } : {};
    if (nativeBinding) {
        logger.info(`[queue] Usando native binding externa: ${nativeBinding}`);
    } else if (isPkg) {
        logger.error(
            '[queue] No se encontro better_sqlite3.node junto al ejecutable. ' +
            'El agente NO podra abrir SQLite y crasheara. Reinstalar el agente.',
        );
    }
    db = new Database(DB_PATH, dbOpts);
    db.pragma('journal_mode = WAL');
    db.pragma('synchronous = NORMAL');
    db.exec(SCHEMA);

    // Recuperación: jobs en `printing` al arrancar = huérfanos de una
    // instancia previa que cayó. Volvemos a `queued` para reintento.
    const recovered = db
        .prepare("UPDATE jobs SET status = 'queued', started_at = NULL WHERE status = 'printing'")
        .run();
    if (recovered.changes > 0) {
        logger.warn(`[queue] Recuperados ${recovered.changes} jobs huerfanos en 'printing' al arrancar.`);
    }
    return db;
};

const close = () => {
    if (!db) return;
    try { db.close(); } catch (_) {}
    db = null;
};

const _row = (row) => row ? ({
    jobId: row.job_id,
    ticketId: row.ticket_id,
    deviceId: row.device_id,
    type: row.type,
    priority: row.priority,
    payload: JSON.parse(row.payload),
    status: row.status,
    attempts: row.attempts,
    lastError: row.last_error,
    enqueuedAt: row.enqueued_at,
    startedAt: row.started_at,
    finishedAt: row.finished_at,
}) : null;

// Inserta el job si ticket_id es nuevo. Si existe, devuelve el original.
// Retorna `{ job, duplicate }`.
const enqueue = ({ ticketId, deviceId, type, priority, payload }) => {
    if (!db) init();
    if (!ticketId) {
        throw new Error('enqueue: ticketId is required for idempotency');
    }

    const existing = db
        .prepare('SELECT * FROM jobs WHERE ticket_id = ?')
        .get(ticketId);
    if (existing) {
        return { job: _row(existing), duplicate: true };
    }

    const jobId = `job_${randomUUID()}`;
    const now = Date.now();
    db.prepare(`
        INSERT INTO jobs (job_id, ticket_id, device_id, type, priority,
                          payload, status, attempts, enqueued_at)
        VALUES (?, ?, ?, ?, ?, ?, 'queued', 0, ?)
    `).run(
        jobId,
        ticketId,
        deviceId || null,
        type || null,
        priority || 'normal',
        JSON.stringify(payload),
        now,
    );

    const created = db
        .prepare('SELECT * FROM jobs WHERE job_id = ?')
        .get(jobId);
    return { job: _row(created), duplicate: false };
};

// Devuelve el siguiente job FIFO en estado queued, o null si la cola
// está vacía.
const nextQueued = () => {
    if (!db) init();
    const row = db
        .prepare("SELECT * FROM jobs WHERE status = 'queued' ORDER BY enqueued_at ASC LIMIT 1")
        .get();
    return _row(row);
};

const markPrinting = (jobId) => {
    if (!db) init();
    db.prepare(`
        UPDATE jobs
           SET status = 'printing',
               attempts = attempts + 1,
               started_at = ?
         WHERE job_id = ?
    `).run(Date.now(), jobId);
};

const markDone = (jobId) => {
    if (!db) init();
    db.prepare(`
        UPDATE jobs
           SET status = 'done',
               last_error = NULL,
               finished_at = ?
         WHERE job_id = ?
    `).run(Date.now(), jobId);
};

const markFailed = (jobId, errorMsg) => {
    if (!db) init();
    db.prepare(`
        UPDATE jobs
           SET status = 'failed',
               last_error = ?,
               finished_at = ?
         WHERE job_id = ?
    `).run(String(errorMsg || '').slice(0, 1000), Date.now(), jobId);
};

const get = (jobId) => {
    if (!db) init();
    const row = db.prepare('SELECT * FROM jobs WHERE job_id = ?').get(jobId);
    return _row(row);
};

const getByTicketId = (ticketId) => {
    if (!db) init();
    const row = db.prepare('SELECT * FROM jobs WHERE ticket_id = ?').get(ticketId);
    return _row(row);
};

// Métricas livianas para /v1/info y diagnóstico.
const stats = () => {
    if (!db) init();
    const counts = db
        .prepare("SELECT status, COUNT(*) as n FROM jobs GROUP BY status")
        .all();
    const out = { queued: 0, printing: 0, done: 0, failed: 0, cancelled: 0 };
    counts.forEach((r) => { out[r.status] = r.n; });
    return out;
};

// Limpia jobs en estado terminal más viejos que `retentionDays`.
const pruneOld = (retentionDays = 7) => {
    if (!db) init();
    const cutoff = Date.now() - retentionDays * 24 * 60 * 60 * 1000;
    const result = db.prepare(`
        DELETE FROM jobs
         WHERE status IN ('done', 'failed', 'cancelled')
           AND finished_at IS NOT NULL
           AND finished_at < ?
    `).run(cutoff);
    if (result.changes > 0) {
        logger.info(`[queue] Prune: borrados ${result.changes} jobs con >${retentionDays}d.`);
    }
    return result.changes;
};

module.exports = {
    init,
    close,
    enqueue,
    nextQueued,
    markPrinting,
    markDone,
    markFailed,
    get,
    getByTicketId,
    stats,
    pruneOld,
    DB_PATH,
};
