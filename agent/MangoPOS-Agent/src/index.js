// PRD 7 Fase 1.0 — Entry point del agente.
//
// Refactor de monolito (1121 líneas → módulos por dominio):
//   - config.js              → env, logger, constantes
//   - print/escpos_helpers   → CMD + formatters
//   - print/usb_selection    → VID/PID parsing
//   - print/winspool         → path Windows USB sin Zadig
//   - print/templates/*      → precheck + invoice
//   - print/job_processor    → orquestador (winspool / libusb / network)
//   - platform/windows       → PowerShell + port listener
//   - network/tcp            → TCP raw + status check
//   - socket/cloud           → Socket.IO al backend
//   - http/server            → Express + endpoints locales
//
// Este index.js solo cablea: config → log → socket → http server.

const { logger, AGENT_ID } = require('./config');
const { startCloudSocket } = require('./socket/cloud');
const { startLocalApiServer } = require('./http/server');

logger.info(`Iniciando MangoPOS Print Agent [${AGENT_ID}]`);

// Cliente Socket.IO al backend (legacy, dormido si no hay BACKEND_URL).
startCloudSocket();

// Servidor HTTP local — path principal hoy.
startLocalApiServer().catch((err) => {
    logger.error(`No se pudo iniciar el servidor HTTP local: ${err.message}`);
});

// Mantener proceso vivo ante errores no manejados.
process.on('uncaughtException', (err) => {
    logger.error(`CRITICAL ERROR: ${err.message}`);
    if (err.stack) logger.error(err.stack);
});

process.on('unhandledRejection', (reason) => {
    logger.error(`Unhandled rejection: ${reason}`);
});

// Shutdown gracioso ante SIGTERM/SIGINT (PRD 7 Fase 1.0).
const handleShutdown = (signal) => {
    logger.info(`Recibido ${signal}. Cerrando agente...`);
    process.exit(0);
};
process.on('SIGTERM', () => handleShutdown('SIGTERM'));
process.on('SIGINT', () => handleShutdown('SIGINT'));
