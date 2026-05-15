const os = require('os');
const net = require('net');
const dgram = require('dgram');
const { config, logger } = require('../config');
const { exec } = require('child_process');

// Expande un CIDR IPv4 a las IPs escaneables (excluye network y broadcast
// para prefijos < /31). Rechaza prefijos < /22 (mas de 1024 hosts) para
// no saturar sockets ni el OS — los locales POS no necesitan rangos mas
// grandes; si alguien declara un /16 probablemente es un error.
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

class DiscoveryService {
    constructor() {
        this.discoveredDevices = [];
        this.isScanning = false;
    }

    async scan() {
        if (this.isScanning) return this.discoveredDevices;
        this.isScanning = true;
        this.discoveredDevices = [];

        logger.info('Starting discovery scan...');

        // 1. Scan Network (Port 9100)
        if (config.discovery.protocols.includes('network')) {
            await this.scanNetwork();
        }

        // 2. Scan USB (platform-aware)
        if (config.discovery.protocols.includes('usb')) {
            await this.scanUSB();
        }

        this.isScanning = false;
        return this.discoveredDevices;
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
        // Recolectamos IPs candidatas desde dos fuentes:
        //   1) /24 de cada NIC IPv4 no-interna del host (comportamiento legado).
        //   2) subredes CIDR adicionales declaradas en config.yaml
        //      (discovery.subnets). Util cuando el agent corre en una PC
        //      que NO tiene IP en la red de impresoras (VLAN separada).
        // Se deduplica antes de escanear para evitar trabajo doble.
        const candidates = new Set();

        const interfaces = os.networkInterfaces();
        Object.keys(interfaces).forEach((ifname) => {
            interfaces[ifname].forEach((iface) => {
                if ('IPv4' !== iface.family || iface.internal !== false) {
                    return;
                }
                const parts = iface.address.split('.');
                parts.pop();
                const base = parts.join('.');
                for (let i = 1; i < 255; i++) {
                    candidates.add(`${base}.${i}`);
                }
            });
        });

        const configuredSubnets = Array.isArray(config.discovery?.subnets)
            ? config.discovery.subnets
            : [];
        for (const cidr of configuredSubnets) {
            try {
                const ips = expandCidr(cidr);
                ips.forEach((ip) => candidates.add(ip));
                logger.info(`[discovery] Subred configurada ${cidr} -> ${ips.length} IPs.`);
            } catch (err) {
                logger.warn(`[discovery] Subred invalida "${cidr}": ${err.message}`);
            }
        }

        const scanPromises = Array.from(candidates).map((ip) => this.checkPort(ip, 9100));
        const results = await Promise.allSettled(scanPromises);
        results.forEach((res) => {
            if (res.status === 'fulfilled' && res.value) {
                this.discoveredDevices.push({
                    type: 'network',
                    name: `Net Printer (${res.value})`,
                    address: res.value,
                    port: 9100,
                });
            }
        });
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
