// PRD-Printing — IP→MAC resolution cross-platform.
//
// Se usa para dos cosas (ver printer_resolver.js):
//   1. Tras un print exitoso, capturar la MAC de la impresora para guardarla
//      en Supabase. Así sobrevivimos cambios de DHCP.
//   2. Al detectar IP inválida, escanear LAN y buscar la impresora por MAC.
//
// Implementación:
//   - Antes de leer la tabla ARP, hacemos un TCP probe corto (puerto 9100) o
//     un ICMP "no-op" para forzar al kernel a resolver ARP si la entrada está
//     stale. Sin esto, una IP no contactada en >60s puede no estar en `arp`.
//   - Parseamos `arp -a <ip>` (Windows/macOS) o `ip neigh show <ip>` (Linux,
//     reemplazo moderno de `arp`).
//   - Normalizamos siempre la MAC a lowercase con separadores `:` para que
//     comparaciones contra Supabase sean determinísticas.

const os = require('os');
const net = require('net');
const { exec } = require('child_process');

const MAC_RE = /([0-9a-f]{2}[:\-]){5}[0-9a-f]{2}/i;

/** Normaliza una MAC a lowercase con `:` (ej: "AA-BB-CC-DD-EE-FF" → "aa:bb:cc:dd:ee:ff"). */
function normalizeMac(raw) {
    if (!raw) return null;
    const m = MAC_RE.exec(String(raw));
    if (!m) return null;
    return m[0].toLowerCase().replace(/-/g, ':');
}

/**
 * Abre y cierra un socket TCP al destino para forzar al SO a resolver ARP.
 * No escribe nada (es solo CONNECT/RST). Si el puerto está cerrado pero el
 * host responde, igual se popula ARP — perfecto para nuestro caso.
 *
 * Resuelve siempre (no throw), independiente del resultado del connect.
 */
function tcpProbe(ip, port = 9100, timeoutMs = 600) {
    return new Promise((resolve) => {
        const sock = new net.Socket();
        let done = false;
        const finish = () => {
            if (done) return;
            done = true;
            try { sock.destroy(); } catch (_) {}
            resolve();
        };
        sock.setTimeout(timeoutMs, finish);
        sock.once('connect', finish);
        sock.once('error', finish);
        try {
            sock.connect(port, ip);
        } catch (_) {
            finish();
        }
    });
}

function execCapture(cmd, timeoutMs = 1500) {
    return new Promise((resolve) => {
        exec(cmd, { timeout: timeoutMs, windowsHide: true }, (err, stdout) => {
            // Ignoramos err — los comandos arp suelen exit 1 cuando no hay entry,
            // pero igual queremos parsear stdout (a veces traen info parcial).
            resolve(String(stdout || ''));
        });
    });
}

/**
 * Linux: `ip neigh show <ip>` → "10.0.0.5 dev wlan0 lladdr aa:bb:cc:dd:ee:ff REACHABLE".
 * Fallback a `arp -n <ip>` si `ip` no está instalado (containers minimos).
 */
async function getMacLinux(ip) {
    let out = await execCapture(`ip neigh show ${ip}`);
    let mac = normalizeMac(out);
    if (mac) return mac;
    out = await execCapture(`arp -n ${ip}`);
    return normalizeMac(out);
}

/**
 * macOS: `arp -n <ip>` → "? (10.0.0.5) at aa:bb:cc:dd:ee:ff on en0 ifscope [ethernet]".
 * `-n` evita reverse DNS (rápido).
 */
async function getMacMac(ip) {
    const out = await execCapture(`arp -n ${ip}`);
    return normalizeMac(out);
}

/**
 * Windows: `arp -a <ip>` → tabla con columnas "Internet Address", "Physical
 * Address", "Type". El MAC viene con separadores `-` que normalizeMac maneja.
 */
async function getMacWindows(ip) {
    const out = await execCapture(`arp -a ${ip}`);
    return normalizeMac(out);
}

/**
 * Resuelve la MAC para una IP. Si no la encuentra en cache ARP, hace TCP
 * probe primero y reintenta. Devuelve la MAC normalizada o null.
 */
async function getMacForIp(ip, { probePort = 9100 } = {}) {
    if (!ip) return null;
    const platform = os.platform();
    const lookup = platform === 'win32'
        ? getMacWindows
        : platform === 'darwin'
            ? getMacMac
            : getMacLinux;

    let mac = await lookup(ip);
    if (mac) return mac;

    // No estaba en cache. Forzar resolución ARP con probe TCP y reintentar.
    await tcpProbe(ip, probePort);
    mac = await lookup(ip);
    return mac; // puede ser null si el host realmente no responde
}

module.exports = {
    normalizeMac,
    getMacForIp,
    tcpProbe,
};
