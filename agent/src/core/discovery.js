const os = require('os');
const net = require('net');
const dgram = require('dgram');
const { config, logger } = require('../config');
const { exec } = require('child_process');

const { expandCidr, candidateIps } = require('../network/ipv4');
const { getMacForIp } = require('../network/arp');

// El cliente legado de /printers (LocalPrintService.discoverPrinters) espera
// 12 s y, si no llega la respuesta, muestra la lista vacía aunque se hayan
// encontrado impresoras. La red tiene un presupuesto y el USB corre en
// paralelo para que todo quepa con margen.
const NETWORK_SCAN_BUDGET_MS = 7000;
// Una impresora en la LAN responde en milisegundos. Esperar 2 s por cada
// dirección vacía hacía que una /24 tardara ~22 s.
const PROBE_TIMEOUT_MS = 800;
const PROBE_CONCURRENCY = 64;

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
                const protocols = config.discovery.protocols;
                await Promise.all([
                    protocols.includes('network') ? this.scanNetwork() : null,
                    protocols.includes('usb') ? this.scanUSB() : null,
                ]);
                // Mismo orden que cuando corrían en serie: primero red, después USB.
                const rank = (d) => (d.type === 'network' ? 0 : 1);
                return this.discoveredDevices.sort((a, b) => rank(a) - rank(b));
            } finally { this.isScanning = false; }
        })();
        try { return await this.scanPromise; } finally { this.scanPromise = null; }
    }

    async scanUSB() {
        const platform = os.platform();
        if (platform === 'win32') {
            return this.scanUSBWindows();
        } else if (platform === 'darwin') {
            return this.scanUSBMacOS();
        } else if (platform === 'linux') {
            return this.scanUSBLinux();
        }
        logger.warn(`USB scan not supported on platform: ${platform}`);
    }

    async scanUSBWindows() {
        // USB thermal printers on Windows are not always exposed with Service=usbprint.
        // Some drivers show them as generic USB PnP devices but still expose VID/PID.
        const script = "$items = Get-CimInstance Win32_PnPEntity | Where-Object { $_.DeviceID -match '^USB\\\\VID_' -and ($_.Service -eq 'usbprint' -or $_.PNPClass -eq 'Printer' -or $_.Name -match 'POS|Printer|2con|XP-|TM-|Epson|Bixolon|Star|Brother') } | Select-Object Name, DeviceID, Manufacturer, Service, PNPClass; $items | ConvertTo-Json -Compress";
        const cmd = `powershell -NoProfile -ExecutionPolicy Bypass -Command "${script}"`;

        return new Promise((resolve) => {
            exec(cmd, (error, stdout, stderr) => {
                if (error || stderr) {
                    logger.warn(`USB Scan failed: ${error || stderr}`);
                    resolve();
                    return;
                }

                try {
                    const data = JSON.parse(stdout);
                    // Handle single object vs array
                    const devices = Array.isArray(data) ? data : [data];

                    const seen = new Set();
                    devices.forEach(d => {
                        if (!d.DeviceID) return;
                        if (seen.has(d.DeviceID)) return;
                        const name = d.Name || 'Unknown USB Printer';
                        const looksLikePrinter =
                            d.Service === 'usbprint' ||
                            /\bPOS\b|Printer|2con|2C-|XP-|TM-|Epson|Bixolon|Star|Brother/i.test(name);
                        if (!looksLikePrinter) return;
                        seen.add(d.DeviceID);
                        // Extract VID/PID from DeviceID (e.g., USB\VID_2CB7&PID_811B\...)
                        // Format: USB\VID_xxxx&PID_xxxx\serial
                        this.discoveredDevices.push({
                            type: 'usb',
                            name,
                            vid: this.extractVidPid(d.DeviceID, 'VID'),
                            pid: this.extractVidPid(d.DeviceID, 'PID'),
                            deviceId: d.DeviceID,
                            service: d.Service || null,
                            pnpClass: d.PNPClass || null,
                            address: d.DeviceID // Use DeviceID as address/endpoint
                        });
                    });
                } catch (e) {
                    // JSON parse error often means no devices found (empty output)
                }
                resolve();
            });
        });
    }

    async scanUSBMacOS() {
        const cmd = 'system_profiler SPUSBDataType -json 2>/dev/null';
        return new Promise((resolve) => {
            exec(cmd, { maxBuffer: 1024 * 1024 }, (error, stdout) => {
                if (error) {
                    logger.warn(`macOS USB scan failed: ${error.message}`);
                    resolve();
                    return;
                }
                try {
                    const data = JSON.parse(stdout);
                    const items = data.SPUSBDataType || [];
                    const printerPattern = /POS|Printer|2con|XP-|TM-|Epson|Bixolon|Star|Brother/i;
                    const flatten = (nodes) => {
                        for (const node of nodes) {
                            const name = node._name || '';
                            if (printerPattern.test(name)) {
                                const vid = node.vendor_id ? `0x${node.vendor_id.replace(/^0x/i, '')}` : null;
                                const pid = node.product_id ? `0x${node.product_id.replace(/^0x/i, '')}` : null;
                                this.discoveredDevices.push({
                                    type: 'usb',
                                    name,
                                    vid,
                                    pid,
                                    deviceId: `${vid || ''}:${pid || ''}`,
                                    address: node.location_id || `${vid}:${pid}`,
                                });
                            }
                            if (node._items) flatten(node._items);
                        }
                    };
                    flatten(items);
                } catch (e) {
                    logger.warn(`macOS USB parse error: ${e.message}`);
                }
                resolve();
            });
        });
    }

    async scanUSBLinux() {
        const cmd = 'lsusb 2>/dev/null';
        return new Promise((resolve) => {
            exec(cmd, (error, stdout) => {
                if (error) {
                    logger.warn(`Linux USB scan failed: ${error.message}`);
                    resolve();
                    return;
                }
                try {
                    const printerPattern = /POS|Printer|2con|XP-|TM-|Epson|Bixolon|Star|Brother/i;
                    const lines = stdout.trim().split('\n');
                    for (const line of lines) {
                        // Format: Bus 001 Device 003: ID 2cb7:811b Device Name
                        const match = line.match(/ID\s+([0-9a-f]{4}):([0-9a-f]{4})\s+(.*)/i);
                        if (!match) continue;
                        const [, vid, pid, name] = match;
                        if (!printerPattern.test(name) && !printerPattern.test(line)) continue;
                        this.discoveredDevices.push({
                            type: 'usb',
                            name: name.trim() || `USB ${vid}:${pid}`,
                            vid: `0x${vid}`,
                            pid: `0x${pid}`,
                            deviceId: `${vid}:${pid}`,
                            address: `${vid}:${pid}`,
                        });
                    }
                } catch (e) {
                    logger.warn(`Linux USB parse error: ${e.message}`);
                }
                resolve();
            });
        });
    }

    extractVidPid(str, type) {
        const match = str.match(new RegExp(`${type}_([0-9A-F]{4})`, 'i'));
        return match ? `0x${match[1]}` : null;
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
        const budgetMs = this.dependencies.scanBudgetMs ?? NETWORK_SCAN_BUDGET_MS;
        const deadline = Date.now() + budgetMs;
        let index = 0;
        const worker = async () => {
            while (index < targets.length && Date.now() < deadline) {
                const { ip, port } = targets[index++];
                try {
                    if (!(await check(ip, port, PROBE_TIMEOUT_MS))) continue;
                    const mac = await readMac(ip, { probePort: port, forceProbe: false });
                    this.discoveredDevices.push({ type: 'network', name: `Net Printer (${ip})`,
                        address: ip, ip, port, mac, deviceId: mac || null });
                } catch (_) { /* An offline host does not interrupt discovery. */ }
            }
        };
        await Promise.all(Array.from({ length: Math.min(PROBE_CONCURRENCY, targets.length) }, worker));
        if (index < targets.length) {
            // Se devuelve lo encontrado: mejor una lista parcial que una vacía.
            logger.warn(
                `[discovery] búsqueda de red cortada a los ${budgetMs} ms: ` +
                `${targets.length - index} de ${targets.length} direcciones sin revisar`,
            );
        }
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
