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

// PRD 7 Fase 1.2 — auth JWT.
// JWT_SECRET: shared secret HS256 con Supabase (env JWT_SECRET o
// SUPABASE_JWT_SECRET).
// RESTAURANT_ID: id del business al que sirve este agente. El claim
// `restaurant_id` (o `business_id`) del JWT debe coincidir con éste,
// o devolvemos 403.
// Si JWT_SECRET no está configurado, el agente loguea WARN al arrancar
// y deja pasar todo (modo legacy/dev). Esto permite rollout gradual:
// configurar JWT_SECRET cuando los clientes ya envían el header.
const JWT_SECRET = process.env.JWT_SECRET || process.env.SUPABASE_JWT_SECRET || null;
const RESTAURANT_ID = process.env.RESTAURANT_ID || process.env.BUSINESS_ID || null;
const AUTH_ENABLED = !!JWT_SECRET;

// Sprint 1.2 (refactor impresion Square+):
//   SUPABASE_URL + SUPABASE_KEY habilitan el "cloud worker" que toma
//   jobs directo de la tabla print_jobs (fuente de verdad). Si NO se
//   configuran, el agent sigue funcionando solo con SQLite local (modo
//   legacy). Esto permite rollout gradual.
//
//   AGENT_UUID: UUID de device_agents.id que representa este agente.
//   Debe coincidir con el UUID que registra el cliente Flutter al
//   arrancar en el mismo device. Si no se configura, el cloud worker
//   queda deshabilitado.
const SUPABASE_URL = process.env.SUPABASE_URL || null;
const SUPABASE_KEY =
    process.env.SUPABASE_SERVICE_ROLE_KEY ||
    process.env.SUPABASE_KEY ||
    process.env.SUPABASE_ANON_KEY ||
    null;
const AGENT_UUID = process.env.AGENT_UUID || null;
const CLOUD_WORKER_ENABLED = !!(SUPABASE_URL && SUPABASE_KEY && AGENT_UUID);

if (!CLOUD_WORKER_ENABLED) {
    logger.warn(
        '[config] Cloud worker DESHABILITADO. Falta SUPABASE_URL, ' +
        'SUPABASE_KEY o AGENT_UUID en .env. El agent procesará solo ' +
        'jobs entrando via HTTP /print (SQLite local).',
    );
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
    JWT_SECRET,
    RESTAURANT_ID,
    AUTH_ENABLED,
    LOCAL_PORT: 4000,
    PRINTER_WIDTH: 48,
    // Sprint 1.2: cloud worker config.
    SUPABASE_URL,
    SUPABASE_KEY,
    AGENT_UUID,
    CLOUD_WORKER_ENABLED,
    // Legacy export (consumers en core/*).
    config,
};
