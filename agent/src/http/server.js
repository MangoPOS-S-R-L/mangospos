// PRD 7 Fase 1.0 — Servidor HTTP local (Express) del agente.
//
// Endpoints:
//   GET  /health                  — health check sin auth
//   GET  /status                  — alias de /health
//   POST /check-connectivity      — TCP ping a un set de impresoras
//   POST /print                   — encolar job (hoy: invoca processPrintJob directo)
//   POST /api/printers/raw        — escribir bytes RAW a IP:puerto
//   GET  /api/printers/discover   — escaneo de red local
//
// PRD 7 Fase 1.1 cambiará POST /print para encolar en SQLite con
// idempotencia + worker async, en vez de procesar inline.

const path = require('path');
const express = require('express');
const cors = require('cors');

const { logger, baseDir, AGENT_ID, LOCAL_PORT } = require('../config');
const { stopExistingAgentOnLocalPort } = require('../platform/windows');
const { processPrintJob } = require('../print/job_processor');
const { sendRawTcp, checkPrinterStatus } = require('../network/tcp');
const discoveryService = require('../core/discovery');

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
    app.get('/status', (_req, res) => res.json({ ...healthPayload(), status: 'online' }));

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
    app.post('/print', async (req, res) => {
        const job = req.body;
        if (!job.id) job.id = `LOCAL-${Date.now()}`;
        try {
            logger.info(`Recibida peticion local de impresion: ${job.id}`);
            await processPrintJob(job);
            res.json({ success: true, jobId: job.id });
        } catch (error) {
            logger.error(`Error en impresion local: ${error.message}`);
            res.status(500).json({ success: false, error: error.message });
        }
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
