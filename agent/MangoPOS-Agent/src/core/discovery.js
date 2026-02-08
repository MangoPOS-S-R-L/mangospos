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

        // 2. Scan USB (node-usb logic stub)
        if (config.discovery.protocols.includes('usb')) {
            // Implementation note: requires 'usb' lib to list devices
            // const usb = require('usb');
            // this.discoveredDevices.push(...usb.getDeviceList().map(d => ({ type: 'usb', ... })));
            logger.info('USB scan placeholder');
        }

        this.isScanning = false;
        return this.discoveredDevices;
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
