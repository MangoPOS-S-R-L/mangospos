// PRD 7 Fase 1.0 — Configuración global del agente.
//
// Exporta:
//   - logger (winston configurado, escribe a Console + agent.log)
//   - env vars normalizadas (SERVER_URL, AGENT_ID, AUTH_TOKEN)
//   - constantes (LOCAL_PORT, PRINTER_WIDTH, baseDir, isPkg)
//   - config (legacy): estructura cargada desde config.yaml para mantener
//     compatibilidad con módulos viejos (core/discovery.js, etc.).
//
// Cualquier módulo nuevo debe importar `logger`, `LOCAL_PORT`, etc.
// directamente. No usar `config.security.api_token` salvo que sea código
// legacy migrado.

const fs = require('fs');
const path = require('path');
const yaml = require('js-yaml');
const winston = require('winston');

// Detectar si corremos como script o como binario pkg.
const isPkg = typeof process.pkg !== 'undefined';
const baseDir = isPkg ? path.dirname(process.execPath) : path.join(__dirname, '..');

require('dotenv').config({ path: path.join(baseDir, '.env') });

const LOGS_DIR = path.join(baseDir, 'logs');
if (!fs.existsSync(LOGS_DIR)) {
    fs.mkdirSync(LOGS_DIR, { recursive: true });
}

const logger = winston.createLogger({
    level: process.env.LOG_LEVEL || 'info',
    format: winston.format.combine(
        winston.format.timestamp(),
        winston.format.json(),
    ),
    transports: [
        new winston.transports.Console({ format: winston.format.simple() }),
        // Mantener compatibilidad con consumers legacy que esperaban
        // agent.log en raíz del baseDir, NO en logs/.
        new winston.transports.File({ filename: path.join(baseDir, 'agent.log') }),
        new winston.transports.File({ filename: path.join(LOGS_DIR, 'agent.log') }),
    ],
});

// ── Legacy config.yaml support (módulos en core/* lo esperan) ─────────
const CONFIG_PATH = path.join(baseDir, 'config.yaml');

const DEFAULT_CONFIG = {
    service: { port: 9100 },
    security: { enabled: true, api_token: 'default_token', whitelist: ['127.0.0.1'] },
    discovery: { enabled: true, protocols: ['network', 'usb'] },
    printers: [],
};

let config = { ...DEFAULT_CONFIG };
try {
    if (fs.existsSync(CONFIG_PATH)) {
        const fileContents = fs.readFileSync(CONFIG_PATH, 'utf8');
        const parsed = yaml.load(fileContents);
        config = { ...DEFAULT_CONFIG, ...parsed };
    }
} catch (e) {
    logger.error(`Error loading config.yaml: ${e}`);
}

module.exports = {
    // Nuevos exports (PRD 7).
    isPkg,
    baseDir,
    logger,
    SERVER_URL: process.env.BACKEND_URL || 'http://localhost:3000',
    AGENT_ID: process.env.AGENT_ID || 'unknown-agent',
    AGENT_NAME: process.env.AGENT_NAME,
    AUTH_TOKEN: process.env.AUTH_TOKEN,
    LOCAL_PORT: 4000,
    PRINTER_WIDTH: 48,
    // Legacy export (consumers en core/*).
    config,
};
