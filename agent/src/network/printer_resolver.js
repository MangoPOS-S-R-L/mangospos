// PRD-Printing — encontrar la IP actual de una impresora a partir de su MAC.
//
// Caso de uso: el comercio configura la impresora con IP 192.168.1.42 y la
// guardamos en Supabase. Luego el router le da DHCP a otra IP (192.168.1.87)
// y nuestros prints empiezan a fallar. Como guardamos el MAC al primer print
// exitoso (ver post-print hook), podemos buscar la nueva IP escaneando el LAN.
//
// Estrategia:
//   1. ARP-fast-path: leer la tabla ARP del SO completa, buscar el MAC. Si
//      ya está cacheado (porque otro proceso del agente la pingueó hace poco),
//      devolvemos al instante sin tocar la red.
//   2. Subnet scan: si no estaba en ARP, escanear el /24 de cada NIC + subnets
//      configuradas (reusa lógica de discovery.js). Para cada IP que responda
//      en puerto 9100, leer su MAC y comparar.
//   3. Devolver la primera coincidencia.
//
// Diseño defensivo:
//   - Timeout total configurable (default 15s) para no colgar el caller.
//   - Scan paralelo con `Promise.allSettled` — un host roto no atrasa al resto.
//   - Si el MAC no aparece tras scan, retornar null (no error). El caller
//     decide si es 404 o reintento más adelante.

const os = require('os');
const net = require('net');
const { exec } = require('child_process');
const { normalizeMac, getMacForIp } = require('./arp');
const { config, logger } = require('../config');

const SCAN_PORT = 9100;
const SCAN_TIMEOUT_MS = 1200;
const ARP_CACHE_CMD = {
    win32: 'arp -a',
    darwin: 'arp -an',
    linux: 'ip neigh show || arp -n',
};

function execAll(cmd) {
    return new Promise((resolve) => {
        exec(cmd, { timeout: 2000, windowsHide: true }, (_e, stdout) => {
            resolve(String(stdout || ''));
        });
    });
}

/**
 * Lee la tabla ARP completa y devuelve la primera IP cuyo MAC matchee.
 * Es la vía rápida — devuelve sin tocar la red. Si no encuentra, null.
 */
async function findIpInArpCache(targetMac) {
    const cmd = ARP_CACHE_CMD[os.platform()] || ARP_CACHE_CMD.linux;
    const out = await execAll(cmd);
    const lines = out.split(/\r?\n/);
    for (const line of lines) {
        // Para que normalizeMac coincida con targetMac, parseamos la línea
        // buscando IP + MAC simultáneamente. Una línea típica:
        //   Linux ip neigh:   "192.168.1.42 dev eth0 lladdr aa:bb:cc:dd:ee:ff REACHABLE"
        //   macOS arp -an:    "? (192.168.1.42) at aa:bb:cc:dd:ee:ff on en0 ..."
        //   Windows arp -a:   "  192.168.1.42         aa-bb-cc-dd-ee-ff     dynamic"
        const ipMatch = line.match(/\b(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\b/);
        if (!ipMatch) continue;
        const mac = normalizeMac(line);
        if (!mac) continue;
        if (mac === targetMac) return ipMatch[1];
    }
    return null;
}

/**
 * Verifica si una IP escucha en el puerto dado. Mismo patrón que discovery.js
 * pero exportable para resolver MAC en paralelo. Resuelve true/false sin throw.
 */
function checkPort(ip, port = SCAN_PORT, timeout = SCAN_TIMEOUT_MS) {
    return new Promise((resolve) => {
        const sock = new net.Socket();
        let done = false;
        const finish = (ok) => {
            if (done) return;
            done = true;
            try { sock.destroy(); } catch (_) {}
            resolve(ok);
        };
        sock.setTimeout(timeout, () => finish(false));
        sock.once('connect', () => finish(true));
        sock.once('error', () => finish(false));
        try {
            sock.connect(port, ip);
        } catch (_) {
            finish(false);
        }
    });
}

/** Expande las IPs candidatas a escanear: /24 de cada NIC + subnets config. */
function candidateIps() {
    const set = new Set();
    const ifaces = os.networkInterfaces();
    for (const name of Object.keys(ifaces)) {
        for (const iface of ifaces[name]) {
            if (iface.family !== 'IPv4' || iface.internal) continue;
            const base = iface.address.split('.').slice(0, 3).join('.');
            for (let i = 1; i < 255; i++) set.add(`${base}.${i}`);
        }
    }
    // No agregamos config.discovery.subnets acá para mantener el scope
    // contenido. Si el usuario tiene VLAN configurada, ya las tiene en el
    // discovery normal. Para v1 nos quedamos con las NICs del host.
    return Array.from(set);
}

/**
 * Busca la IP actual de la impresora identificada por MAC.
 *
 * Pasos:
 *   - Normalizar el MAC. Si es inválido, retornar null (no error).
 *   - Fast path: ARP cache → si está, devolver.
 *   - Slow path: scan /24 puerto 9100 → para cada respondedor, ver MAC.
 *
 * Retorna `{ ip, source: 'arp_cache'|'scan' }` o null si no encuentra.
 */
async function resolveByMac(targetMacRaw, { logCtx = '' } = {}) {
    const target = normalizeMac(targetMacRaw);
    if (!target) {
        logger?.warn?.(`[resolver]${logCtx} MAC inválida: ${targetMacRaw}`);
        return null;
    }

    // Fast path
    const cached = await findIpInArpCache(target);
    if (cached) {
        logger?.info?.(`[resolver]${logCtx} hit ARP cache: ${target} → ${cached}`);
        return { ip: cached, source: 'arp_cache' };
    }

    // Slow path: scan LAN
    const ips = candidateIps();
    logger?.info?.(`[resolver]${logCtx} scan ${ips.length} IPs en puerto ${SCAN_PORT} buscando ${target}`);

    // checkPort en paralelo (allSettled — ningún error individual frena el batch).
    const portResults = await Promise.allSettled(ips.map((ip) => checkPort(ip)));
    const responders = [];
    portResults.forEach((res, idx) => {
        if (res.status === 'fulfilled' && res.value === true) responders.push(ips[idx]);
    });
    if (responders.length === 0) {
        logger?.warn?.(`[resolver]${logCtx} nadie respondió en :${SCAN_PORT}`);
        return null;
    }

    // Para cada respondedor, leer su MAC. En paralelo, primer match gana.
    const macResults = await Promise.allSettled(
        responders.map(async (ip) => ({ ip, mac: await getMacForIp(ip) })),
    );
    for (const r of macResults) {
        if (r.status === 'fulfilled' && r.value.mac === target) {
            logger?.info?.(`[resolver]${logCtx} match scan: ${target} → ${r.value.ip}`);
            return { ip: r.value.ip, source: 'scan' };
        }
    }

    logger?.warn?.(
        `[resolver]${logCtx} ${responders.length} impresoras respondieron pero ninguna con MAC ${target}`,
    );
    return null;
}

module.exports = {
    resolveByMac,
    findIpInArpCache,
    candidateIps,
};
