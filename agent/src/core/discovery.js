const os = require('os');
const net = require('net');
const dgram = require('dgram');
const { config, logger } = require('../config');
const { exec } = require('child_process');

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
        // Simple ping sweep logic for local subnet on port 9100
        const interfaces = os.networkInterfaces();
        const subnets = [];

        Object.keys(interfaces).forEach((ifname) => {
            interfaces[ifname].forEach((iface) => {
                if ('IPv4' !== iface.family || iface.internal !== false) {
                    return; // skip over internal (i.e. 127.0.0.1) and non-ipv4
                }
                // Calculate subnet range (simplified /24)
                const parts = iface.address.split('.');
                parts.pop();
                subnets.push(parts.join('.'));
            });
        });

        // Scan aggressively (parallel)
        const scanPromises = [];
        subnets.forEach(subnet => {
            for (let i = 1; i < 255; i++) {
                const ip = `${subnet}.${i}`;
                scanPromises.push(this.checkPort(ip, 9100));
            }
        });

        const results = await Promise.allSettled(scanPromises);
        results.forEach(res => {
            if (res.status === 'fulfilled' && res.value) {
                this.discoveredDevices.push({
                    type: 'network',
                    name: `Net Printer (${res.value})`,
                    address: res.value,
                    port: 9100
                });
            }
        });
    }

    checkPort(ip, port, timeout = 200) {
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
