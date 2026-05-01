// PRD 7 Fase 1.0 — Orquestador de jobs de impresión.
//
// Recibe un `job` (con `printer` config + `content`), decide el path
// (winspool en Win+USB+raw, libusb fallback, network) y delega al
// template correcto (raw_base64, precheck, invoice).
//
// PRD 7 Fase 1.1 (próxima): este módulo se invoca desde el worker de
// la cola SQLite, no directo desde HTTP.

const escpos = require('escpos');
escpos.Network = require('escpos-network');
escpos.USB = require('escpos-usb');

const { logger } = require('../config');
const { CMD } = require('./escpos_helpers');
const { describePrinter, resolveUsbSelection } = require('./usb_selection');
const { printRawViaWinspoolWindows } = require('./winspool');
const { printPreCheck } = require('./templates/precheck');
const { printInvoice } = require('./templates/invoice');

const processPrintJob = (job) => new Promise(async (resolve, reject) => {
    logger.info(`Procesando job ${job.id} tipo: ${job.printer?.type || 'unknown'} - Contenido: ${job.content?.type}`);

    const content = job.content;
    const printerConfig = job.printer;

    if (!printerConfig) {
        return reject(new Error('No printer configuration provided in job'));
    }

    logger.info(`Printer payload ${describePrinter(printerConfig)}`);

    // ── Fast path: Windows + USB + raw_base64 → winspool (sin Zadig).
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
            logger.info(`Winspool path para USB ${printerConfig.name || ''} (sin Zadig)`);
            await printRawViaWinspoolWindows(printerConfig, dataBase64);
            return resolve();
        } catch (err) {
            logger.error(`Winspool failed: ${err.message}. Cayendo a libusb fallback.`);
            // Fallback a escpos.USB() si winspool falla. Si Zadig está
            // OK funciona; sino, ambos fallan y el caller ve el error.
        }
    }

    try {
        let device;
        if (printerConfig.type === 'network') {
            if (!printerConfig.ip) throw new Error('IP Address missing for network printer');
            const sanitizedIp = printerConfig.ip.split('/')[0];
            logger.info(`Conectando a impresora de red: ${sanitizedIp}:${printerConfig.port || 9100}`);
            device = new escpos.Network(sanitizedIp, printerConfig.port || 9100);
        } else if (printerConfig.type === 'usb') {
            const usbSelection = resolveUsbSelection(printerConfig);
            if (usbSelection.vid !== null && usbSelection.pid !== null) {
                logger.info(`Conectando a impresora USB ${printerConfig.name || ''} por VID/PID ${usbSelection.vid.toString(16)}:${usbSelection.pid.toString(16)} (${usbSelection.source})`);
                device = new escpos.USB(usbSelection.vid, usbSelection.pid);
            } else {
                logger.warn(`Impresora USB sin VID/PID resoluble. Intentando auto-detect. payload=${describePrinter(printerConfig)}`);
                device = new escpos.USB();
            }
        } else {
            throw new Error(`Tipo de impresora no soportado por el agente: ${printerConfig.type}. Tipos validos: network, usb (winspool en Windows), bluetooth (via cliente Flutter directo).`);
        }

        const printer = new escpos.Printer(device);

        device.open(async (error) => {
            if (error) {
                const message = error?.message || String(error);
                logger.error(`Error abriendo conexion con impresora: ${message} payload=${describePrinter(printerConfig)}`);
                return reject(new Error(`No se pudo abrir la impresora ${printerConfig.name || ''}. ${message}`.trim()));
            }

            try {
                // 1. INIT & CONFIG
                device.write(CMD.RESET);
                await new Promise((r) => setTimeout(r, 150));
                device.write(CMD.CODEPAGE_PC850);
                device.write(CMD.DOUBLE_STRIKE_ON);
                await new Promise((r) => setTimeout(r, 50));
                printer.encoding = 'cp850';

                // 2. PRINTING
                if (content.type === 'raw_base64') {
                    const dataBase64 = content.dataBase64 || job.dataBase64;
                    if (!dataBase64) throw new Error('Missing dataBase64 in raw job');
                    const payload = Buffer.from(dataBase64, 'base64');
                    device.write(payload);
                    printer.feed(3).cut().close();
                } else if (content.type === 'precheck') {
                    await printPreCheck(device, printer, content.data);
                } else if (content.type === 'invoice') {
                    await printInvoice(device, printer, content.data);
                } else {
                    // Legacy: payload simple con title + body.
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
                try { printer.close(); } catch (_) {}
                reject(err);
            }
        });
    } catch (e) {
        reject(e);
    }
});

module.exports = { processPrintJob };
