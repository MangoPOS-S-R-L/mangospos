const io = require('socket.io-client');
const winston = require('winston');
require('dotenv').config();

// Configuración de Logging
const logger = winston.createLogger({
    level: process.env.LOG_LEVEL || 'info',
    format: winston.format.combine(
        winston.format.timestamp(),
        winston.format.json()
    ),
    transports: [
        new winston.transports.Console({
            format: winston.format.simple(),
        }),
        new winston.transports.File({ filename: 'agent.log' }),
    ],
});

// Configuración
const SERVER_URL = process.env.BACKEND_URL || 'http://localhost:3000';
const AGENT_ID = process.env.AGENT_ID || 'unknown-agent';

logger.info(`🚀 Iniciando MangoPOS Print Agent [${AGENT_ID}]`);
logger.info(`📡 Conectando a ${SERVER_URL}...`);

// Conexión Socket.IO
const socket = io(SERVER_URL, {
    auth: {
        token: process.env.AUTH_TOKEN,
        agentId: AGENT_ID
    },
    reconnection: true,
    reconnectionAttempts: Infinity,
    reconnectionDelay: 1000,
});

// Manejo de Eventos de Conexión
socket.on('connect', () => {
    logger.info('✅ Conectado al servidor Cloud');
    registerAgent();
});

socket.on('disconnect', (reason) => {
    logger.warn(`❌ Desconectado: ${reason}`);
});

socket.on('connect_error', (error) => {
    logger.error(`⚠️ Error de conexión: ${error.message}`);
});

// Manejo de Trabajos de Impresión
socket.on('print-job', async (job, ack) => {
    logger.info(`🖨️ Recibido trabajo de impresión: ${job.id}`);

    try {
        await processPrintJob(job);

        // Confirmar éxito al servidor
        if (ack) ack({ status: 'success', jobId: job.id });
        logger.info(`✅ Trabajo ${job.id} completado`);

    } catch (error) {
        logger.error(`🔥 Error imprimiendo trabajo ${job.id}: ${error.message}`);

        // Reportar error
        if (ack) ack({ status: 'error', jobId: job.id, message: error.message });
    }
});

function registerAgent() {
    socket.emit('register-agent', {
        id: AGENT_ID,
        name: process.env.AGENT_NAME,
        status: 'online',
        system: {
            platform: process.platform,
            arch: process.arch
        }
    });
}

// Lógica de Impresión Real
const escpos = require('escpos');
escpos.Network = require('escpos-network');
escpos.USB = require('escpos-usb');

async function processPrintJob(job) {
    return new Promise(async (resolve, reject) => {
        logger.info(`📄 Procesando job ${job.id} tipo: ${job.printer?.type || 'unknown'}`);

        const content = job.content;
        const printerConfig = job.printer; // { type: 'network', ip: '192.168.x.x', port: 9100 }

        if (!printerConfig) {
            return reject(new Error("No printer configuration provided in job"));
        }

        try {
            let device;

            // 1. Selector de Adapters (Network vs USB)
            if (printerConfig.type === 'network') {
                if (!printerConfig.ip) throw new Error("IP Address missing for network printer");

                // Sanitize IP (remove /32 or similar if presents)
                const sanitizedIp = printerConfig.ip.split('/')[0];

                logger.info(`🔌 Conectando a impresora de red: ${sanitizedIp}:${printerConfig.port || 9100}`);
                device = new escpos.Network(sanitizedIp, printerConfig.port || 9100);
            }
            else if (printerConfig.type === 'usb') {
                // TODO: Implementar selección USB específica si es necesario
                device = new escpos.USB();
            }
            else {
                // Fallback a consola para debug
                logger.info("⚠️ Usando Consola (Printer Type no reconocido o 'test')");
                device = new escpos.Console();
            }

            const printer = new escpos.Printer(device);

            device.open(async function (error) {
                if (error) {
                    logger.error(`❌ Error abriendo conexión con impresora: ${error}`);
                    return reject(error);
                }

                try {
                    // NEW: Pre-Check Logic
                    if (content.type === 'precheck') {
                        await printPreCheck(printer, content.data);
                    }
                    // Legacy/Generic Logic
                    else {
                        printer
                            .font('a')
                            .align('ct')
                            .style('bu')
                            .size(1, 1)
                            .text(content.title || 'Mango POS')
                            .style('reset')
                            .feed(1);

                        if (content.body) {
                            printer.text(content.body);
                        }

                        // Si vienen lineas estructuradas (items de venta)
                        if (content.lines && Array.isArray(content.lines)) {
                            printer.align('lt');
                            content.lines.forEach(line => {
                                printer.text(line);
                            });
                        }

                        printer
                            .feed(2)
                            .cut()
                            .close();
                    }

                    resolve();

                } catch (err) {
                    // printer.close(); // Sometimes causing double close issues if cut already closed
                    try { printer.close(); } catch (e) { }
                    reject(err);
                }
            });

        } catch (e) {
            reject(e);
        }
    });
}

// Helper: Formato Moneda
function fmt(num) {
    return (num || 0).toFixed(2);
}

// Helper: Lógica específica de Pre-Cuenta
async function printPreCheck(printer, data) {
    return new Promise(async (resolve, reject) => {
        try {
            logger.info('🖨️ Datos de Pre-Cuenta recibidos:', JSON.stringify(data, null, 2));

            // Modo ultra-simple para debugging
            printer.text(data.restaurantName || 'REST. MANGO POS');
            printer.text('RNC: ' + (data.rnc || '000-00000-0'));
            printer.text('Tel: ' + (data.phone || '809-555-0000'));
            printer.feed(1);

            printer.text(data.title || '*** PRE-CUENTA ***');
            printer.feed(1);

            printer.text('Mesa: ' + (data.tableName || 'N/A'));
            printer.text('Mesero: ' + (data.waiterName || 'N/A'));
            printer.text('Fecha: ' + new Date().toLocaleString('es-DO'));
            printer.feed(1);

            printer.text('CANT  DESCRIPCION         TOTAL');
            printer.text('--------------------------------');

            if (data.items && Array.isArray(data.items)) {
                data.items.forEach(item => {
                    // Formato simple: "1 x Producto - 100.00"
                    const line = `${item.quantity} x ${item.name} - ${fmt(item.price)}`;
                    printer.text(line);
                });
            } else {
                printer.text('(Sin items)');
            }

            printer.text('--------------------------------');
            printer.feed(1);

            printer.text('SUBTOTAL: ' + fmt(data.subtotal));
            printer.text('ITBIS: ' + fmt(data.tax));
            printer.text('TOTAL: ' + fmt(data.total));
            printer.feed(2);

            printer.text('Gracias por su visita');
            printer.feed(3);

            // Cut y Close al final
            printer.cut();
            printer.close();

            resolve();
        } catch (e) {
            logger.error(`❌ Error en printPreCheck logic: ${e.message}`);
            // Intentar cerrar en caso de error para liberar recurso
            try { printer.close(); } catch (err) { }
            reject(e);
        }
    });
}

// ==========================================
// SERVIDOR HTTP LOCAL (API para Flutter Web)
// ==========================================
const express = require('express');
const cors = require('cors');
const net = require('net'); // Para chequear conectividad TCP de impresoras

const app = express();
const LOCAL_PORT = 4000;

app.use(cors({
    origin: true, // Allow all origins
    credentials: true,
    methods: ['GET', 'POST', 'OPTIONS'],
    allowedHeaders: ['Content-Type', 'Authorization', 'Access-Control-Allow-Private-Network'],
}));

// Middleware para Private Network Access (Chrome/Edge)
app.use((req, res, next) => {
    res.setHeader("Access-Control-Allow-Private-Network", "true");
    next();
});

app.use(express.json());

// 1. Endpoint de Estado (Health Check)
app.get('/status', (req, res) => {
    res.json({
        status: 'online',
        agent: AGENT_ID,
        version: '1.0.0'
    });
});

// 2. Endpoint de Verificación de Impresoras (Ping)
app.post('/check-connectivity', async (req, res) => {
    const { printers } = req.body; // Espera array de { ip, port }

    if (!printers || !Array.isArray(printers)) {
        return res.status(400).json({ error: 'Invalid printers list' });
    }

    const results = {};

    // Chequear cada impresora en paralelo
    await Promise.all(printers.map(async (p) => {
        if (!p.ip) return;
        const isOnline = await checkPrinterStatus(p.ip, p.port || 9100);
        results[p.ip] = isOnline;
    }));

    res.json({ results });
});

// 3. Endpoint de Impresión Directa (Local)
app.post('/print', async (req, res) => {
    const job = req.body;
    if (!job.id) job.id = `LOCAL-${Date.now()}`;

    try {
        logger.info(`📥 Recibida petición local de impresión: ${job.id}`);
        await processPrintJob(job);
        res.json({ success: true, jobId: job.id });
    } catch (error) {
        logger.error(`❌ Error en impresión local: ${error.message}`);
        res.status(500).json({ success: false, error: error.message });
    }
});

// Función auxiliar para chequear puertos TCP
function checkPrinterStatus(ip, port, timeout = 1500) {
    return new Promise((resolve) => {
        const socket = new net.Socket();
        let status = false;

        socket.setTimeout(timeout);

        socket.on('connect', () => {
            status = true;
            socket.destroy();
        });

        socket.on('timeout', () => {
            socket.destroy();
        });

        socket.on('error', (err) => {
            socket.destroy();
        });

        socket.on('close', () => {
            resolve(status);
        });

        socket.connect(port, ip);
    });
}

// Iniciar Servidor HTTP
app.listen(LOCAL_PORT, () => {
    logger.info(`🌍 Local API escuchando en http://localhost:${LOCAL_PORT}`);
});

// ==========================================
// Mantener proceso vivo
// ==========================================
process.on('uncaughtException', (err) => {
    logger.error('CRITICAL ERROR:', err);
});
