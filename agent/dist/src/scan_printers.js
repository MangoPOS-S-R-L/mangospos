const net = require('net');
const os = require('os');

function getLocalIPs() {
    const interfaces = os.networkInterfaces();
    const ips = [];
    for (const name of Object.keys(interfaces)) {
        for (const iface of interfaces[name]) {
            // Skip internal and non-IPv4 addresses
            if ('IPv4' !== iface.family || iface.internal) {
                continue;
            }
            ips.push(iface.address);
        }
    }
    return ips;
}

function checkPort(ip, port, timeout = 400) {
    return new Promise((resolve) => {
        const socket = new net.Socket();
        let status = 'closed';

        socket.setTimeout(timeout);

        socket.on('connect', () => {
            status = 'open';
            socket.destroy();
        });

        socket.on('timeout', () => {
            socket.destroy();
        });

        socket.on('error', (err) => {
            socket.destroy();
        });

        socket.on('close', () => {
            resolve(status === 'open');
        });

        socket.connect(port, ip);
    });
}

async function scanSubnet(subnet) {
    console.log(`Scanning subnet: ${subnet}.1 - ${subnet}.254 for Port 9100 (Printers)...`);
    const printers = [];

    // Create an array of promises for scanning
    const promises = [];
    for (let i = 1; i < 255; i++) {
        const ip = `${subnet}.${i}`;
        promises.push(async () => {
            const isOpen = await checkPort(ip, 9100);
            if (isOpen) {
                console.log(`✅ FOUND PRINTER AT: ${ip}`);
                printers.push(ip);
            }
        });
    }

    // Run in chunks to avoid too many open files/sockets
    const chunk_size = 50;
    for (let i = 0; i < promises.length; i += chunk_size) {
        const chunk = promises.slice(i, i + chunk_size);
        await Promise.all(chunk.map(p => p()));
    }

    return printers;
}

async function main() {
    const localIPs = getLocalIPs();
    console.log("Local IPs found:", localIPs);

    if (localIPs.length === 0) {
        console.error("No network connection found.");
        return;
    }

    for (const ip of localIPs) {
        // Assume /24 subnet for simplicity
        const subnet = ip.split('.').slice(0, 3).join('.');
        await scanSubnet(subnet);
    }

    console.log("Scan complete.");
}

main();
