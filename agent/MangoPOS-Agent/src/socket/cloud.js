// PRD 7 Fase 1.0 — Cliente Socket.IO al backend cloud.
//
// Recibe jobs por evento `print-job` y los procesa secuencialmente.
// PRD 7 Fase 1.1 reemplazará el procesamiento directo por encolado en
// SQLite con idempotencia.
//
// En el deploy actual (LAN-only) este socket está dormido salvo que
// se configure BACKEND_URL + AUTH_TOKEN.

const io = require('socket.io-client');
const { logger, SERVER_URL, AGENT_ID, AGENT_NAME, AUTH_TOKEN } = require('../config');
const { processPrintJob } = require('../print/job_processor');

const startCloudSocket = () => {
    logger.info(`Conectando a ${SERVER_URL}...`);

    const socket = io(SERVER_URL, {
        auth: {
            token: AUTH_TOKEN,
            agentId: AGENT_ID,
        },
        reconnection: true,
        reconnectionAttempts: Infinity,
        reconnectionDelay: 1000,
    });

    socket.on('connect', () => {
        logger.info('Conectado al servidor Cloud');
        socket.emit('register-agent', {
            id: AGENT_ID,
            name: AGENT_NAME,
            status: 'online',
            system: {
                platform: process.platform,
                arch: process.arch,
            },
        });
    });

    socket.on('disconnect', (reason) => {
        logger.warn(`Desconectado: ${reason}`);
    });

    socket.on('connect_error', (error) => {
        logger.error(`Error de conexion: ${error.message}`);
    });

    socket.on('print-job', async (job, ack) => {
        logger.info(`Recibido trabajo de impresion: ${job.id}`);
        try {
            await processPrintJob(job);
            if (ack) ack({ status: 'success', jobId: job.id });
            logger.info(`Trabajo ${job.id} completado`);
        } catch (error) {
            logger.error(`Error imprimiendo trabajo ${job.id}: ${error.message}`);
            if (ack) ack({ status: 'error', jobId: job.id, message: error.message });
        }
    });

    return socket;
};

module.exports = { startCloudSocket };
