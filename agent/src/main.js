const config = require('./config');
const apiServer = require('./api/server');
const printerManager = require('./core/printer_manager');

// Handle Process Events
process.on('uncaughtException', (err) => {
    console.error('Uncaught Exception:', err);
    // In a real service, verify if we should exit or keep running
});

process.on('unhandledRejection', (reason, promise) => {
    console.error('Unhandled Rejection at:', promise, 'reason:', reason);
});

async function main() {
    config.logger.info('Starting MangoPOS Print Agent...');

    // Discovery on startup: DESACTIVADO.
    // El scan barría TODOS los IPs del subnet en port 9100 (JetDirect/RAW),
    // y algunas impresoras térmicas imprimen basura cuando reciben una
    // conexión TCP en ese puerto, aunque no se envíen bytes. En LAN
    // compartida (varios negocios), eso generaba impresiones constantes
    // en impresoras ajenas. El scan sigue disponible bajo demanda vía
    // GET /api/printers/discover si el cliente lo necesita.

    // Start API
    apiServer.start();

    // Start Queue
    config.logger.info('Printer Queue Manager started.');
}

main();
