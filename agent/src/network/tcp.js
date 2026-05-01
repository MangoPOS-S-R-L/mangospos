// PRD 7 Fase 1.0 — Helpers TCP para impresoras de red y health checks.

const net = require('net');

// Envía bytes raw a una impresora TCP (típicamente puerto 9100). Resuelve
// cuando los bytes están escritos y la conexión cerrada. Rechaza con
// Error si hay timeout o falla de socket.
const sendRawTcp = (ip, port, payload, timeout = 8000) => new Promise((resolve, reject) => {
    const socket = new net.Socket();
    let settled = false;
    const finish = (err) => {
        if (settled) return;
        settled = true;
        try { socket.destroy(); } catch (_) {}
        err ? reject(err) : resolve();
    };

    const timer = setTimeout(() => finish(new Error('connect timeout')), timeout);
    socket.once('connect', () => {
        clearTimeout(timer);
        socket.write(payload, (err) => {
            if (err) return finish(err);
            socket.end(() => finish());
        });
    });
    socket.once('error', (err) => {
        clearTimeout(timer);
        finish(err || new Error('socket error'));
    });
    socket.connect(port, ip);
});

// Chequea si una impresora responde en TCP. Resuelve true/false (no
// rechaza) — útil para health checks paralelos.
const checkPrinterStatus = (ip, port, timeout = 1500) => new Promise((resolve) => {
    const socket = new net.Socket();
    let status = false;

    socket.setTimeout(timeout);
    socket.on('connect', () => {
        status = true;
        socket.destroy();
    });
    socket.on('timeout', () => socket.destroy());
    socket.on('error', () => socket.destroy());
    socket.on('close', () => resolve(status));
    socket.connect(port, ip);
});

module.exports = { sendRawTcp, checkPrinterStatus };
