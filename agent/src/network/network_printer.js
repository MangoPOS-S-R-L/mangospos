const { normalizeMac, validIpv4, validPort } = require('./arp');
const resolver = require('./printer_resolver');
const tcp = require('./tcp');

function createNetworkPrinter({ resolveByMac = resolver.resolveByMac,
    invalidateCache = resolver.invalidateCache, sendRawTcp = tcp.sendRawTcp } = {}) {
    async function resolveTarget(printer = {}, skipMemoryCache = false) {
        const endpoint = typeof printer.endpoint === 'string' ? printer.endpoint.trim().split(':') : [];
        const ip = String(printer.ip || printer.ip_address || printer.ipAddress || endpoint[0] || '').split('/')[0].trim();
        const port = validPort(printer.port ?? endpoint[1] ?? 9100);
        const mac = normalizeMac(printer.mac);
        if (!port || (!mac && !validIpv4(ip))) throw new Error('Invalid printer IPv4/port');
        if (printer.mac && !mac) {
            const err = new Error('Invalid saved printer MAC identity');
            err.code = 'PRINTER_IDENTITY_UNVERIFIED'; err.safeToRetry = false; err.retryable = false;
            throw err;
        }
        if (!mac) return { ip, port, verified: false };
        const resolved = await resolveByMac(mac, { ip, port, skipMemoryCache });
        if (!resolved || resolved.verified !== true || resolved.mac !== mac || resolved.port !== port) {
            const err = new Error('Saved printer MAC could not be verified on the local network');
            err.code = 'PRINTER_IDENTITY_UNVERIFIED'; err.safeToRetry = true; err.retryable = true;
            throw err;
        }
        return resolved;
    }
    async function printNetworkPayload(printer, payload, timeout = 8000) {
        let target = await resolveTarget(printer);
        try { await sendRawTcp(target.ip, target.port, payload, timeout, 1); }
        catch (err) {
            if (!err.safeToRetry || err.deliveryUncertain || !target.mac) throw err;
            invalidateCache(target.mac);
            target = await resolveTarget({ ...printer, ip: target.ip }, true);
            await sendRawTcp(target.ip, target.port, payload, timeout, 1);
        }
        printer.ip = target.ip;
        printer.port = target.port;
        if (printer.endpoint) printer.endpoint = `${target.ip}:${target.port}`;
        return target;
    }
    return { resolveTarget, printNetworkPayload };
}
module.exports = { ...createNetworkPrinter(), createNetworkPrinter };
