// Resolve the saved physical identity before submitting ANY ticket bytes.
// Cached IPs and ARP candidates are hints: both MAC and TCP port are checked.
const os = require('os');
const arp = require('./arp');
const { candidateIps } = require('./ipv4');

function createPrinterResolver(dependencies = {}) {
    const getMacForIp = dependencies.getMacForIp || arp.getMacForIp;
    const readArpEntries = dependencies.readArpEntries || arp.readArpEntries;
    const checkPort = dependencies.checkPort || arp.tcpProbe;
    const getInterfaces = dependencies.getInterfaces || os.networkInterfaces;
    const getSubnets = dependencies.getSubnets || (() => require('../config').config.discovery?.subnets || []);
    const now = dependencies.now || Date.now;
    const cache = new Map();
    const pending = new Map();
    const ttlMs = dependencies.ttlMs || 5 * 60 * 1000;
    const concurrency = dependencies.concurrency || 24;

    const invalidateCache = (raw) => {
        const mac = arp.normalizeMac(raw);
        for (const key of cache.keys()) if (key.startsWith(`${mac}|`)) cache.delete(key);
    };
    const verify = async (ip, mac, port, timeoutMs) => {
        if (!arp.validIpv4(ip) || !(await checkPort(ip, port, timeoutMs))) return false;
        return arp.normalizeMac(await getMacForIp(ip, { probePort: port, forceProbe: false })) === mac;
    };
    async function resolveByMac(raw, options = {}) {
        const mac = arp.normalizeMac(raw);
        const port = arp.validPort(options.port ?? 9100);
        if (!mac || !port) return null;
        const key = `${mac}|${port}`;
        if (options.skipMemoryCache || options.skipCache) cache.delete(key);
        if (pending.has(key)) return pending.get(key);
        const task = resolve(mac, port, key, options);
        pending.set(key, task);
        try { return await task; } finally { pending.delete(key); }
    }
    async function resolve(mac, port, key, options) {
        const deadline = now() + Math.min(Math.max(Number(options.timeoutMs) || 12000, 100), 15000);
        const tried = new Set();
        const attempt = async (ip, source) => {
            if (!arp.validIpv4(ip) || tried.has(ip) || now() >= deadline) return null;
            tried.add(ip);
            try {
                if (!(await verify(ip, mac, port, Math.min(600, Math.max(1, deadline - now()))))) return null;
                return { mac, ip: ip.trim(), port, source, verified: true };
            } catch (_) { return null; }
        };
        const matches = new Map();
        const include = (result) => { if (result) matches.set(result.ip, result); };
        const accept = () => {
            if (matches.size !== 1) { cache.delete(key); return null; }
            const result = [...matches.values()][0];
            cache.set(key, { result, time: now() });
            return result;
        };
        const cached = cache.get(key);
        if (cached && now() - cached.time <= ttlMs) {
            include(await attempt(cached.result.ip, 'memory_cache'));
        }
        cache.delete(key);
        const hint = options.ip || options.hintIp;
        include(await attempt(hint, 'configured_ip'));
        let entries;
        try { entries = await readArpEntries(); } catch (_) { entries = []; }
        // A live hint avoids a full scan, but known conflicting identities
        // must still be checked before accepting that destination.
        for (const entry of entries) {
            if (arp.normalizeMac(entry.mac) === mac) include(await attempt(entry.ip, 'arp_cache'));
        }
        if (matches.size) return accept();
        let ips;
        try { ips = candidateIps({ interfaces: getInterfaces(), subnets: getSubnets(), hintIp: hint }); }
        catch (_) { ips = candidateIps({ interfaces: getInterfaces(), hintIp: hint }); }
        let index = 0;
        let found = null;
        const worker = async () => {
            while (!found && index < ips.length && now() < deadline) {
                const ip = ips[index++];
                const result = await attempt(ip, 'scan');
                if (result) {
                    include(result);
                    if (!found) found = result;
                }
            }
        };
        await Promise.all(Array.from({ length: Math.min(concurrency, ips.length) }, worker));
        return accept();
    }
    return { resolveByMac, invalidateCache, _resetCache: () => cache.clear() };
}

const resolver = createPrinterResolver();
module.exports = { ...resolver, createPrinterResolver, candidateIps,
    findIpInArpCache: async (raw) => {
        const mac = arp.normalizeMac(raw);
        return (await arp.readArpEntries()).find((entry) => entry.mac === mac)?.ip || null;
    } };
