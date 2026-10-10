// MAC identity is available only on the agent's local layer-2 network.
// Commands receive validated IPv4 arguments via execFile, never a shell.
const os = require('os');
const net = require('net');
const { execFile } = require('child_process');

function normalizeMac(raw) {
    if (typeof raw !== 'string') return null;
    const value = raw.trim();
    if (!/^(?:[0-9a-f]{1,2}:){5}[0-9a-f]{1,2}$/i.test(value) &&
        !/^(?:[0-9a-f]{2}-){5}[0-9a-f]{2}$/i.test(value)) return null;
    const octets = value.toLowerCase().split(/[:-]/).map((part) => part.padStart(2, '0'));
    const normalized = octets.join(':');
    if (normalized === '00:00:00:00:00:00' || (parseInt(octets[0], 16) & 1)) return null;
    return normalized;
}

function validIpv4(ip) {
    return typeof ip === 'string' && net.isIP(ip.trim()) === 4;
}

function validPort(port = 9100) {
    const value = Number(port);
    return Number.isInteger(value) && value > 0 && value <= 65535 ? value : null;
}

function parseArpEntries(output) {
    const entries = [];
    for (const line of String(output || '').split(/\r?\n/)) {
        if (/\b(?:incomplete|failed|unreachable)\b/i.test(line)) continue;
        const ip = line.match(/\b(?:\d{1,3}\.){3}\d{1,3}\b/)?.[0];
        if (!validIpv4(ip)) continue;
        const token = line.match(/(?:^|[\s(])((?:[0-9a-f]{1,2}:){5}[0-9a-f]{1,2}|(?:[0-9a-f]{2}-){5}[0-9a-f]{2})(?=$|[\s)])/i)?.[1];
        const mac = normalizeMac(token);
        if (mac) entries.push({ ip, mac });
    }
    return entries;
}

function tcpProbe(ip, port = 9100, timeoutMs = 600, socketFactory = () => new net.Socket()) {
    if (!validIpv4(ip) || !validPort(port)) return Promise.resolve(false);
    return new Promise((resolve) => {
        const socket = socketFactory();
        let settled = false;
        const timer = setTimeout(() => finish(false), timeoutMs);
        const finish = (connected) => {
            if (settled) return;
            settled = true;
            clearTimeout(timer);
            socket.destroy();
            resolve(connected);
        };
        socket.once('connect', () => finish(true));
        socket.once('error', () => finish(false));
        socket.once('close', () => finish(false));
        try { socket.connect(Number(port), ip.trim()); } catch (_) { finish(false); }
    });
}

function capture(command, args, run = execFile) {
    return new Promise((resolve) => {
        run(command, args, { timeout: 1500, windowsHide: true }, (_error, stdout) => {
            resolve(String(stdout || ''));
        });
    });
}

function createArpReader({ platform = os.platform(), run = execFile, probe = tcpProbe } = {}) {
    async function readEntries(ip) {
        let output;
        if (platform === 'win32') output = await capture('arp', ip ? ['-a', ip] : ['-a'], run);
        else if (platform === 'darwin') output = await capture('arp', ip ? ['-n', ip] : ['-an'], run);
        else {
            output = await capture('ip', ip ? ['neigh', 'show', ip] : ['neigh', 'show'], run);
            if (!parseArpEntries(output).length) output = await capture('arp', ip ? ['-n', ip] : ['-n'], run);
        }
        return parseArpEntries(output);
    }
    async function getMacForIp(ip, { probePort = 9100, forceProbe = true } = {}) {
        if (!validIpv4(ip) || !validPort(probePort)) return null;
        const target = ip.trim();
        if (forceProbe) await probe(target, Number(probePort));
        const identity = async () => {
            const matches = new Set((await readEntries(target)).filter((entry) => entry.ip === target).map((entry) => entry.mac));
            // Overlapping interfaces with different neighbors are ambiguous.
            return matches.size === 1 ? [...matches][0] : null;
        };
        let mac = await identity();
        if (!mac && !forceProbe) {
            await probe(target, Number(probePort));
            mac = await identity();
        }
        return mac;
    }
    return { getMacForIp, readEntries };
}

const reader = createArpReader();
module.exports = { normalizeMac, validIpv4, validPort, parseArpEntries, tcpProbe,
    createArpReader, getMacForIp: reader.getMacForIp, readArpEntries: reader.readEntries };
