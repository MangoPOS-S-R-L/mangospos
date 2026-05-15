// PRD 7 Fase 1.0 — Helpers TCP para impresoras de red y health checks.
//
// Hardening contra "se desconectó a mitad de impresión":
//   - Retry interno: el dispatcher reencola jobs, pero la latencia
//     hasta el próximo claim es 2-5s. Un retry inmediato aquí cubre
//     blips de red (~80% de los casos) en <500ms sin que el cajero
//     vea el ticket en espera.
//   - setNoDelay: ESC/POS son ráfagas pequeñas; Nagle puede demorar el
//     corte (GS V) ~200ms y el driver POS asume desconexión.
//   - setKeepAlive: detectar peer muerto durante jobs largos antes que
//     el OS lo deje colgado en FIN_WAIT.
//   - Drain antes de end(): damos tiempo a la térmica a procesar el
//     último corte antes del FIN, evitando truncado.
//   - 'error' event escuchado siempre (no solo en connect): RST/EPIPE
//     post-write asíncronos llegan acá, no al callback de write.

const net = require('net');

const TRANSIENT_CODES = new Set([
    'ECONNRESET',
    'EPIPE',
    'ETIMEDOUT',
    'EHOSTUNREACH',
    'ENETUNREACH',
    'ENETDOWN',
]);

const isTransientError = (err) => {
    if (!err) return false;
    if (err.code && TRANSIENT_CODES.has(err.code)) return true;
    const msg = (err.message || '').toLowerCase();
    return msg.includes('timeout') || msg.includes('reset');
};

const sendRawTcpOnce = (ip, port, payload, timeout) => new Promise((resolve, reject) => {
    const socket = new net.Socket();
    let settled = false;
    let drainTimer = null;
    let connectTimer = null;
    let firstError = null;

    const finish = (err) => {
        if (settled) return;
        settled = true;
        if (connectTimer) clearTimeout(connectTimer);
        if (drainTimer) clearTimeout(drainTimer);
        try { socket.destroy(); } catch (_) {}
        if (err) reject(err);
        else resolve();
    };

    connectTimer = setTimeout(
        () => finish(new Error('connect timeout')),
        timeout,
    );

    socket.once('connect', () => {
        clearTimeout(connectTimer);
        connectTimer = null;
        try {
            socket.setNoDelay(true);
            socket.setKeepAlive(true, 30000);
        } catch (_) {}

        socket.write(payload, (err) => {
            if (err) return finish(err);
            // Drain: dejamos que la térmica consuma el TX buffer
            // (incluyendo el corte) antes del FIN. Sin este pause
            // algunas impresoras truncan el último comando y el ticket
            // sale a la mitad — el cajero lo lee como "se desconectó".
            drainTimer = setTimeout(() => {
                socket.end(() => finish(firstError));
            }, 80);
        });
    });

    socket.on('error', (err) => {
        if (!firstError) firstError = err;
        // Si el error llega antes del connect, fail rápido. Si llega
        // durante el drain, finish() lo propaga via firstError.
        finish(err);
    });

    socket.on('close', () => {
        // close sin error previo = éxito. close tras error ya está
        // cubierto por finish() inicial vía 'error'.
        finish(firstError);
    });

    socket.connect(port, ip);
});

// Envía bytes raw a una impresora TCP (típicamente puerto 9100). Resuelve
// cuando los bytes están escritos y la conexión cerrada. Rechaza con
// Error si todos los intentos fallan.
const sendRawTcp = async (ip, port, payload, timeout = 8000, attempts = 2) => {
    const total = Math.max(1, attempts);
    let lastError = null;
    for (let i = 0; i < total; i++) {
        if (i > 0) {
            await new Promise((r) => setTimeout(r, 300));
        }
        try {
            await sendRawTcpOnce(ip, port, payload, timeout);
            return;
        } catch (err) {
            lastError = err;
            // Si el error no es transitorio y ya hicimos un intento
            // (típicamente ECONNREFUSED = IP/puerto mal, o EACCES),
            // no insistir.
            if (i > 0 && !isTransientError(err)) break;
        }
    }
    throw lastError || new Error('sendRawTcp failed');
};

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
