const Service = require('node-windows').Service;
const path = require('path');
const config = require('../src/config'); // Load config to get service name

// Create a new service object
const svc = new Service({
    name: config.service?.name || 'MangoPOSPrintAgent',
    description: config.service?.description || 'MangoPOS Print Agent Service',
    script: path.join(__dirname, '../src/main.js'),
    env: [{
        name: "NODE_ENV",
        value: "production"
    }]
});

// Listen for the "install" event, which indicates the
// process is available as a service.
svc.on('install', function () {
    console.log('Service installed successfully!');
    svc.start();
});

svc.on('alreadyinstalled', function () {
    console.log('Service is already installed.');
    svc.start();
});

svc.install();
