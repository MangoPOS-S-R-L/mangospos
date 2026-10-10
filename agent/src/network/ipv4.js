const os = require('os');
const { validIpv4 } = require('./arp');
const MIN_PREFIX = 22;
function expandCidr(cidr) {
    const m = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})(?:\/(\d{1,2}))?$/.exec(String(cidr).trim());
    if (!m) {
        throw new Error('formato esperado a.b.c.d/prefix');
    }
    const octets = [m[1], m[2], m[3], m[4]].map((s) => Number(s));
    if (octets.some((o) => o < 0 || o > 255)) {
        throw new Error('octeto fuera de rango 0-255');
    }
    const prefix = m[5] !== undefined ? Number(m[5]) : 24;
    if (prefix < MIN_PREFIX || prefix > 32) {
        throw new Error(`prefijo /${prefix} fuera de rango [/${MIN_PREFIX}, /32]`);
    }
    const baseInt = ((octets[0] << 24) >>> 0) + (octets[1] << 16) + (octets[2] << 8) + octets[3];
    const mask = prefix === 0 ? 0 : (0xFFFFFFFF << (32 - prefix)) >>> 0;
    const netInt = (baseInt & mask) >>> 0;
    const hostCount = 2 ** (32 - prefix);
    const skipEdges = prefix < 31 ? 1 : 0; // saltar .0 y broadcast en rangos normales
    const ips = [];
    for (let i = skipEdges; i < hostCount - skipEdges; i++) {
        const addr = (netInt + i) >>> 0;
        ips.push(`${(addr >>> 24) & 0xff}.${(addr >>> 16) & 0xff}.${(addr >>> 8) & 0xff}.${addr & 0xff}`);
    }
    return ips;
}

function candidateIps({ interfaces = os.networkInterfaces(), subnets = [], hintIp } = {}) {
    const candidates = new Set();
    if (validIpv4(hintIp)) candidates.add(hintIp.trim());
    for (const list of Object.values(interfaces)) {
        for (const iface of list || []) {
            if ((iface.family !== 'IPv4' && iface.family !== 4) || iface.internal || !validIpv4(iface.address)) continue;
            const cidr = iface.cidr && Number(iface.cidr.split('/')[1]) >= MIN_PREFIX
                ? iface.cidr : `${iface.address}/24`;
            try { expandCidr(cidr).forEach((ip) => candidates.add(ip)); } catch (_) {}
        }
    }
    for (const cidr of subnets) {
        try { expandCidr(cidr).forEach((ip) => candidates.add(ip)); } catch (_) {}
    }
    return Array.from(candidates);
}
module.exports = { expandCidr, candidateIps };
