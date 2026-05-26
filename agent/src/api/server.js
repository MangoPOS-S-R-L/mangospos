const express = require('express');
const cors = require('cors');
const { config, logger } = require('../config');
const printerManager = require('../core/printer_manager');
const discoveryService = require('../core/discovery');
const { getMacForIp, normalizeMac } = require('../network/arp');
const { resolveByMac } = require('../network/printer_resolver');

const app = express();
const PORT = config.service.port || 9100;

app.use(cors());
app.use(express.json());

const authenticate = (req, res, next) => {
    if (!config.security.enabled) return next();

    const token = req.headers['authorization'] || req.query.token;
    if (token === `Bearer ${config.security.api_token}` || token === config.security.api_token) {
        return next();
    }
    logger.warn(`Unauthorized access attempt from ${req.ip} to ${req.method} ${req.originalUrl}`);
    res.status(401).json({ error: 'Verify API Token' });
};

app.get('/status', (req, res) => {
    res.json({
        service: config.service.name,
        version: '2.0.0',
        uptime: process.uptime(),
        queue: printerManager.getQueueStatus(),
        discovery: discoveryService.isScanning ? 'scanning' : 'idle',
    });
});

app.get('/printers', authenticate, async (req, res) => {
    try {
        const configured = config.printers;
        const discovered = await discoveryService.scan();
        res.json({ configured, discovered });
    } catch (e) {
        logger.error(`Discovery failed: ${e.message}`);
        res.status(500).json({ error: e.message });
    }
});

app.get('/api/printers/discover', authenticate, async (req, res) => {
    try {
        const discovered = await discoveryService.scan();
        res.json({ items: discovered, discovered });
    } catch (e) {
        logger.error(`Discovery failed: ${e.message}`);
        res.status(500).json({ error: e.message });
    }
});

app.post('/print', authenticate, async (req, res) => {
    const job = req.body;
    if (!job.printerId || job.content == null) {
        return res.status(400).json({ error: 'Missing printerId or content' });
    }

    try {
        logger.info(
            `Incoming /print request -> printerId=${job.printerId} type=${job.type || 'text'} from ${req.ip}` +
            `${job.printer ? ' with-inline-printer=true' : ''}`
        );

        const normalizedJob = {
            printerId: job.printerId,
            printer: job.printer && typeof job.printer === 'object' ? job.printer : undefined,
            meta: job.meta,
            data: {
                type: job.type || 'text',
                content: job.content,
            },
        };

        const jobId = printerManager.addJob(normalizedJob);
        res.json({ success: true, jobId, status: 'queued' });
    } catch (e) {
        res.status(500).json({ error: e.message });
    }
});

app.post('/test-print', authenticate, async (req, res) => {
    const { printerId } = req.body;
    if (!printerId) return res.status(400).json({ error: 'Printer ID required' });

    const testJob = {
        printerId,
        data: {
            type: 'text',
            content: `
--------------------------------
MANGO POS TEST PRINT
--------------------------------
Date: ${new Date().toLocaleString()}
Printer ID: ${printerId}
Service Status: ONLINE
--------------------------------
`,
        },
    };

    logger.info(`Incoming /test-print request -> printerId=${printerId} from ${req.ip}`);
    const jobId = printerManager.addJob(testJob);
    res.json({ success: true, jobId, message: 'Test print queued' });
});

app.post('/api/printers/test', authenticate, async (req, res) => {
    const { printerId, ip, port } = req.body;
    const normalizedPrinterId = printerId || (ip ? `${ip}:${port || 9100}` : null);

    if (!normalizedPrinterId) {
        return res.status(400).json({ error: 'Printer ID required' });
    }

    const testJob = {
        printerId: normalizedPrinterId,
        data: {
            type: 'text',
            content: `
--------------------------------
MANGO POS TEST PRINT
--------------------------------
Date: ${new Date().toLocaleString()}
Printer ID: ${normalizedPrinterId}
Service Status: ONLINE
--------------------------------
`,
        },
    };

    const jobId = printerManager.addJob(testJob);
    res.json({ ok: true, success: true, jobId, message: 'Test print queued' });
});

app.post('/api/printers/raw', authenticate, async (req, res) => {
    const { printerId, ip, port, dataBase64 } = req.body;
    const normalizedPrinterId = printerId || (ip ? `${ip}:${port || 9100}` : null);

    if (!normalizedPrinterId || !dataBase64) {
        return res.status(400).json({ error: 'Missing printerId/ip or dataBase64' });
    }

    try {
        const jobId = printerManager.addJob({
            printerId: normalizedPrinterId,
            data: {
                type: 'raw',
                content: dataBase64,
            },
        });
        res.json({ ok: true, success: true, jobId, status: 'queued' });
    } catch (e) {
        res.status(500).json({ error: e.message });
    }
});

// ============================================================================
// Printer auto-recovery — MAC-based IP resolution
//
// Flujo cliente (Flutter):
//   1. POST /api/printers/mac-for-ip { ip } → captura MAC tras print exitoso
//      la primera vez (cuando aún no la teníamos guardada en Supabase).
//   2. POST /api/printers/resolve-by-mac { mac } → tras un fallo de socket,
//      buscar la nueva IP de esa impresora en el LAN. Si la encuentra,
//      Flutter actualiza Supabase y reintenta el print una vez.
// ============================================================================

app.post('/api/printers/mac-for-ip', authenticate, async (req, res) => {
    const { ip } = req.body || {};
    if (!ip || !/^\d{1,3}(\.\d{1,3}){3}$/.test(String(ip))) {
        return res.status(400).json({ error: 'Missing or invalid ip' });
    }
    try {
        const mac = await getMacForIp(String(ip));
        if (!mac) return res.status(404).json({ error: 'mac_not_resolved', ip });
        res.json({ ip, mac });
    } catch (e) {
        logger.error(`/mac-for-ip failed for ${ip}: ${e.message}`);
        res.status(500).json({ error: e.message });
    }
});

app.post('/api/printers/resolve-by-mac', authenticate, async (req, res) => {
    const { mac, printerId } = req.body || {};
    const normalized = normalizeMac(mac);
    if (!normalized) {
        return res.status(400).json({ error: 'Missing or invalid mac' });
    }
    const logCtx = printerId ? ` [printer=${printerId}]` : '';
    try {
        const result = await resolveByMac(normalized, { logCtx });
        if (!result) {
            return res.status(404).json({ error: 'printer_not_found', mac: normalized });
        }
        res.json({ mac: normalized, ip: result.ip, source: result.source });
    } catch (e) {
        logger.error(`/resolve-by-mac failed for ${normalized}: ${e.message}`);
        res.status(500).json({ error: e.message });
    }
});

app.use(express.static(require('path').join(__dirname, '../../public')));

app.get('/api/config', authenticate, (req, res) => {
    res.json(config);
});

app.post('/api/config', authenticate, async (req, res) => {
    const newConfig = req.body;
    if (!newConfig.service || !newConfig.printers) {
        return res.status(400).json({ error: 'Invalid config structure' });
    }

    Object.assign(config, newConfig);

    try {
        const fs = require('fs');
        const yaml = require('js-yaml');
        const path = require('path');
        const yamlStr = yaml.dump(newConfig);
        fs.writeFileSync(path.join(__dirname, '../../config.yaml'), yamlStr, 'utf8');
        logger.info('Config updated via API');
        res.json({ success: true, message: 'Configuration saved.' });
    } catch (e) {
        logger.error(`Failed to save config: ${e.message}`);
        res.status(500).json({ error: 'Failed to write config file' });
    }
});

const start = () => {
    app.listen(PORT, '0.0.0.0', () => {
        logger.info(`MangoPOS Agent running on port ${PORT}`);
        logger.info(`Admin UI available at http://localhost:${PORT}`);
    });
};

module.exports = { start };
