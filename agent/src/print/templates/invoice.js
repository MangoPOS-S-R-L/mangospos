// PRD 7 Fase 1.0 — Template ESC/POS de Factura.

const { logger } = require('../../config');
const {
    CMD,
    PRINTER_WIDTH,
    fmtMoney,
} = require('../escpos_helpers');

const printInvoice = (device, printer, data) => new Promise((resolve, reject) => {
    try {
        logger.info('Imprimiendo Factura (RAW)...');

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

        // ── TITULO ──────────────────────────────────────────────────
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

        // ── ITEMS ───────────────────────────────────────────────────
        if (data.items && Array.isArray(data.items)) {
            data.items.forEach((item) => {
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

        // ── TOTALES ─────────────────────────────────────────────────
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

        // ── TOTAL ───────────────────────────────────────────────────
        printer.align('ct');
        printer.style('b');
        addSep('=');
        addLine('TOTAL');
        addLine(fmtMoney(data.total || 0));
        addSep('=');
        printer.style('normal');
        printer.feed(1);

        // ── FORMAS DE PAGO ──────────────────────────────────────────
        printer.align('lt');
        printer.size(1, 1);
        printer.style('normal');

        if (data.payments && Array.isArray(data.payments)) {
            printer.text('FORMA DE PAGO:');
            data.payments.forEach((p) =>
                printTotal('  ' + (p.method || ''), p.amount || 0));
            if ((data.change || 0) > 0) {
                printer.feed(1);
                printTotal('SU CAMBIO:', data.change, true);
            }
        }

        printer.feed(2);

        printer.align('ct');
        printer.size(1, 1);
        printer.style('normal');
        printer.text('Gracias por su visita');
        if (data.wifiPass) printer.text('WIFI: ' + data.wifiPass);
        printer.feed(3);

        printer.cut();
        printer.close();
        resolve();
    } catch (e) {
        logger.error(`Error Factura: ${e.message}`);
        try { printer.close(); } catch (_) {}
        reject(e);
    }
});

module.exports = { printInvoice };
