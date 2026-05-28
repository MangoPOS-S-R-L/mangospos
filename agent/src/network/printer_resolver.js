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

// ── Cache MAC→IP en memoria ────────────────────────────────────────────────
//
// Sin esta cache, cada fallo de impresión dispara el flujo completo
// (ARP scan → port scan del /24). Cuando varias tablets fallan al mismo
// tiempo (típico cuando una impresora reinicia y todos los cajeros
// reciben ECONNREFUSED a la vez), todos arrancan scans paralelos
// saturando la red.
//
// Con la cache:
//   1. Resolución exitosa por ARP/scan ⇒ guardamos {ip, cachedAt}.
//   2. Siguiente request ⇒ si la entry está dentro del TTL (5 min),
//      devolvemos inmediatamente sin escanear.
//   3. Cuando una impresión falla, el caller invoca invalidateCache(mac)
//      para forzar re-resolución en el próximo intento.
//
// Es un Map en memoria del proceso del agente — no persiste reinicios,
// pero el cliente Flutter ya tiene la última IP buena en Supabase, así
// que el agente vuelve a llenar la cache rápido al primer request.
const RESOLVE_CACHE_TTL_MS = 5 * 60 * 1000;
const _resolveCache = new Map(); // mac → { ip, cachedAt, source }

function readResolveCache(mac) {
    const entry = _resolveCache.get(mac);
    if (!entry) return null;
    if (Date.now() - entry.cachedAt > RESOLVE_CACHE_TTL_MS) {
        _resolveCache.delete(mac);
        return null;
    }
    return entry;
}

function writeResolveCache(mac, ip, source) {
    _resolveCache.set(mac, { ip, cachedAt: Date.now(), source });
}

/**
 * Invalida la entrada de cache para un MAC específico. El caller debe
 * llamar esto cuando un print a la IP cacheada falla — fuerza re-scan
 * en el próximo lookup. Sin esta llamada, una IP stale sigue
 * devolviéndose hasta vencer el TTL.
 */
function invalidateCache(macRaw) {
    const mac = normalizeMac(macRaw);
    if (!mac) return;
    _resolveCache.delete(mac);
}

/** Solo para tests / debugging. */
function _resetCache() {
    _resolveCache.clear();
}

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
async function resolveByMac(targetMacRaw, { logCtx = '', skipMemoryCache = false } = {}) {
    const target = normalizeMac(targetMacRaw);
    if (!target) {
        logger?.warn?.(`[resolver]${logCtx} MAC inválida: ${targetMacRaw}`);
        return null;
    }

    // Fast-fast path: cache en memoria del proceso. Evita pegar al SO
    // (ARP read) y ahorra latencia bajo carga. El caller puede saltar
    // la cache pasando `skipMemoryCache: true` cuando ya sabe que la
    // IP cacheada está stale (típico después de un fallo de impresión
    // que el caller acaba de invalidar).
    if (!skipMemoryCache) {
        const cached = readResolveCache(target);
        if (cached) {
            logger?.info?.(
                `[resolver]${logCtx} hit memory cache: ${target} → ${cached.ip} (orig: ${cached.source})`,
            );
            return { ip: cached.ip, source: 'memory_cache' };
        }
    }

    // Fast path
    const arpHit = await findIpInArpCache(target);
    if (arpHit) {
        logger?.info?.(`[resolver]${logCtx} hit ARP cache: ${target} → ${arpHit}`);
        writeResolveCache(target, arpHit, 'arp_cache');
        return { ip: arpHit, source: 'arp_cache' };
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
            writeResolveCache(target, r.value.ip, 'scan');
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
    invalidateCache,
    _resetCache,
};
