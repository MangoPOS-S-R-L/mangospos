// PRD 7 Fase 1.0 — Resolución de VID/PID USB para escpos-usb.
//
// Acepta cualquier formato razonable (numero, hex con 0x, hex de 4
// chars, string con "VID_xxxx PID_yyyy") y devuelve enteros normalizados.
// Usado solo en el path libusb (Mac/Linux y fallback Windows).

const parseUsbNumber = (value) => {
    if (value === null || value === undefined) return null;
    if (typeof value === 'number' && Number.isFinite(value)) return value;
    const raw = String(value).trim();
    if (!raw) return null;
    if (/^0x[0-9a-f]+$/i.test(raw)) return parseInt(raw, 16);
    if (/^[0-9a-f]{4}$/i.test(raw)) return parseInt(raw, 16);
    if (/^\d+$/.test(raw)) return parseInt(raw, 10);
    return null;
};

const extractUsbIdsFromText = (value) => {
    if (!value) return { vid: null, pid: null };
    const raw = String(value);
    const vidMatch = raw.match(/VID[_:= -]?([0-9A-F]{4})/i);
    const pidMatch = raw.match(/PID[_:= -]?([0-9A-F]{4})/i);
    return {
        vid: vidMatch ? parseInt(vidMatch[1], 16) : null,
        pid: pidMatch ? parseInt(pidMatch[1], 16) : null,
    };
};

const describePrinter = (printerConfig = {}) => JSON.stringify({
    id: printerConfig.id || null,
    name: printerConfig.name || null,
    type: printerConfig.type || null,
    ip: printerConfig.ip || null,
    port: printerConfig.port || null,
    endpoint: printerConfig.endpoint || null,
    devicePath: printerConfig.devicePath || null,
    path: printerConfig.path || null,
    deviceId: printerConfig.deviceId || null,
    vid: printerConfig.vid || null,
    pid: printerConfig.pid || null,
});

const resolveUsbSelection = (printerConfig = {}) => {
    const directVid = parseUsbNumber(printerConfig.vid);
    const directPid = parseUsbNumber(printerConfig.pid);
    if (directVid !== null && directPid !== null) {
        return { vid: directVid, pid: directPid, source: 'printerConfig.vid/pid' };
    }

    const candidates = [
        ['printerConfig.endpoint', printerConfig.endpoint],
        ['printerConfig.devicePath', printerConfig.devicePath],
        ['printerConfig.path', printerConfig.path],
        ['printerConfig.deviceId', printerConfig.deviceId],
        ['printerConfig.mac', printerConfig.mac],
    ];

    for (const [source, value] of candidates) {
        const parsed = extractUsbIdsFromText(value);
        if (parsed.vid !== null && parsed.pid !== null) {
            return { vid: parsed.vid, pid: parsed.pid, source };
        }
    }

    return { vid: null, pid: null, source: null };
};

module.exports = {
    parseUsbNumber,
    extractUsbIdsFromText,
    describePrinter,
    resolveUsbSelection,
};
