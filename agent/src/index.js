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
const queueWorker = require('./queue/worker');
const mdnsAdvertiser = require('./discovery/mdns_advertiser');
const membershipCache = require('./http/membership_cache');

logger.info(`Iniciando MangoPOS Print Agent [${AGENT_ID}]`);

// Sprint 6 — Cache de membresías (user_id → business_ids) para que la
// validación JWT pueda chequear si el usuario realmente pertenece al
// negocio del agent sin tirar una query a Supabase por cada request.
membershipCache.start();

// Worker de la cola — arranca antes que cualquier path que encole, así
// no perdemos jobs si llegan inmediatamente.
queueWorker.start();

// Cliente Socket.IO al backend (legacy, dormido si no hay BACKEND_URL).
startCloudSocket();

// Servidor HTTP local — path principal hoy.
startLocalApiServer().catch((err) => {
    logger.error(`No se pudo iniciar el servidor HTTP local: ${err.message}`);
});

// Sprint 2.1: anunciar el agent vía mDNS para que tablets lo descubran
// automáticamente sin configurar IP. Si mDNS falla (red bloquea
// multicast), el agent sigue funcionando — solo no se auto-descubre.
mdnsAdvertiser.start();

// Mantener proceso vivo ante errores no manejados.
process.on('uncaughtException', (err) => {
    logger.error(`CRITICAL ERROR: ${err.message}`);
    if (err.stack) logger.error(err.stack);
});

process.on('unhandledRejection', (reason) => {
    logger.error(`Unhandled rejection: ${reason}`);
});

// Shutdown gracioso ante SIGTERM/SIGINT (PRD 7 Fase 1.0).
const handleShutdown = async (signal) => {
    logger.info(`Recibido ${signal}. Cerrando agente...`);
    try {
        mdnsAdvertiser.stop();
    } catch (e) {
        logger.warn(`Error deteniendo mdns: ${e.message}`);
    }
    try {
        await queueWorker.stop();
    } catch (e) {
        logger.warn(`Error cerrando worker: ${e.message}`);
    }
    try {
        membershipCache.stop();
    } catch (e) {
        logger.warn(`Error deteniendo membership cache: ${e.message}`);
    }
    process.exit(0);
};
process.on('SIGTERM', () => handleShutdown('SIGTERM'));
process.on('SIGINT', () => handleShutdown('SIGINT'));
