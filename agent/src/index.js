const path = require('path');
const io = require('socket.io-client');
const winston = require('winston');
const { exec, spawn } = require('child_process');
const discoveryService = require('./core/discovery');

// Cargar .env: detectar si corremos como script o como binario pkg
const isPkg = typeof process.pkg !== 'undefined';
const baseDir = isPkg ? path.dirname(process.execPath) : path.join(__dirname, '..');
require('dotenv').config({ path: path.join(baseDir, '.env') });


// Configuración de Logging
const logger = winston.createLogger({
    level: process.env.LOG_LEVEL || 'info',
    format: winston.format.combine(
        winston.format.timestamp(),
        winston.format.json()
    ),
    transports: [
        new winston.transports.Console({
            format: winston.format.simple(),
        }),
        // Guardar el log junto al ejecutable o en la raiz del agente
        new winston.transports.File({ filename: path.join(baseDir, 'agent.log') }),
    ],
});


// Configuración
const SERVER_URL = process.env.BACKEND_URL || 'http://localhost:3000';
const AGENT_ID = process.env.AGENT_ID || 'unknown-agent';


logger.info(`?? Iniciando MangoPOS Print Agent [${AGENT_ID}]`);
logger.info(`?? Conectando a ${SERVER_URL}...`);


// Conexión Socket.IO
const socket = io(SERVER_URL, {
    auth: {
        token: process.env.AUTH_TOKEN,
        agentId: AGENT_ID
    },
    reconnection: true,
    reconnectionAttempts: Infinity,
    reconnectionDelay: 1000,
});


// Manejo de Eventos de Conexión
socket.on('connect', () => {
    logger.info('? Conectado al servidor Cloud');
    registerAgent();
});


socket.on('disconnect', (reason) => {
    logger.warn(`? Desconectado: ${reason}`);
});


socket.on('connect_error', (error) => {
    logger.error(`?? Error de conexión: ${error.message}`);
});


// Manejo de Trabajos de Impresión
socket.on('print-job', async (job, ack) => {
    logger.info(`??? Recibido trabajo de impresión: ${job.id}`);


    try {
        await processPrintJob(job);


        // Confirmar éxito al servidor
        if (ack) ack({ status: 'success', jobId: job.id });
        logger.info(`? Trabajo ${job.id} completado`);


    } catch (error) {
        logger.error(`?? Error imprimiendo trabajo ${job.id}: ${error.message}`);


        // Reportar error
        if (ack) ack({ status: 'error', jobId: job.id, message: error.message });
    }
});


function registerAgent() {
    socket.emit('register-agent', {
        id: AGENT_ID,
        name: process.env.AGENT_NAME,
        status: 'online',
        system: {
            platform: process.platform,
            arch: process.arch
        }
    });
}


// Lógica de Impresión Real
const escpos = require('escpos');
escpos.Network = require('escpos-network');
escpos.USB = require('escpos-usb');


// Helper: Configuración Global de Impresión
const PRINTER_WIDTH = 48; // Ancho estándar para 80mm real (48 columnas)


// Helper: Formateadores
const fmtMoney = (amount) => {
    return 'RD$ ' + (amount || 0).toFixed(2).replace(/\d(?=(\d{3})+\.)/g, '$&,');
};


const padRight = (str, len) => {
    str = String(str || '');
    if (str.length > len) return str.substring(0, len);
    return str + ' '.repeat(len - str.length);
};


const padLeft = (str, len) => {
    str = String(str || '');
    if (str.length > len) return str.substring(0, len);
    return ' '.repeat(len - str.length) + str;
};


const center = (str, len = PRINTER_WIDTH) => {
    str = String(str || '');
    if (str.length >= len) return str.substring(0, len);
    const leftPad = Math.floor((len - str.length) / 2);
    return ' '.repeat(leftPad) + str;
};


const drawLine = (char = '-', len = PRINTER_WIDTH) => {
    return char.repeat(len);
};


const titleBlock = (txt) => [
    drawLine('='),
    center(txt),
    drawLine('=')
];


const formatDate = () => {
    const now = new Date();
    return now.toLocaleString('es-DO', {
        day: '2-digit', month: '2-digit', year: 'numeric',
        hour: '2-digit', minute: '2-digit', hour12: true
    });
};


// Comandos ESC/POS
const CMD = {
    RESET: '\x1B\x40',
    CODEPAGE_PC850: '\x1B\x74\x02', // CP850 (Latin-1) - mejor para español
    BOLD_ON: '\x1B\x45\x01',
    BOLD_OFF: '\x1B\x45\x00',
    DOUBLE_STRIKE_ON: '\x1B\x47\x01', // Makes text thicker/darker
    DOUBLE_STRIKE_OFF: '\x1B\x47\x00',
    ALIGN_LEFT: '\x1B\x61\x00',
    ALIGN_CENTER: '\x1B\x61\x01',
    ALIGN_RIGHT: '\x1B\x61\x02',
    DENSITY_HIGH: '\x1D\x7C\x02', // Aumenta la densidad de impresión
    // Tamaños de texto
    SIZE_NORMAL: '\x1D\x21\x00',
    SIZE_DOUBLE_WIDTH: '\x1D\x21\x10',
    SIZE_DOUBLE_HEIGHT: '\x1D\x21\x01',
    SIZE_DOUBLE: '\x1D\x21\x11', // Doble ancho y alto
};


// Helper para fecha segura (ASCII only)
const getSafeDate = () => {
    const now = new Date();
    const d = now.getDate().toString().padStart(2, '0');
    const m = (now.getMonth() + 1).toString().padStart(2, '0');
    const y = now.getFullYear();


    let h = now.getHours();
    const min = now.getMinutes().toString().padStart(2, '0');
    const ampm = h >= 12 ? 'PM' : 'AM';
    h = h % 12;
    h = h ? h : 12;


    return `${d}/${m}/${y} ${h}:${min} ${ampm}`;
};

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


// =============================================================
// Windows winspool path (no libusb / no Zadig)
// Misma lógica que `_printRawDirectUsbWindows` en Flutter:
// abre la impresora vía OpenPrinter de winspool.drv, escribe los bytes
// RAW y cierra. Funciona con cualquier impresora térmica instalada como
// impresora estándar de Windows — sin necesidad de Zadig ni libusb.
// =============================================================
function escapePsSingleQuoted(value) {
    return String(value || '').replace(/'/g, "''");
}

async function printRawViaWinspoolWindows(printerConfig, base64Payload) {
    const printerName = escapePsSingleQuoted(printerConfig.name);
    const devicePath = escapePsSingleQuoted(printerConfig.devicePath);
    const portHint = escapePsSingleQuoted(printerConfig.mac);

    const script = `
$ErrorActionPreference = 'Stop'
$printerName = '${printerName}'
$devicePath = '${devicePath}'
$portHint = '${portHint}'
$payload = '${base64Payload}'
$bytes = [Convert]::FromBase64String($payload)

$target = Get-CimInstance Win32_Printer |
  Where-Object {
    ($printerName -and $_.Name -eq $printerName) -or
    ($devicePath -and ($_.Name -eq $devicePath -or $_.DeviceID -eq $devicePath)) -or
    ($portHint -and $_.PortName -eq $portHint)
  } |
  Select-Object -First 1

if (-not $target) {
  $target = Get-CimInstance Win32_Printer |
    Where-Object {
      $_.Local -eq $true -and $_.PortName -match '^USB' -and (
        ($printerName -and $_.Name -like "*$printerName*") -or
        ($devicePath -and ($_.Name -like "*$devicePath*" -or $_.DeviceID -like "*$devicePath*")) -or
        ($portHint -and $_.PortName -like "*$portHint*")
      )
    } |
    Select-Object -First 1
}

if (-not $target) {
  throw "USB_PRINTER_NOT_FOUND name=$printerName devicePath=$devicePath port=$portHint"
}

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class RawPrinterHelper
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
    public class DOCINFOA
    {
        [MarshalAs(UnmanagedType.LPStr)]
        public string pDocName;
        [MarshalAs(UnmanagedType.LPStr)]
        public string pOutputFile;
        [MarshalAs(UnmanagedType.LPStr)]
        public string pDataType;
    }

    [DllImport("Winspool.drv", EntryPoint = "OpenPrinterA", SetLastError = true, CharSet = CharSet.Ansi, ExactSpelling = true, CallingConvention = CallingConvention.StdCall)]
    public static extern bool OpenPrinter(string szPrinter, out IntPtr hPrinter, IntPtr pd);

    [DllImport("Winspool.drv", EntryPoint = "ClosePrinter", SetLastError = true, ExactSpelling = true, CallingConvention = CallingConvention.StdCall)]
    public static extern bool ClosePrinter(IntPtr hPrinter);

    [DllImport("Winspool.drv", EntryPoint = "StartDocPrinterA", SetLastError = true, CharSet = CharSet.Ansi, ExactSpelling = true, CallingConvention = CallingConvention.StdCall)]
    public static extern bool StartDocPrinter(IntPtr hPrinter, int level, [In, MarshalAs(UnmanagedType.LPStruct)] DOCINFOA di);

    [DllImport("Winspool.drv", EntryPoint = "EndDocPrinter", SetLastError = true, ExactSpelling = true, CallingConvention = CallingConvention.StdCall)]
    public static extern bool EndDocPrinter(IntPtr hPrinter);

    [DllImport("Winspool.drv", EntryPoint = "StartPagePrinter", SetLastError = true, ExactSpelling = true, CallingConvention = CallingConvention.StdCall)]
    public static extern bool StartPagePrinter(IntPtr hPrinter);

    [DllImport("Winspool.drv", EntryPoint = "EndPagePrinter", SetLastError = true, ExactSpelling = true, CallingConvention = CallingConvention.StdCall)]
    public static extern bool EndPagePrinter(IntPtr hPrinter);

    [DllImport("Winspool.drv", EntryPoint = "WritePrinter", SetLastError = true, ExactSpelling = true, CallingConvention = CallingConvention.StdCall)]
    public static extern bool WritePrinter(IntPtr hPrinter, byte[] pBytes, int dwCount, out int dwWritten);
}
"@

$handle = [IntPtr]::Zero
$docStarted = $false
$pageStarted = $false

if (-not [RawPrinterHelper]::OpenPrinter($target.Name, [ref]$handle, [IntPtr]::Zero)) {
  $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
  throw "OPEN_PRINTER_FAILED $err ($($target.Name))"
}

try {
  $doc = New-Object RawPrinterHelper+DOCINFOA
  $doc.pDocName = 'MangoPOS'
  $doc.pDataType = 'RAW'

  if (-not [RawPrinterHelper]::StartDocPrinter($handle, 1, $doc)) {
    $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    throw "START_DOC_FAILED $err"
  }
  $docStarted = $true

  if (-not [RawPrinterHelper]::StartPagePrinter($handle)) {
    $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    throw "START_PAGE_FAILED $err"
  }
  $pageStarted = $true

  $written = 0
  if (-not [RawPrinterHelper]::WritePrinter($handle, $bytes, $bytes.Length, [ref]$written)) {
    $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    throw "WRITE_PRINTER_FAILED $err"
  }

  if ($written -ne $bytes.Length) {
    throw "WRITE_PRINTER_INCOMPLETE $written/$($bytes.Length)"
  }
}
finally {
  if ($pageStarted) { [void][RawPrinterHelper]::EndPagePrinter($handle) }
  if ($docStarted) { [void][RawPrinterHelper]::EndDocPrinter($handle) }
  if ($handle -ne [IntPtr]::Zero) { [void][RawPrinterHelper]::ClosePrinter($handle) }
}
`;

    return new Promise((resolve, reject) => {
        const child = spawn('powershell', [
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-Command', '-',
        ], { windowsHide: true });

        let stderr = '';
        let stdout = '';
        child.stdout.on('data', (chunk) => { stdout += chunk.toString(); });
        child.stderr.on('data', (chunk) => { stderr += chunk.toString(); });

        const timer = setTimeout(() => {
            try { child.kill(); } catch (_) {}
            reject(new Error('WINSPOOL_TIMEOUT (30s)'));
        }, 30000);

        child.on('error', (err) => {
            clearTimeout(timer);
            reject(err);
        });

        child.on('close', (code) => {
            clearTimeout(timer);
            if (code === 0) {
                resolve();
            } else {
                const msg = stderr.trim() || stdout.trim() || `winspool exit code ${code}`;
                reject(new Error(msg));
            }
        });

        child.stdin.write(script);
        child.stdin.end();
    });
}

async function processPrintJob(job) {
    return new Promise(async (resolve, reject) => {
        logger.info(`?? Procesando job ${job.id} tipo: ${job.printer?.type || 'unknown'} - Contenido: ${job.content?.type}`);


        const content = job.content;
        const printerConfig = job.printer;


        if (!printerConfig) return reject(new Error("No printer configuration provided in job"));

        logger.info(`?? Printer payload ${describePrinter(printerConfig)}`);

        // ===========================================================
        // Fast path: Windows + USB + raw_base64 → winspool (sin Zadig).
        // Evita escpos.USB() que requiere libusb (driver Zadig). Usa
        // OpenPrinter / WritePrinter contra el spooler de Windows con
        // el driver estándar instalado por el OEM o uno genérico RAW.
        // ===========================================================
        if (
            process.platform === 'win32' &&
            printerConfig.type === 'usb' &&
            content && content.type === 'raw_base64'
        ) {
            const dataBase64 = content.dataBase64 || job.dataBase64;
            if (!dataBase64) {
                return reject(new Error('Missing dataBase64 in raw job'));
            }
            try {
                logger.info(`?? Winspool path para USB ${printerConfig.name || ''} (sin Zadig)`);
                await printRawViaWinspoolWindows(printerConfig, dataBase64);
                return resolve();
            } catch (err) {
                logger.error(`? Winspool failed: ${err.message}. Cayendo a libusb fallback.`);
                // Fallback a escpos.USB() si winspool falla por algún motivo
                // (ej. impresora no instalada en Windows). Si Zadig está OK,
                // este fallback funciona; sino, ambos fallan y el caller
                // verá el error original de winspool.
            }
        }

        try {
            let device;
            if (printerConfig.type === 'network') {
                if (!printerConfig.ip) throw new Error("IP Address missing for network printer");
                const sanitizedIp = printerConfig.ip.split('/')[0];
                logger.info(`?? Conectando a impresora de red: ${sanitizedIp}:${printerConfig.port || 9100}`);
                device = new escpos.Network(sanitizedIp, printerConfig.port || 9100);
            } else if (printerConfig.type === 'usb') {
                const usbSelection = resolveUsbSelection(printerConfig);
                if (usbSelection.vid !== null && usbSelection.pid !== null) {
                    logger.info(`?? Conectando a impresora USB ${printerConfig.name || ''} por VID/PID ${usbSelection.vid.toString(16)}:${usbSelection.pid.toString(16)} (${usbSelection.source})`);
                    device = new escpos.USB(usbSelection.vid, usbSelection.pid);
                } else {
                    logger.warn(`?? Impresora USB sin VID/PID resoluble. Intentando auto-detect. payload=${describePrinter(printerConfig)}`);
                    device = new escpos.USB();
                }
            } else {
                logger.info("?? Usando Consola (Printer Type no reconocido o 'test')");
                device = new escpos.Console();
            }


            const printer = new escpos.Printer(device);


            device.open(async function (error) {
                if (error) {
                    const message = error?.message || String(error);
                    logger.error(`? Error abriendo conexion con impresora: ${message} payload=${describePrinter(printerConfig)}`);
                    return reject(new Error(`No se pudo abrir la impresora ${printerConfig.name || ''}. ${message}`.trim()));
                }
                if (false && error) {
                    logger.error(`? Error abriendo conexión con impresora: ${error}`);
                    return reject(error);
                }


                try {
                    // 1. INIT & CONFIG
                    device.write(CMD.RESET);
                    await new Promise(r => setTimeout(r, 150)); // Wait for reset


                    device.write(CMD.CODEPAGE_PC850); // CP850 para español
                    device.write(CMD.DOUBLE_STRIKE_ON); // High Quality (Darker)
                    await new Promise(r => setTimeout(r, 50));


                    // Configurar encoding
                    printer.encoding = 'cp850';


                    // 2. PRINTING
                    if (content.type === 'raw_base64') {
                        const dataBase64 = content.dataBase64 || job.dataBase64;
                        if (!dataBase64) {
                            throw new Error('Missing dataBase64 in raw job');
                        }
                        const payload = Buffer.from(dataBase64, 'base64');
                        device.write(payload);
                        printer.feed(3).cut().close();
                    } else if (content.type === 'precheck') {
                        await printPreCheck(device, printer, content.data);
                    } else if (content.type === 'invoice') {
                        await printInvoice(device, printer, content.data);
                    } else {
                        // Legacy
                        device.write(CMD.ALIGN_CENTER);
                        device.write(CMD.BOLD_ON);
                        printer.text(content.title || 'Mango POS');
                        device.write(CMD.BOLD_OFF);
                        device.write(CMD.ALIGN_LEFT);
                        if (content.body) printer.text(content.body);
                        printer.feed(2).cut().close();
                    }
                    resolve();
                } catch (err) {
                    try { printer.close(); } catch (e) { }
                    reject(err);
                }
            });
        } catch (e) {
            reject(e);
        }
    });
}


async function printPreCheck(device, printer, data) {
    return new Promise((resolve, reject) => {
        try {
            logger.info('🖨️ Imprimiendo Pre-Cuenta (RAW)...');


            // ================= HEADER =================
            printer.align('ct');
            device.write(CMD.BOLD_ON);
            printer.text(data.restaurantName || 'MANGO POS RESTAURANT');
            device.write(CMD.BOLD_OFF);
            printer.text('RNC: ' + (data.rnc || '101-00000-1'));
            printer.text('Tel: ' + (data.phone || '809-555-0101'));
            printer.feed(1);


            printer.text(drawLine('='));
            printer.text('PRE-CUENTA');
            printer.text(drawLine('='));
            printer.feed(1);

            printer.align('lt');

            // ================= INFO ORDEN ==============
            device.write(CMD.BOLD_ON);
            printer.text('ORDEN: ' + (data.orderNumber || '---'));
            device.write(CMD.BOLD_OFF);
            printer.feed(1);
            printer.text('Mesa:   ' + (data.tableName || 'N/A'));
            printer.text('Mesero: ' + (data.waiterName || 'N/A'));
            printer.text('Fecha:  ' + getSafeDate());
            printer.feed(1);
            printer.text(drawLine('-'));


            // ================= ITEMS ===================
            if (data.items && Array.isArray(data.items)) {
                data.items.forEach(item => {
                    device.write(CMD.BOLD_ON);
                    printer.text(item.name || '');
                    device.write(CMD.BOLD_OFF);

                    const qtyPrice = `${item.quantity || 1} x ${fmtMoney(item.price || 0)}`;
                    const totalLine = fmtMoney(item.total || ((item.quantity || 1) * (item.price || 0)));
                    const spaceLen = PRINTER_WIDTH - (qtyPrice.length + totalLine.length);
                    const dots = spaceLen > 0 ? '.'.repeat(spaceLen) : ' ';
                    printer.text(qtyPrice + dots + totalLine);

                    if (item.modifiers && Array.isArray(item.modifiers)) {
                        item.modifiers.forEach(mod => printer.text('  + ' + mod));
                    }
                    if (item.note) {
                        printer.text('  (NOTA: ' + item.note + ')');
                    }
                });
            }

            printer.text(drawLine('-'));
            printer.feed(1);

            // ================= TOTALES =================
            const printTotal = (lbl, val, bold = false) => {
                if (bold) device.write(CMD.BOLD_ON);
                const v = fmtMoney(val || 0);
                const s = PRINTER_WIDTH - (lbl.length + v.length);
                const spacer = s > 0 ? ' '.repeat(s) : ' ';
                printer.text(lbl + spacer + v);
                if (bold) device.write(CMD.BOLD_OFF);
            };


            printTotal('Subtotal:', data.subtotal || 0);
            if ((data.serviceFee || 0) > 0) printTotal('Servicio (10%):', data.serviceFee);
            printTotal('ITBIS (18%):', data.tax || 0);
            if ((data.discount || 0) > 0) printTotal('Descuento:', -(data.discount));


            printer.feed(1);


            // ================= TOTAL ==================
            printer.align('ct');
            printer.style('b');
            printer.text(drawLine('='));
            printer.text('TOTAL');
            printer.text(fmtMoney(data.total || 0));
            printer.text(drawLine('='));
            printer.style('normal');
            printer.feed(2);

            // ================= FOOTER =================
            printer.align('ct');
            printer.text('ESTE DOCUMENTO NO ES UN');
            printer.text('COMPROBANTE FISCAL');
            printer.feed(1);
            printer.text('Gracias por su preferencia');
            printer.text('¡Vuelva pronto!');
            printer.feed(3);

            printer.cut();
            printer.close();
            resolve();


        } catch (e) {
            logger.error(`❌ Error PC: ${e.message}`);
            try { printer.close(); } catch (err) { }
            reject(e);
        }
    });
}



async function printInvoice(device, printer, data) {
    return new Promise((resolve, reject) => {
        try {
            logger.info('🖨️ Imprimiendo Factura (RAW)...');

            const addLine = (txt = '') => printer.text(txt);
            const addSep = (char = '-', len = PRINTER_WIDTH) => printer.text(char.repeat(len));

            printer.align('ct');
            device.write(CMD.BOLD_ON);
            addLine(data.restaurantName || 'MANGO POS RESTAURANT');
            device.write(CMD.BOLD_OFF);


            addLine('RNC: ' + (data.rnc || '101-00000-1'));
            addLine('Tel: ' + (data.phone || '809-555-0101'));
            if (data.address) addLine(data.address);
            printer.feed(1);


            // TITULO
            device.write(CMD.BOLD_ON);
            addSep('=');
            addLine(data.invoiceType || 'FACTURA DE CONSUMO');
            addSep('=');
            device.write(CMD.BOLD_OFF);
            printer.feed(1);


            printer.align('lt');


            if (data.ncf) addLine('NCF: ' + data.ncf);
            if (data.ncfExpiredDate) addLine('Vence: ' + data.ncfExpiredDate);
            printer.feed(1);


            addSep('-');


            if (data.items && Array.isArray(data.items)) {
                data.items.forEach(item => {


                    device.write(CMD.BOLD_ON);
                    addLine(item.name || '');
                    device.write(CMD.BOLD_OFF);


                    const qtyPrice = (item.quantity || 1) + ' x ' + fmtMoney(item.price || 0);
                    const totalLine = fmtMoney(item.total || 0);


                    const spaceLen = PRINTER_WIDTH - (qtyPrice.length + totalLine.length);
                    const dots = spaceLen > 0 ? '.'.repeat(spaceLen) : ' ';


                    addLine(qtyPrice + dots + totalLine);
                });
            }


            addSep('-');
            printer.feed(1);


            const printTotal = (lbl, val, bold = false) => {
                if (bold) device.write(CMD.BOLD_ON);
                const v = fmtMoney(val || 0);
                const s = PRINTER_WIDTH - (lbl.length + v.length);
                const spacer = s > 0 ? ' '.repeat(s) : ' ';
                addLine(lbl + spacer + v);
                if (bold) device.write(CMD.BOLD_OFF);
            };


            printTotal('Subtotal:', data.subtotal || 0);
            if ((data.serviceFee || 0) > 0) printTotal('Ley 10%:', data.serviceFee);
            printTotal('ITBIS 18%:', data.tax || 0);
            if ((data.discount || 0) > 0) printTotal('Descuento:', -(data.discount));


            printer.feed(1);


            // 🧾 BLOQUE TOTAL (factura) — centrado
            printer.align('ct');
            printer.style('b');
            addSep('=');
            addLine('TOTAL');
            addLine(fmtMoney(data.total || 0));
            addSep('=');
            printer.style('normal');
            printer.feed(1);


            // FORMAS DE PAGO (tamaño normal)
            printer.align('lt');
            printer.size(1, 1);
            printer.style('normal');

            if (data.payments && Array.isArray(data.payments)) {
                printer.text('FORMA DE PAGO:');
                data.payments.forEach(p =>
                    printTotal('  ' + (p.method || ''), p.amount || 0)
                );
                if ((data.change || 0) > 0) {
                    printer.feed(1);
                    printTotal('SU CAMBIO:', data.change, true);
                }
            }


            printer.feed(2);


            printer.align('ct');
            printer.size(1, 1);
            printer.style('normal');
            printer.text('¡Gracias por su visita!');
            if (data.wifiPass) printer.text('WIFI: ' + data.wifiPass);
            printer.feed(3);


            printer.cut();
            printer.close();
            resolve();


        } catch (e) {
            logger.error(`? Error Factura: ${e.message}`);
            try { printer.close(); } catch (err) { }
            reject(e);
        }
    });
}



// ==========================================
// SERVIDOR HTTP LOCAL (API para Flutter Web)
// ==========================================
const express = require('express');
const cors = require('cors');
const net = require('net'); // Para chequear conectividad TCP de impresoras


const app = express();
const LOCAL_PORT = 4000;


app.use(cors({
    origin: true, // Allow all origins
    credentials: true,
    methods: ['GET', 'POST', 'OPTIONS'],
    allowedHeaders: ['Content-Type', 'Authorization', 'Access-Control-Allow-Private-Network'],
}));


// Middleware para Private Network Access (Chrome/Edge)
app.use((req, res, next) => {
    res.setHeader("Access-Control-Allow-Private-Network", "true");
    next();
});


app.use(express.json());


// 1. Endpoint de Estado (Health Check)
app.get('/health', (req, res) => {
    res.json({
        status: 'ok',
        agent: AGENT_ID,
        version: '1.0.0'
    });
});

app.get('/status', (req, res) => {
    res.json({
        status: 'online',
        agent: AGENT_ID,
        version: '1.0.0'
    });
});


// 2. Endpoint de Verificación de Impresoras (Ping)
app.post('/check-connectivity', async (req, res) => {
    const { printers } = req.body; // Espera array de { ip, port }


    if (!printers || !Array.isArray(printers)) {
        return res.status(400).json({ error: 'Invalid printers list' });
    }


    const results = {};


    // Chequear cada impresora en paralelo
    await Promise.all(printers.map(async (p) => {
        if (!p.ip) return;
        const isOnline = await checkPrinterStatus(p.ip, p.port || 9100);
        results[p.ip] = isOnline;
    }));


    res.json({ results });
});


// 3. Endpoint de Impresión Directa (Local)
app.post('/print', async (req, res) => {
    const job = req.body;
    if (!job.id) job.id = `LOCAL-${Date.now()}`;


    try {
        logger.info(`?? Recibida petición local de impresión: ${job.id}`);
        await processPrintJob(job);
        res.json({ success: true, jobId: job.id });
    } catch (error) {
        logger.error(`? Error en impresión local: ${error.message}`);
        res.status(500).json({ success: false, error: error.message });
    }
});

// Endpoint para servir la UI estática (si existe)
app.use(express.static(path.join(baseDir, 'public')));

// 4. Endpoint de impresión RAW (base64/hex)
// body: { ip, port=9100, dataBase64?, dataHex? }
app.post('/api/printers/raw', async (req, res) => {
    try {
        const ip = req.body?.ip;
        const port = req.body?.port || 9100;
        const dataBase64 = req.body?.dataBase64;
        const dataHex = req.body?.dataHex;

        if (!ip) {
            return res.status(400).json({ ok: false, error: 'Missing ip' });
        }
        if (!dataBase64 && !dataHex) {
            return res.status(400).json({ ok: false, error: 'Missing dataBase64/dataHex' });
        }

        const payload = dataBase64
            ? Buffer.from(dataBase64, 'base64')
            : Buffer.from(dataHex, 'hex');

        await sendRawTcp(ip, port, payload);
        return res.json({ ok: true });
    } catch (error) {
        logger.error(`Error RAW print: ${error.message}`);
        return res.status(500).json({ ok: false, error: error.message });
    }
});

app.get('/api/printers/discover', async (req, res) => {
    try {
        const devices = await discoveryService.scan();
        const items = devices.map((device) => ({
            type: device.type || 'network',
            name: device.name || 'Printer',
            ip: device.address && device.type === 'network' ? device.address : null,
            port: device.port || 9100,
            mac: device.deviceId || null,
            deviceId: device.deviceId || device.address || null,
            vid: device.vid || null,
            pid: device.pid || null,
        }));
        res.json({ items });
    } catch (error) {
        logger.error(`Discovery error: ${error.message}`);
        res.status(500).json({ items: [], error: error.message });
    }
});

function sendRawTcp(ip, port, payload, timeout = 8000) {
    return new Promise((resolve, reject) => {
        const socket = new net.Socket();
        let settled = false;
        const finish = (err) => {
            if (settled) return;
            settled = true;
            try { socket.destroy(); } catch (_) { }
            err ? reject(err) : resolve();
        };

        const timer = setTimeout(() => finish(new Error('connect timeout')), timeout);
        socket.once('connect', () => {
            clearTimeout(timer);
            socket.write(payload, (err) => {
                if (err) return finish(err);
                socket.end(() => finish());
            });
        });
        socket.once('error', (err) => {
            clearTimeout(timer);
            finish(err || new Error('socket error'));
        });
        socket.connect(port, ip);
    });
}


// Función auxiliar para chequear puertos TCP
function checkPrinterStatus(ip, port, timeout = 1500) {
    return new Promise((resolve) => {
        const socket = new net.Socket();
        let status = false;


        socket.setTimeout(timeout);


        socket.on('connect', () => {
            status = true;
            socket.destroy();
        });


        socket.on('timeout', () => {
            socket.destroy();
        });


        socket.on('error', () => {
            socket.destroy();
        });


        socket.on('close', () => {
            resolve(status);
        });


        socket.connect(port, ip);
    });
}

function runPowerShell(script) {
    return new Promise((resolve, reject) => {
        const escaped = script.replace(/"/g, '\\"');
        exec(`powershell -NoProfile -ExecutionPolicy Bypass -Command "${escaped}"`, {
            windowsHide: true,
        }, (error, stdout, stderr) => {
            if (error) {
                reject(new Error((stderr || error.message || '').trim()));
                return;
            }
            resolve((stdout || '').trim());
        });
    });
}

async function getLocalApiListener() {
    if (process.platform !== 'win32') return null;

    const script = [
        `$conn = Get-NetTCPConnection -LocalPort ${LOCAL_PORT} -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1`,
        'if (-not $conn) { return }',
        '$proc = Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue',
        '[pscustomobject]@{ pid = $conn.OwningProcess; name = if ($proc) { $proc.ProcessName } else { $null } } | ConvertTo-Json -Compress',
    ].join('; ');

    try {
        const raw = await runPowerShell(script);
        if (!raw) return null;
        return JSON.parse(raw);
    } catch (error) {
        logger.warn(`No se pudo inspeccionar el puerto ${LOCAL_PORT}: ${error.message}`);
        return null;
    }
}

async function stopExistingAgentOnLocalPort() {
    const listener = await getLocalApiListener();
    if (!listener || !listener.pid || listener.pid === process.pid) {
        return false;
    }

    const processName = String(listener.name || '').toLowerCase();
    const looksLikeAgent =
        processName.includes('mangopos-agent') ||
        processName === 'node' ||
        processName === 'node.exe';

    if (!looksLikeAgent) {
        logger.warn(`El puerto ${LOCAL_PORT} esta ocupado por ${listener.name || 'otro proceso'} (PID ${listener.pid}). No se detendra automaticamente.`);
        return false;
    }

    logger.warn(`Se detecto una instancia previa del agente en el puerto ${LOCAL_PORT} (PID ${listener.pid}, ${listener.name}). Se intentara reiniciar.`);

    try {
        await runPowerShell(`Stop-Process -Id ${listener.pid} -Force -ErrorAction Stop`);
    } catch (error) {
        logger.error(`No se pudo detener la instancia previa del agente (PID ${listener.pid}): ${error.message}`);
        return false;
    }

    for (let attempt = 0; attempt < 10; attempt += 1) {
        await new Promise((resolve) => setTimeout(resolve, 300));
        const current = await getLocalApiListener();
        if (!current || current.pid === process.pid) {
            logger.info(`Puerto ${LOCAL_PORT} liberado correctamente.`);
            return true;
        }
    }

    logger.error(`La instancia previa del agente no libero el puerto ${LOCAL_PORT} a tiempo.`);
    return false;
}

async function startLocalApiServer() {
    await stopExistingAgentOnLocalPort();

    app.listen(LOCAL_PORT, () => {
        logger.info(`ðŸš€ Local API escuchando en http://localhost:${LOCAL_PORT}`);
    }).on('error', (err) => {
        if (err.code === 'EADDRINUSE') {
            logger.error(`âŒ El puerto ${LOCAL_PORT} ya estÃ¡ en uso. El agente seguirÃ¡ operando vÃ­a Socket.io si es posible.`);
        } else {
            logger.error(`âŒ Error iniciando servidor API: ${err.message}`);
        }
    });
}


startLocalApiServer();

// Iniciar Servidor HTTP
if (false) app.listen(LOCAL_PORT, () => {
    logger.info(`🚀 Local API escuchando en http://localhost:${LOCAL_PORT}`);
}).on('error', (err) => {
    if (err.code === 'EADDRINUSE') {
        logger.error(`❌ El puerto ${LOCAL_PORT} ya está en uso. El agente seguirá operando vía Socket.io si es posible.`);
    } else {
        logger.error(`❌ Error iniciando servidor API: ${err.message}`);
    }
});



// ==========================================
// Mantener proceso vivo
// ==========================================
process.on('uncaughtException', (err) => {
    logger.error('CRITICAL ERROR:', err);
});




