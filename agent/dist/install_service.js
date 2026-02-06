const Service = require('node-windows').Service;
const path = require('path');

// Crear el objeto del servicio
const svc = new Service({
    name: 'MangoPOS Print Agent',
    description: 'Servicio de impresión en segundo plano para MangoPOS Cloud.',
    script: path.join(__dirname, 'src', 'index.js'),
    workingDirectory: __dirname,
    nodeOptions: [
        '--harmony',
        '--max_old_space_size=4096'
    ],
    env: [
        { name: 'NODE_ENV', value: 'production' },
        // Garantiza que dotenv pueda resolver el .env relativo al workingDirectory
        { name: 'PWD', value: __dirname }
    ]
    //, allowServiceLogon: true
});

// Escuchar eventos
svc.on('install', function () {
    console.log('✅ Servicio instalado correctamente.');
    console.log('🚀 Iniciando servicio...');
    svc.start();
});

svc.on('alreadyinstalled', function () {
    console.log('⚠️ El servicio ya estaba instalado. Intentando reiniciarlo...');
    svc.start();
});

svc.on('start', function () {
    console.log('🎉 El Agente está corriendo en segundo plano (Background Service).');
    console.log('Ya puedes cerrar esta ventana.');
});

svc.on('error', function (e) {
    console.error('❌ Error gestionando el servicio:', e);
});

// Instalar
console.log('📦 Instalando MangoPOS Agent como Servicio de Windows...');
svc.install();
