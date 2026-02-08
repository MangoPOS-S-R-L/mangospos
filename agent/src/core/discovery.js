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

        // 2. Scan USB (Windows PowerShell)
        if (config.discovery.protocols.includes('usb')) {
            await this.scanUSBWindows();
        }

        this.isScanning = false;
        return this.discoveredDevices;
    }

    async scanUSBWindows() {
        // Use PowerShell to find USB Printing Support devices
        // This is more robust than node-usb on Windows without build tools
        // We use Get-WmiObject to interpret the 'Service' property correctly
        const cmd = `powershell -NoProfile -Command "Get-WmiObject Win32_PnPEntity | Where-Object { $_.Service -eq 'usbprint' } | Select-Object Name, DeviceID, Manufacturer | ConvertTo-Json"`;

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

                    devices.forEach(d => {
                        if (!d.DeviceID) return;
                        // Extract VID/PID from DeviceID (e.g., USB\VID_2CB7&PID_811B\...)
                        // Format: USB\VID_xxxx&PID_xxxx\serial
                        this.discoveredDevices.push({
                            type: 'usb',
                            name: d.Name || 'Unknown USB Printer',
                            vid: this.extractVidPid(d.DeviceID, 'VID'),
                            pid: this.extractVidPid(d.DeviceID, 'PID'),
                            deviceId: d.DeviceID,
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
