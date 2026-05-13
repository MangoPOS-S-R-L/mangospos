// PRD 7 Fase 1.0/1.1/1.2 — Servidor HTTP local (Express) del agente.
//
// Endpoints:
//   GET  /health                  — health check (SIN auth, RF-14)
//   GET  /status                  — alias de /health (sin auth)
//   POST /check-connectivity      — TCP ping a un set de impresoras
//   POST /print                   — encola job en SQLite (FIFO, Fase 1.1)
//   GET  /v1/jobs/:jobId          — estado del job
//   GET  /v1/info                 — métricas del agente
//   POST /api/printers/raw        — escribir bytes RAW a IP:puerto
//   GET  /api/printers/discover   — escaneo de red local
//
// Fase 1.2: todos los endpoints excepto /health y /status pasan por
// `requireAuth` (Bearer JWT, validación HS256, claim restaurant_id).

const path = require('path');
const { randomUUID } = require('crypto');
const express = require('express');
const cors = require('cors');

const { logger, baseDir, AGENT_ID, LOCAL_PORT } = require('../config');
const { stopExistingAgentOnLocalPort } = require('../platform/windows');
const { sendRawTcp, checkPrinterStatus } = require('../network/tcp');
const queue = require('../queue/store');
const queueWorker = require('../queue/worker');
const discoveryService = require('../core/discovery');
const { requireAuth, logStartupMode: logAuthStartupMode } = require('./auth');

const buildApp = () => {
    const app = express();

    app.use(cors({
        origin: true,
        credentials: true,
        methods: ['GET', 'POST', 'OPTIONS'],
        allowedHeaders: [
            'Content-Type',
            'Authorization',
            'Access-Control-Allow-Private-Network',
        ],
    }));

    // Private Network Access (Chrome/Edge).
    app.use((req, res, next) => {
        res.setHeader('Access-Control-Allow-Private-Network', 'true');
        next();
    });

    app.use(express.json());

    // ── Health ──────────────────────────────────────────────────────
    const healthPayload = () => ({
        status: 'ok',
        agent: AGENT_ID,
        version: '1.0.0',
    });
    app.get('/health', (_req, res) => res.json(healthPayload()));
    // Sprint 4 — /status incluye el snapshot del dispatcher concurrente
    // (impresoras activas, jobs en cola por impresora). Útil para que
    // la pantalla de diagnóstico del frontend muestre throughput vivo.
    app.get('/status', (_req, res) => {
        let workerStats = null;
        try {
            workerStats = queueWorker.stats();
        } catch (_) { /* worker no inicializado todavía */ }
        res.json({
            ...healthPayload(),
            status: 'online',
            worker: workerStats,
        });
    });

    // ── Auth gate (Fase 1.2) ────────────────────────────────────────
    // A partir de aquí, todos los endpoints requieren JWT válido
    // (no-op si JWT_SECRET no está configurado — modo legacy).
    app.use(requireAuth);

    // ── TCP ping a impresoras (batch) ───────────────────────────────
    app.post('/check-connectivity', async (req, res) => {
        const { printers } = req.body;
        if (!printers || !Array.isArray(printers)) {
            return res.status(400).json({ error: 'Invalid printers list' });
        }
        const results = {};
        await Promise.all(printers.map(async (p) => {
            if (!p.ip) return;
            const isOnline = await checkPrinterStatus(p.ip, p.port || 9100);
            results[p.ip] = isOnline;
        }));
        res.json({ results });
    });

    // ── Encolar job de impresión (path principal) ───────────────────
    // Encola en SQLite con idempotencia por ticket_id; el worker
    // secuencial procesa FIFO (PRD 7 Fase 1.1).
    app.post('/print', async (req, res) => {
        const body = req.body || {};
        // Acepta `ticket_id` (PRD 7 contract), `ticketId` (camelCase) o
        // el legacy `id` que el cliente Flutter actual envía.
        const ticketId = body.ticket_id || body.ticketId || body.id || `local_${randomUUID()}`;
        try {
            const { job, duplicate } = queue.enqueue({
                ticketId,
                deviceId: body.device_id || body.deviceId || null,
                type: body.type || body.printer?.type || 'unknown',
                priority: body.priority || 'normal',
                payload: {
                    printer: body.printer,
                    content: body.content,
                    // Legacy: algunos callers mandaban dataBase64 al root.
                    dataBase64: body.dataBase64,
                },
            });

            if (duplicate) {
                logger.info(`Print duplicate ticket=${ticketId} → job=${job.jobId} (status=${job.status})`);
                return res.status(200).json({
                    job_id: job.jobId,
                    ticket_id: job.ticketId,
                    status: job.status,
                    duplicate: true,
                    printed_at: job.finishedAt
                        ? new Date(job.finishedAt).toISOString()
                        : null,
                });
            }

            logger.info(`Print encolado ticket=${ticketId} → job=${job.jobId}`);
            res.status(202).json({
                job_id: job.jobId,
                ticket_id: job.ticketId,
                status: job.status,
                // Compat legacy con clientes actuales.
                success: true,
                jobId: job.jobId,
            });
        } catch (error) {
            logger.error(`Error encolando impresion: ${error.message}`);
            res.status(500).json({ success: false, error: error.message });
        }
    });

    // ── Estado de un job específico ─────────────────────────────────
    app.get('/v1/jobs/:jobId', (req, res) => {
        const job = queue.get(req.params.jobId);
        if (!job) return res.status(404).json({ error: 'job not found' });
        res.json({
            job_id: job.jobId,
            ticket_id: job.ticketId,
            status: job.status,
            attempts: job.attempts,
            last_error: job.lastError,
            enqueued_at: job.enqueuedAt && new Date(job.enqueuedAt).toISOString(),
            started_at: job.startedAt && new Date(job.startedAt).toISOString(),
            printed_at: job.finishedAt && new Date(job.finishedAt).toISOString(),
        });
    });

    // ── Info / métricas del agente ──────────────────────────────────
    app.get('/v1/info', (_req, res) => {
        res.json({
            agent_id: AGENT_ID,
            agent_version: '1.0.0',
            queue: queue.stats(),
            uptime_seconds: Math.round(process.uptime()),
        });
    });

    // ── UI estática (si existe public/) ─────────────────────────────
    app.use(express.static(path.join(baseDir, 'public')));

    // ── Impresión RAW directa por IP (network) ──────────────────────
    app.post('/api/printers/raw', async (req, res) => {
        try {
            const ip = req.body?.ip;
            const port = req.body?.port || 9100;
            const dataBase64 = req.body?.dataBase64;
            const dataHex = req.body?.dataHex;

            if (!ip) return res.status(400).json({ ok: false, error: 'Missing ip' });
            if (!dataBase64 && !dataHex) {
                return res.status(400).json({ ok: false, error: 'Missing dataBase64/dataHex' });
            }

            const payload = dataBase64
                ? Buffer.from(dataBase64, 'base64')
                : Buffer.from(dataHex, 'hex');

            await sendRawTcp(ip, port, payload);
            res.json({ ok: true });
        } catch (error) {
            logger.error(`Error RAW print: ${error.message}`);
            res.status(500).json({ ok: false, error: error.message });
        }
    });

    // ── Discovery de impresoras en red local ────────────────────────
    app.get('/api/printers/discover', async (_req, res) => {
        try {
            const devices = await discoveryService.scan();
            const items = devices.map((device) => ({
                type: device.type || 'network',
                name: device.name || 'Printer',
                ip: device.address && device.type === 'network' ? device.address : null,
                port: device.port || 9100,
                mac: device.deviceId || null,
                deviceId: device.deviceId || device.address || null,
                vid: device.vid || null,
                pid: device.pid || null,
            }));
            res.json({ items });
        } catch (error) {
            logger.error(`Discovery error: ${error.message}`);
            res.status(500).json({ items: [], error: error.message });
        }
    });

    return app;
};

const startLocalApiServer = async () => {
    await stopExistingAgentOnLocalPort();
    logAuthStartupMode();

    const app = buildApp();

    // Bind explícito a 0.0.0.0 para garantizar accesibilidad LAN
    // (sharing de impresoras USB/BT entre dispositivos del business).
    return new Promise((resolve, reject) => {
        const server = app.listen(LOCAL_PORT, '0.0.0.0', () => {
            logger.info(`Local API escuchando en http://0.0.0.0:${LOCAL_PORT}`);
            resolve(server);
        }).on('error', (err) => {
            if (err.code === 'EADDRINUSE') {
                logger.error(`El puerto ${LOCAL_PORT} ya esta en uso. El agente seguira operando via Socket.io si es posible.`);
            } else {
                logger.error(`Error iniciando servidor API: ${err.message}`);
            }
            reject(err);
        });
    });
};

module.exports = { startLocalApiServer, buildApp };
