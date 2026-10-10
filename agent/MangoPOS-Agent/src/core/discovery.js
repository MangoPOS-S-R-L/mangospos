const os = require('os');
const net = require('net');
const dgram = require('dgram');
const { config, logger } = require('../config');
const { exec } = require('child_process');

const { expandCidr, candidateIps } = require('../network/ipv4');
const { getMacForIp } = require('../network/arp');

class DiscoveryService {
    constructor(dependencies = {}) {
        this.dependencies = dependencies;
        this.scanPromise = null;
        this.discoveredDevices = [];
        this.isScanning = false;
    }

    async scan() {
        if (this.scanPromise) return this.scanPromise;
        this.isScanning = true;
        this.discoveredDevices = [];
        this.scanPromise = (async () => {
            try {
                if (config.discovery.protocols.includes('network')) await this.scanNetwork();
                if (config.discovery.protocols.includes('usb')) logger.info('USB scan placeholder');
                return this.discoveredDevices;
            } finally { this.isScanning = false; }
        })();
        try { return await this.scanPromise; } finally { this.scanPromise = null; }
    }

    async scanNetwork() {
        const getCandidates = this.dependencies.candidateIps || candidateIps;
        const readMac = this.dependencies.getMacForIp || getMacForIp;
        const check = this.dependencies.checkPort || this.checkPort.bind(this);
        const ips = getCandidates({ subnets: config.discovery?.subnets || [] });
        const ports = new Set([9100]);
        for (const printer of config.printers || []) {
            const port = Number(printer.port || String(printer.endpoint || '').split(':')[1]);
            if (Number.isInteger(port) && port > 0 && port <= 65535) ports.add(port);
        }
        const targets = ips.flatMap((ip) => [...ports].map((port) => ({ ip, port })));
        let index = 0;
        const worker = async () => {
            while (index < targets.length) {
                const { ip, port } = targets[index++];
                try {
                    if (!(await check(ip, port))) continue;
                    const mac = await readMac(ip, { probePort: port, forceProbe: false });
                    this.discoveredDevices.push({ type: 'network', name: `Net Printer (${ip})`,
                        address: ip, ip, port, mac, deviceId: mac || null });
                } catch (_) { /* An offline host does not interrupt discovery. */ }
            }
        };
        await Promise.all(Array.from({ length: Math.min(24, targets.length) }, worker));
    }

    checkPort(ip, port, timeout = 2000) {
        return new Promise((resolve, reject) => {
            const socket = new net.Socket();
            socket.setTimeout(timeout);
            socket.on('connect', () => {
                socket.destroy();
                resolve(ip);
            });
            socket.on('timeout', () => {
                socket.destroy();
                reject('timeout');
            });
            socket.on('error', (err) => {
                socket.destroy();
                reject(err);
            });
            socket.connect(port, ip);
        });
    }
}

module.exports = new DiscoveryService();
module.exports.DiscoveryService = DiscoveryService;
module.exports.expandCidr = expandCidr;
