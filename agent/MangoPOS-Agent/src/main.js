const config = require('./config');
const apiServer = require('./api/server');
const printerManager = require('./core/printer_manager');
const discovery = require('./core/discovery');

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

    // Load Discovery (Scan on startup)
    try {
        await discovery.scan();
        config.logger.info(`Discovered ${discovery.discoveredDevices.length} devices.`);
    } catch (e) {
        config.logger.warn(`Initial discovery failed: ${e.message}`);
    }

    // Start API
    apiServer.start();

    // Start Queue
    config.logger.info('Printer Queue Manager started.');
}

main();
