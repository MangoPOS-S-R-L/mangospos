const Service = require('node-windows').Service;
const path = require('path');
const config = require('../src/config');

// Create a new service object
const svc = new Service({
    name: config.service?.name || 'MangoPOSPrintAgent', // Must match install script
    script: path.join(__dirname, '../src/main.js')
});

// Listen for the "uninstall" event so we know when it's done.
svc.on('uninstall', function () {
    console.log('Uninstall complete.');
    console.log('To reinstall, run scripts/install_service.js');
});

// Uninstall the service.
svc.uninstall();
