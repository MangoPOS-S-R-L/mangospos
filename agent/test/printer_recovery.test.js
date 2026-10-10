const test = require('node:test');
const assert = require('node:assert/strict');
const { EventEmitter } = require('node:events');
const Module = require('node:module');
const path = require('node:path');
const arp = require('../src/network/arp');
const { candidateIps } = require('../src/network/ipv4');
const { createPrinterResolver } = require('../src/network/printer_resolver');
const { createNetworkPrinter } = require('../src/network/network_printer');
const { createTcpSender } = require('../src/network/tcp');
const { installPrinterRecoveryRoutes } = require('../src/network/printer_routes');

const MAC = 'aa:bb:cc:dd:ee:02';
const OTHER = '12:34:56:78:90:ab';
const configStub = { config: { discovery: { protocols: ['network'], subnets: [] }, printers: [], queue: { max_retries: 3 } },
    logger: { info() {}, warn() {}, error() {} }, baseDir: '/tmp', PRINTER_WIDTH: 48, AGENT_ID: 'test', LOCAL_PORT: 4000 };

function loadWithStubs(file, stubs = {}) {
    const filename = require.resolve(file);
    const load = Module._load;
    delete require.cache[filename];
    Module._load = function(request, parent, ...rest) {
        if (Object.hasOwn(stubs, request)) return stubs[request];
        if ((request === '../config' || request === '../../config') && parent?.filename.includes('/agent/')) return configStub;
        return load.call(this, request, parent, ...rest);
    };
    try { return require(filename); } finally { Module._load = load; }
}

function response() {
    return { statusCode: 200, status(code) { this.statusCode = code; return this; },
        json(body) { this.body = body; return this; } };
}

test('MAC and IP validation handles macOS octets and rejects placeholders/multicast/injection', () => {
    assert.equal(arp.normalizeMac('A:B:C:D:E:2'), '0a:0b:0c:0d:0e:02');
    assert.equal(arp.normalizeMac('AA-BB-CC-DD-EE-02'), MAC);
    for (const value of ['00:00:00:00:00:00', 'ff:ff:ff:ff:ff:ff', '01:00:5e:00:00:01', 'USB:VID_1234', `prefix ${MAC}`]) {
        assert.equal(arp.normalizeMac(value), null);
    }
    assert.equal(arp.validIpv4('999.2.3.4'), false);
    assert.equal(arp.validIpv4('192.168.1.2; echo unsafe'), false);
});

test('ARP rows bind MAC to the requested IPv4 on Windows/Linux/macOS', async () => {
    const output = `Interface: 192.168.1.1 --- 0x12\n  192.168.1.8 ${OTHER.replaceAll(':', '-')} dynamic\n  192.168.1.9 ${MAC.replaceAll(':', '-')} dynamic`;
    const commands = [];
    const reader = arp.createArpReader({ platform: 'win32', probe: async () => true,
        run(command, args, options, callback) { commands.push({ command, args }); callback(null, output); } });
    assert.equal(await reader.getMacForIp('192.168.1.9'), MAC);
    assert.deepEqual(commands, [{ command: 'arp', args: ['-a', '192.168.1.9'] }]);
    assert.equal(await reader.getMacForIp('192.168.1.9; unsafe'), null);
    assert.equal(commands.length, 1);
    assert.deepEqual(arp.parseArpEntries('? (10.0.0.9) at a:b:c:d:e:2 on en0'), [{ ip: '10.0.0.9', mac: '0a:0b:0c:0d:0e:02' }]);
    assert.deepEqual(arp.parseArpEntries(`10.0.0.9 dev eth0 lladdr ${MAC} STALE\n10.0.0.10 dev eth0 FAILED`), [{ ip: '10.0.0.9', mac: MAC }]);
});

test('conflicting ARP identities on overlapping interfaces cannot select a printer', async () => {
    const reader = arp.createArpReader({ platform: 'win32', probe: async () => true,
        run(_command, _args, _options, callback) { callback(null,
            `192.168.1.9 ${MAC.replaceAll(':', '-')} dynamic\n192.168.1.9 ${OTHER.replaceAll(':', '-')} dynamic`); } });
    assert.equal(await reader.getMacForIp('192.168.1.9'), null);
});

test('candidate ranges include interface /23 and configured CIDRs with deduplication', () => {
    const ips = candidateIps({ interfaces: { lan: [{ family: 'IPv4', internal: false, address: '10.1.0.10', cidr: '10.1.0.10/23' }] },
        subnets: ['invalid', '10.1.1.0/24', '192.168.9.0/30'] });
    assert.ok(ips.includes('10.1.1.200'));
    assert.ok(ips.includes('192.168.9.2'));
    assert.equal(ips.length, new Set(ips).size);
    assert.equal(ips.includes('192.168.9.3'), false);
});

test('DHCP reassignment rejects stale cached/ARP IP now owned by another printer', async () => {
    const current = new Map([['10.0.0.1', MAC]]);
    const calls = [];
    const resolver = createPrinterResolver({ getInterfaces: () => ({}), getSubnets: () => ['10.0.0.0/29'],
        readArpEntries: async () => [{ ip: '10.0.0.1', mac: MAC }],
        checkPort: async (ip, port) => { calls.push({ ip, port }); return current.has(ip); },
        getMacForIp: async (ip) => current.get(ip) });
    assert.deepEqual(await resolver.resolveByMac(MAC, { ip: '10.0.0.1', port: 9200 }),
        { mac: MAC, ip: '10.0.0.1', port: 9200, source: 'configured_ip', verified: true });
    current.set('10.0.0.1', OTHER);
    current.set('10.0.0.2', MAC);
    const recovered = await resolver.resolveByMac(MAC, { ip: '10.0.0.1', port: 9200 });
    assert.equal(recovered.ip, '10.0.0.2');
    assert.equal(recovered.verified, true);
    assert.ok(calls.every((call) => call.port === 9200));
});

test('resolver shares concurrent lookups and limits probe concurrency', async () => {
    let reads = 0;
    let inFlight = 0;
    let max = 0;
    const resolver = createPrinterResolver({ concurrency: 3, getInterfaces: () => ({}), getSubnets: () => ['10.0.0.0/28'],
        readArpEntries: async () => { reads++; return []; },
        checkPort: async (ip) => { inFlight++; max = Math.max(max, inFlight); await new Promise(setImmediate); inFlight--; return ip === '10.0.0.9'; },
        getMacForIp: async () => MAC });
    const results = await Promise.all([resolver.resolveByMac(MAC), resolver.resolveByMac(MAC), resolver.resolveByMac(MAC)]);
    assert.equal(reads, 1);
    assert.ok(max <= 3);
    assert.ok(results.every((result) => result.ip === '10.0.0.9' && result.verified));
});

test('duplicate verified MAC in known ARP candidates rejects even a healthy hint', async () => {
    let scanned = false;
    const resolver = createPrinterResolver({ getInterfaces: () => { scanned = true; return {}; }, getSubnets: () => [],
        readArpEntries: async () => [{ ip: '10.0.0.1', mac: MAC }, { ip: '10.0.0.2', mac: MAC }],
        checkPort: async () => true, getMacForIp: async () => MAC });
    assert.equal(await resolver.resolveByMac(MAC, { ip: '10.0.0.1' }), null);
    assert.equal(scanned, false);
});

test('scan waits for in-flight matches and rejects duplicate physical identity', async () => {
    const resolver = createPrinterResolver({ concurrency: 4, getInterfaces: () => ({}), getSubnets: () => ['10.0.0.0/29'],
        readArpEntries: async () => [], checkPort: async (ip) => {
            await new Promise(setImmediate); return ['10.0.0.1', '10.0.0.2'].includes(ip);
        }, getMacForIp: async () => MAC });
    assert.equal(await resolver.resolveByMac(MAC), null);
});

test('network print uses verified recovered IP and never submits to replaced old IP', async () => {
    const sent = [];
    const printer = { type: 'network', ip: '10.0.0.1', mac: MAC, port: 9200 };
    const service = createNetworkPrinter({ resolveByMac: async (mac, options) => {
        assert.equal(options.ip, '10.0.0.1'); assert.equal(options.port, 9200);
        return { mac, ip: '10.0.0.2', port: 9200, verified: true };
    }, sendRawTcp: async (ip, port, payload) => sent.push({ ip, port, payload }) });
    await service.printNetworkPayload(printer, Buffer.from('ticket'));
    assert.equal(sent.length, 1);
    assert.equal(sent[0].ip, '10.0.0.2');
    assert.equal(printer.ip, '10.0.0.2');
});

test('pre-write failure resolves fresh once; uncertain failure never resolves/reprints', async () => {
    let resolves = 0;
    let sends = 0;
    let invalidations = 0;
    const service = createNetworkPrinter({ resolveByMac: async (mac, options) => {
        resolves++;
        if (resolves === 2) assert.equal(options.skipMemoryCache, true);
        return { mac, ip: `10.0.0.${resolves}`, port: 9100, verified: true };
    }, invalidateCache: () => invalidations++, sendRawTcp: async () => {
        if (++sends === 1) throw Object.assign(new Error('refused'), { safeToRetry: true });
    } });
    await service.printNetworkPayload({ mac: MAC, ip: '10.0.0.1' }, Buffer.from('ticket'));
    assert.equal(resolves, 2); assert.equal(sends, 2); assert.equal(invalidations, 1);
    const uncertain = Object.assign(new Error('reset after write'), { safeToRetry: false, deliveryUncertain: true });
    const blocked = createNetworkPrinter({ resolveByMac: async (mac) => { resolves++; return { mac, ip: '10.0.0.2', port: 9100, verified: true }; },
        sendRawTcp: async () => { sends++; throw uncertain; } });
    await assert.rejects(blocked.printNetworkPayload({ mac: MAC }, Buffer.from('ticket')), (err) => err === uncertain);
    assert.equal(resolves, 3); assert.equal(sends, 3);
});

test('missing MAC match and unverifiable response submit no bytes', async () => {
    let sends = 0;
    const service = createNetworkPrinter({ resolveByMac: async () => null, sendRawTcp: async () => sends++ });
    await assert.rejects(service.printNetworkPayload({ mac: MAC, ip: '10.0.0.1' }, Buffer.from('ticket')), /could not be verified/);
    assert.equal(sends, 0);
});

class FakeSocket extends EventEmitter {
    constructor(mode, stats) { super(); this.mode = mode; this.stats = stats; }
    connect() { queueMicrotask(() => {
        if (this.mode === 'refused') this.emit('error', Object.assign(new Error('refused'), { code: 'ECONNREFUSED' }));
        else if (this.mode === 'close') this.emit('close');
        else this.emit('connect');
    }); }
    setNoDelay() {}
    setKeepAlive() {}
    write(_payload, callback) { this.stats.writes++;
        if (this.mode === 'write-error') callback(Object.assign(new Error('reset'), { code: 'ECONNRESET' }));
        else if (this.mode !== 'hang') callback();
    }
    end(callback) { callback(); }
    destroy() { this.stats.destroyed++; }
}

test('TCP retries pre-write refusal but not write error, timeout or premature success', async () => {
    let created = 0;
    const stats = { writes: 0, destroyed: 0 };
    const sender = createTcpSender({ drainMs: 0, retryDelayMs: 0, socketFactory: () => new FakeSocket(++created === 1 ? 'refused' : 'ok', stats) });
    await sender.sendRawTcp('10.0.0.1', 9100, Buffer.from('ticket'), 100, 2);
    assert.equal(created, 2); assert.equal(stats.writes, 1);
    for (const mode of ['write-error', 'hang', 'close']) {
        let attempts = 0;
        const service = createTcpSender({ drainMs: 0, retryDelayMs: 0, socketFactory: () => { attempts++; return new FakeSocket(mode, stats); } });
        await assert.rejects(service.sendRawTcp('10.0.0.1', 9100, Buffer.from('ticket'), 10, mode === 'close' ? 1 : 3),
            (err) => mode === 'close' ? err.safeToRetry && !err.deliveryUncertain : err.deliveryUncertain && !err.safeToRetry);
        assert.equal(attempts, 1);
    }
});

test('raw hex/base64 render identical full ticket bytes including Star payload', async () => {
    const { renderNetworkContent } = loadWithStubs('../src/print/network_content');
    const data = Buffer.from([0x1b, 0x2a, 0x72, 0x41, 0x00, 0x01, 0x1d, 0x56]);
    assert.deepEqual(await renderNetworkContent({ type: 'raw_hex', dataHex: data.toString('hex') }), data);
    assert.deepEqual(await renderNetworkContent({ type: 'raw_base64', dataBase64: data.toString('base64') }), data);
    await assert.rejects(renderNetworkContent({ type: 'raw_hex', dataHex: 'garbage' }), /Invalid/);
    const text = await renderNetworkContent({ type: 'text', content: 'Pedido 123' });
    assert.ok(text.includes(Buffer.from('Pedido 123')));
});

test('shared routes validate requests and return verified identity/port contract', async () => {
    const routes = new Map();
    const app = { post(route, auth, handler) { routes.set(route, { auth, handler }); } };
    let authCalls = 0;
    installPrinterRecoveryRoutes(app, (_req, _res, next) => { authCalls++; next(); }, {
        checkPort: async () => true, getMacForIp: async () => MAC,
        resolveByMac: async (mac, options) => ({ mac, ip: '10.0.0.2', port: options.port, verified: true, source: 'scan' }), invalidateCache() {} });
    const route = routes.get('/api/printers/resolve-by-mac');
    const res = response();
    const req = { body: { mac: MAC, ip: '10.0.0.1', port: 9200, skipCache: true } };
    route.auth(req, res, () => {}); await route.handler(req, res);
    assert.equal(authCalls, 1);
    assert.deepEqual(res.body, { mac: MAC, ip: '10.0.0.2', port: 9200, verified: true, source: 'scan' });
    const invalid = response(); await route.handler({ body: { mac: MAC, port: 70000 } }, invalid);
    assert.equal(invalid.statusCode, 400);
});

test('primary :4000 buildApp exposes recovery routes and guarded raw submission', async () => {
    const { buildApp } = loadWithStubs('../src/http/server', {
        '../queue/store': {}, '../queue/worker': { stats() {} }, '../platform/windows': { stopExistingAgentOnLocalPort() {} },
        './auth': { requireAuth(_req, _res, next) { next(); }, logStartupMode() {} },
    });
    let target;
    const app = buildApp({ recovery: { resolveByMac: async (mac, options) => ({ mac, ip: '10.0.0.2', port: options.port, verified: true }) },
        printNetworkPayload: async (printer) => { target = printer; return { ip: '10.0.0.2', port: printer.port, verified: true }; } });
    const routes = app._router.stack.filter((layer) => layer.route).map((layer) => layer.route);
    for (const route of ['mac-for-ip', 'resolve-by-mac', 'invalidate-mac-cache']) {
        assert.ok(routes.some((item) => item.path === `/api/printers/${route}`));
    }
    const raw = routes.find((item) => item.path === '/api/printers/raw').stack[0].handle;
    const res = response();
    await raw({ body: { printerId: 'saved-id', printer: { id: 'saved-id', type: 'network', ip: '10.0.0.1', port: 9200, mac: MAC },
        dataBase64: Buffer.from('ticket').toString('base64') } }, res);
    assert.equal(target.mac, MAC); assert.equal(target.id, 'saved-id'); assert.equal(target.port, 9200);
    assert.equal(res.body.ip, '10.0.0.2');
    assert.equal(res.body.verified, true);
});

test('primary raw HTTP reports uncertain delivery without accepting a retry', async () => {
    const { buildApp } = loadWithStubs('../src/http/server', {
        '../queue/store': {}, '../queue/worker': { stats() {} }, '../platform/windows': {},
        './auth': { requireAuth(_req, _res, next) { next(); }, logStartupMode() {} },
    });
    let attempts = 0;
    const app = buildApp({ printNetworkPayload: async () => {
        attempts++;
        throw Object.assign(new Error('Connection reset after write'), { code: 'DELIVERY_UNCERTAIN', deliveryUncertain: true, safeToRetry: false });
    } });
    const raw = app._router.stack.find((layer) => layer.route?.path === '/api/printers/raw').route.stack[0].handle;
    const res = response();
    await raw({ body: { ip: '10.0.0.1', mac: MAC, dataBase64: Buffer.from('ticket').toString('base64') } }, res);
    assert.equal(attempts, 1); assert.equal(res.statusCode, 500);
    assert.equal(res.body.deliveryUncertain, true); assert.equal(res.body.safeToRetry, false);
});

test('actual network job processor renders raw cloud bytes before guarded send', async () => {
    const payload = Buffer.from([0x1b, 0x2a, 0x72, 0x41, 0x00, 0x1d, 0x56]);
    const events = [];
    const { processPrintJob } = loadWithStubs('../src/print/job_processor', {
        'escpos-usb': class {}, 'escpos-network': class {},
        './network_content': { async renderNetworkContent(content) {
            events.push('render'); assert.equal(content.type, 'raw_hex');
            return Buffer.from(content.dataHex, 'hex');
        } },
        '../network/network_printer': { async printNetworkPayload(printer, data) {
            events.push('verified_send'); assert.equal(printer.mac, MAC); assert.deepEqual(data, payload);
            return { ip: '10.0.0.2', mac: MAC, port: 9200, verified: true };
        } },
    });
    const result = await processPrintJob({ id: 'cloud', printer: { type: 'network', ip: '10.0.0.1', port: 9200, mac: MAC },
        content: { type: 'raw_hex', dataHex: payload.toString('hex') } });
    assert.deepEqual(events, ['render', 'verified_send']); assert.equal(result.ip, '10.0.0.2');
});

test('cloud dispatcher flags uncertain delivery as terminal for database handling', async () => {
    let completed;
    const { dispatch, stop } = loadWithStubs('../src/queue/printer_dispatcher', {
        '../print/job_processor': { async processPrintJob() { throw Object.assign(new Error('reset'), { deliveryUncertain: true }); } },
        './cloud_store': { async complete(...args) { completed = args; } },
    });
    assert.equal(dispatch({ id: 'cloud', printer_id: 'saved', data_hex: 'aa' }, { type: 'network', mac: MAC }), true);
    await stop();
    assert.deepEqual(completed, ['cloud', false, '[DELIVERY_UNCERTAIN] reset']);
});

test('cloud worker cannot print old job IP when saved printer lookup is unavailable', async () => {
    let dispatched = 0;
    let claimed = false;
    let completed;
    const worker = loadWithStubs('../src/queue/worker', {
        './store': { init() {}, nextQueued() { return null; }, close() {} },
        './cloud_store': { isEnabled: () => true, async claimNext() {
            if (claimed) return null; claimed = true;
            return { id: 'job', printer_id: 'saved', ip: '10.0.0.1', port: 9100 };
        }, async fetchPrinter() { return null; }, async complete(...args) { completed = args; } },
        './printer_dispatcher': { start() {}, async stop() {}, inFlightCount: () => 0, MAX_CONCURRENT_PRINTERS: 8,
            dispatch() { dispatched++; return true; } },
        '../print/job_processor': { processPrintJob() { throw new Error('Must not print'); } },
    });
    worker.start();
    await new Promise(setImmediate);
    await worker.stop();
    assert.equal(dispatched, 0); assert.equal(completed[0], 'job'); assert.equal(completed[1], false);
    assert.match(completed[2], /configuration unavailable/);
});

test('SQLite completion failure after successful send still marks delivery uncertain', async () => {
    let selected = false;
    let printed = 0;
    let failed;
    const worker = loadWithStubs('../src/queue/worker', {
        './store': { init() {}, nextQueued() {
            if (selected) return null; selected = true; return { jobId: 'job', ticketId: 'ticket', payload: {} };
        }, markPrinting() {}, markDone() { throw new Error('Completion write failed'); },
        markFailed(...args) { failed = args; }, close() {} },
        './cloud_store': { isEnabled: () => false },
        './printer_dispatcher': { start() {}, async stop() {}, inFlightCount: () => 0, MAX_CONCURRENT_PRINTERS: 8 },
        '../print/job_processor': { async processPrintJob() { printed++; } },
    });
    worker.start(); await new Promise(setImmediate); await worker.stop();
    assert.equal(printed, 1); assert.deepEqual(failed, ['job', '[DELIVERY_UNCERTAIN] Completion write failed']);
});

test('SQLite restart preserves pending jobs and never replays an interrupted ticket', () => {
    // Execute the production SQL against real in-memory SQLite; the adapter
    // only substitutes the native binding to avoid a host-specific ABI.
    let sqlite;
    try { sqlite = new (require('node:sqlite').DatabaseSync)(':memory:'); }
    catch (_) { sqlite = new (require('better-sqlite3'))(':memory:'); }
    class Database {
        pragma(value) { sqlite.exec(`PRAGMA ${value}`); }
        exec(value) { sqlite.exec(value); }
        prepare(value) { return sqlite.prepare(value); }
        close() {} // Simulate disconnect/reopen while retaining the database.
    }
    const store = loadWithStubs('../src/queue/store', { 'better-sqlite3': Database });
    try {
        const interrupted = store.enqueue({ ticketId: 'interrupted', payload: {} }).job;
        const pending = store.enqueue({ ticketId: 'pending', payload: {} }).job;
        store.markPrinting(interrupted.jobId);
        store.close(); store.init();
        const recovered = store.get(interrupted.jobId);
        assert.equal(recovered.status, 'failed'); assert.match(recovered.lastError, /^\[DELIVERY_UNCERTAIN\]/);
        assert.equal(store.nextQueued().jobId, pending.jobId);
        const duplicate = store.enqueue({ ticketId: 'interrupted', payload: {} });
        assert.equal(duplicate.duplicate, true); assert.equal(duplicate.job.status, 'failed');
    } finally { store.close(); sqlite.close(); }
});

test('discovery concurrent callers wait for complete results with network MAC', async () => {
    const { DiscoveryService } = loadWithStubs('../src/core/discovery');
    let checks = 0;
    const service = new DiscoveryService({ candidateIps: () => ['10.0.0.1'],
        checkPort: async () => { checks++; await new Promise(setImmediate); return true; }, getMacForIp: async () => MAC });
    const [first, second] = await Promise.all([service.scan(), service.scan()]);
    assert.equal(checks, 1); assert.deepEqual(first, second);
    assert.equal(first[0].mac, MAC); assert.equal(first[0].deviceId, MAC);
});

test('network discovery fits the legacy 12 s client and keeps printers found before the cut', async () => {
    const { DiscoveryService } = loadWithStubs('../src/core/discovery');
    const ips = Array.from({ length: 254 }, (_, i) => `10.0.0.${i + 1}`);
    const timeouts = new Set();
    let probes = 0;
    const service = new DiscoveryService({ candidateIps: () => ips, scanBudgetMs: 60, getMacForIp: async () => MAC,
        checkPort: (ip, _port, timeout) => {
            probes++; timeouts.add(timeout);
            if (ip === '10.0.0.1') return Promise.resolve(ip);
            return new Promise((_resolve, reject) => setTimeout(() => reject(new Error('timeout')), 100));
        } });
    const started = Date.now();
    const found = await service.scan();
    assert.ok(Date.now() - started < 600, `took ${Date.now() - started} ms`);
    assert.ok(probes < ips.length, 'stops probing when the budget runs out');
    assert.deepEqual(found.map((d) => d.ip), ['10.0.0.1']);
    assert.deepEqual([...timeouts], [800]);
});

test('legacy inline saved MAC never selects a different configured printer by name/IP', () => {
    configStub.config.printers = [{ id: 'old', type: 'network', name: 'Kitchen', ip: '10.0.0.1', mac: OTHER }];
    const { PrinterManager } = loadWithStubs('../src/core/printer_manager', { 'escpos-usb': class {}, 'escpos-serialport': class {} });
    const service = new PrinterManager();
    const selected = service._findConfiguredPrinter({ printerId: 'new', printer: { type: 'network', name: 'Kitchen', ip: '10.0.0.1', mac: MAC } });
    assert.equal(selected.mac, MAC); assert.equal(selected.id, 'new');
    configStub.config.printers = [];
});

test('legacy queue never replays uncertain delivery', async () => {
    const { PrinterManager } = loadWithStubs('../src/core/printer_manager', { 'escpos-usb': class {}, 'escpos-serialport': class {} });
    const service = new PrinterManager();
    let calls = 0;
    service.printToDevice = async () => { calls++; throw Object.assign(new Error('uncertain'), { deliveryUncertain: true, retryable: false }); };
    service.addJob({ printerId: 'p', printer: { type: 'network', ip: '10.0.0.1', mac: MAC }, data: { type: 'text', content: 'ticket' } });
    await new Promise(setImmediate);
    assert.equal(calls, 1); assert.equal(service.history[0].status, 'failed');
});

test('cloud dispatcher reports the printing ticket and those waiting behind a slow printer', async () => {
    let release;
    const gate = new Promise((resolve) => { release = resolve; });
    const { dispatch, heldJobIds, stop } = loadWithStubs('../src/queue/printer_dispatcher', {
        '../print/job_processor': { async processPrintJob() { await gate; } },
        './cloud_store': { async complete() {} },
    });
    for (const id of ['first', 'second', 'third']) {
        assert.equal(dispatch({ id, printer_id: 'slow', data_hex: 'aa' }, { type: 'network', mac: MAC }), true);
    }
    assert.deepEqual(heldJobIds(), ['first', 'second', 'third']);
    release();
    await stop();
    assert.deepEqual(heldJobIds(), []);
});

test('cloud worker renews held claims so a slow printer never expires waiting tickets', async (t) => {
    t.mock.timers.enable({ apis: ['setInterval'] });
    const renewed = [];
    const worker = loadWithStubs('../src/queue/worker', {
        './store': { init() {}, nextQueued() { return null; }, close() {} },
        './cloud_store': { isEnabled: () => true, async claimNext() { return null; }, async reclaimStale() { return 0; },
            async renewClaims(ids) { renewed.push(ids); return ids.length; } },
        './printer_dispatcher': { start() {}, async stop() {}, inFlightCount: () => 0, MAX_CONCURRENT_PRINTERS: 8,
            dispatch() { return true; }, heldJobIds: () => ['printing', 'waiting'] },
        '../print/job_processor': { processPrintJob() { throw new Error('Must not print'); } },
    });
    worker.start();
    t.mock.timers.tick(19_999);
    assert.deepEqual(renewed, []);
    t.mock.timers.tick(1);
    await new Promise(setImmediate);
    await worker.stop();
    assert.deepEqual(renewed, [['printing', 'waiting']]);
});
