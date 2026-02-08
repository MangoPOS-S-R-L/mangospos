const express = require('express');
const cors = require('cors');
const { config, logger } = require('../config');
const printerManager = require('../core/printer_manager');
const discoveryService = require('../core/discovery');

const app = express();
const PORT = config.service.port || 9100;

// Middleware
app.use(cors());
app.use(express.json());

// Auth Middleware
const authenticate = (req, res, next) => {
    if (!config.security.enabled) return next();

    const token = req.headers['authorization'] || req.query.token;
    if (token === `Bearer ${config.security.api_token}` || token === config.security.api_token) {
        return next();
    }
    logger.warn(`Unauthorized access attempt from ${req.ip}`);
    res.status(401).json({ error: 'Verify API Token' });
};

// --- Routes ---

// Status
app.get('/status', (req, res) => {
    res.json({
        service: config.service.name,
        version: '2.0.0',
        uptime: process.uptime(),
        queue: printerManager.getQueueStatus(),
        discovery: discoveryService.isScanning ? 'scanning' : 'idle'
    });
});

// Prerequisites: Get Printers (Discovery + Configured)
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

// Print Job
app.post('/print', authenticate, async (req, res) => {
    const job = req.body;
    // job object: { printerId, type: 'raw'|'text', content: 'Base64...' }
    if (!job.printerId || !job.content) {
        return res.status(400).json({ error: 'Missing printerId or content' });
    }

    try {
        const jobId = printerManager.addJob(job);
        res.json({ success: true, jobId, status: 'queued' });
    } catch (e) {
        res.status(500).json({ error: e.message });
    }
});

// Test Print
app.post('/test-print', authenticate, async (req, res) => {
    const { printerId } = req.body;
    if (!printerId) return res.status(400).json({ error: 'Printer ID required' });

    // Internal test job
    const testJob = {
        printerId,
        type: 'text',
        content: `
--------------------------------
MANGO POS TEST PRINT
--------------------------------
Date: ${new Date().toLocaleString()}
Printer ID: ${printerId}
Service Status: ONLINE
--------------------------------
`
    };

    const jobId = printerManager.addJob(testJob);
    res.json({ success: true, jobId, message: 'Test print queued' });
});


// --- Config & UI ---

// Serve Admin UI
app.use(express.static(require('path').join(__dirname, '../../public')));

// Get Config
app.get('/api/config', authenticate, (req, res) => {
    res.json(config);
});

// Update Config
app.post('/api/config', authenticate, async (req, res) => {
    const newConfig = req.body;
    // Basic validation
    if (!newConfig.service || !newConfig.printers) {
        return res.status(400).json({ error: 'Invalid config structure' });
    }

    // Update runtime config
    Object.assign(config, newConfig);

    // Save to disk
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


// Start Server
const start = () => {
    app.listen(PORT, '0.0.0.0', () => {
        logger.info(`MangoPOS Agent running on port ${PORT}`);
        logger.info(`Admin UI available at http://localhost:${PORT}`);
    });
};

module.exports = { start };
