// Shared recovery contract for the primary :4000 and legacy HTTP servers.
const arp = require('./arp');
const resolver = require('./printer_resolver');

function installPrinterRecoveryRoutes(app, authenticate, dependencies = {}) {
    const getMacForIp = dependencies.getMacForIp || arp.getMacForIp;
    const resolveByMac = dependencies.resolveByMac || resolver.resolveByMac;
    const invalidateCache = dependencies.invalidateCache || resolver.invalidateCache;
    const checkPort = dependencies.checkPort || arp.tcpProbe;
    app.post('/api/printers/mac-for-ip', authenticate, async (req, res) => {
        const { ip, port: rawPort = 9100 } = req.body || {};
        const port = arp.validPort(rawPort);
        if (!arp.validIpv4(ip) || !port) return res.status(400).json({ error: 'invalid_ip_or_port' });
        try {
            if (!(await checkPort(ip.trim(), port))) return res.status(404).json({ error: 'printer_not_reachable' });
            const mac = arp.normalizeMac(await getMacForIp(ip.trim(), { probePort: port, forceProbe: false }));
            if (!mac) return res.status(404).json({ error: 'mac_not_resolved' });
            return res.json({ ip: ip.trim(), port, mac, verified: true });
        } catch (err) { return res.status(500).json({ error: err.message }); }
    });
    app.post('/api/printers/resolve-by-mac', authenticate, async (req, res) => {
        const { mac: rawMac, ip, port: rawPort = 9100, skipCache, printerId } = req.body || {};
        const mac = arp.normalizeMac(rawMac);
        const port = arp.validPort(rawPort);
        if (!mac || !port || (ip !== undefined && !arp.validIpv4(ip))) return res.status(400).json({ error: 'invalid_mac_ip_or_port' });
        try {
            const result = await resolveByMac(mac, { ip, port, skipMemoryCache: skipCache === true,
                logCtx: printerId ? ` [printer=${String(printerId).slice(0, 80)}]` : '' });
            if (!result) return res.status(404).json({ error: 'printer_not_found', mac });
            return res.json(result);
        } catch (err) { return res.status(500).json({ error: err.message }); }
    });
    app.post('/api/printers/invalidate-mac-cache', authenticate, (req, res) => {
        const mac = arp.normalizeMac(req.body?.mac);
        if (!mac) return res.status(400).json({ error: 'invalid_mac' });
        invalidateCache(mac);
        return res.json({ ok: true, mac });
    });
}
module.exports = { installPrinterRecoveryRoutes };
