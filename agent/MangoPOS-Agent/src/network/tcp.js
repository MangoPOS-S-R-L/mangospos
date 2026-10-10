// Retry only before bytes have been submitted. Once writing starts, failure
// means uncertain delivery and must be reviewed rather than replayed.
const net = require('net');
const { validIpv4, validPort, tcpProbe } = require('./arp');

function deliveryError(error, writeStarted) {
    const err = error instanceof Error ? error : new Error(String(error));
    err.deliveryUncertain = Boolean(writeStarted);
    err.retryable = !writeStarted;
    err.safeToRetry = !writeStarted;
    if (writeStarted) err.code = 'DELIVERY_UNCERTAIN';
    return err;
}

function createTcpSender({ socketFactory = () => new net.Socket(), drainMs = 80, retryDelayMs = 300 } = {}) {
    function sendRawTcpOnce(ip, port, payload, timeout) {
        return new Promise((resolve, reject) => {
            let socket;
            let settled = false;
            let writeStarted = false;
            let drainTimer;
            const finish = (error) => {
                if (settled) return;
                settled = true;
                clearTimeout(deadline);
                clearTimeout(drainTimer);
                try { socket?.destroy(); } catch (_) {}
                if (error) reject(deliveryError(error, writeStarted)); else resolve();
            };
            const deadline = setTimeout(() => {
                const error = new Error(writeStarted ? 'Print delivery timeout' : 'Printer connect timeout');
                error.code = 'ETIMEDOUT';
                finish(error);
            }, timeout);
            try {
                socket = socketFactory();
                socket.once('connect', () => {
                    try {
                        socket.setNoDelay(true);
                        socket.setKeepAlive(true, 30000);
                        writeStarted = true;
                        socket.write(payload, (error) => {
                            if (settled) return;
                            if (error) return finish(error);
                            drainTimer = setTimeout(() => {
                                try { socket.end(() => finish()); } catch (err) { finish(err); }
                            }, drainMs);
                        });
                    } catch (err) { finish(err); }
                });
                socket.on('error', finish);
                socket.once('close', () => {
                    if (!settled) {
                        const error = new Error('Printer connection closed before delivery completed');
                        error.code = 'ECONNRESET';
                        finish(error);
                    }
                });
                socket.connect(port, ip);
            } catch (err) { finish(err); }
        });
    }
    async function sendRawTcp(ip, port, payload, timeout = 8000, attempts = 2) {
        if (!validIpv4(ip) || !validPort(port)) {
            const err = deliveryError(new Error('Invalid printer IPv4/port'), false);
            err.retryable = false;
            err.safeToRetry = false;
            throw err;
        }
        const total = Math.min(3, Math.max(1, Number(attempts) || 1));
        for (let i = 0; i < total; i++) {
            try { return await sendRawTcpOnce(ip.trim(), Number(port), payload, timeout); }
            catch (err) {
                if (!err.safeToRetry || i + 1 === total) throw err;
                await new Promise((resolve) => setTimeout(resolve, retryDelayMs));
            }
        }
    }
    return { sendRawTcp, sendRawTcpOnce };
}
module.exports = { ...createTcpSender(), createTcpSender, deliveryError,
    checkPrinterStatus: (ip, port, timeout = 1500) => tcpProbe(ip, port, timeout) };
