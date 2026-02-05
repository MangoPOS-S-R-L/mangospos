const Service = require('node-windows').Service;
const path = require('path');

// Crear el objeto del servicio
const svc = new Service({
    name: 'MangoPOS Print Agent',
    script: path.join(__dirname, 'src', 'index.js')
});

// Escuchar evento de desinstalación
svc.on('uninstall', function () {
    console.log('🗑️ Servicio eliminado correctamente.');
    console.log('El agente ha dejado de ejecutarse.');
});

// Desinstalar
console.log('Propagando detención del servicio...');
svc.uninstall();
