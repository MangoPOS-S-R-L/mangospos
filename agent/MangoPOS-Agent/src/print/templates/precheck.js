// PRD 7 Fase 1.0 — Template ESC/POS de Pre-Cuenta.

const { logger } = require('../../config');
const {
    CMD,
    PRINTER_WIDTH,
    fmtMoney,
    drawLine,
    getSafeDate,
} = require('../escpos_helpers');

const printPreCheck = (device, printer, data) => new Promise((resolve, reject) => {
    try {
        logger.info('Imprimiendo Pre-Cuenta (RAW)...');

        // ── HEADER ──────────────────────────────────────────────────
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

        // ── INFO ORDEN ──────────────────────────────────────────────
        device.write(CMD.BOLD_ON);
        printer.text('ORDEN: ' + (data.orderNumber || '---'));
        device.write(CMD.BOLD_OFF);
        printer.feed(1);
        printer.text('Mesa:   ' + (data.tableName || 'N/A'));
        printer.text('Mesero: ' + (data.waiterName || 'N/A'));
        printer.text('Fecha:  ' + getSafeDate());
        printer.feed(1);
        printer.text(drawLine('-'));

        // ── ITEMS ───────────────────────────────────────────────────
        if (data.items && Array.isArray(data.items)) {
            data.items.forEach((item) => {
                device.write(CMD.BOLD_ON);
                printer.text(item.name || '');
                device.write(CMD.BOLD_OFF);

                const qtyPrice = `${item.quantity || 1} x ${fmtMoney(item.price || 0)}`;
                const totalLine = fmtMoney(item.total || ((item.quantity || 1) * (item.price || 0)));
                const spaceLen = PRINTER_WIDTH - (qtyPrice.length + totalLine.length);
                const dots = spaceLen > 0 ? '.'.repeat(spaceLen) : ' ';
                printer.text(qtyPrice + dots + totalLine);

                if (item.modifiers && Array.isArray(item.modifiers)) {
                    item.modifiers.forEach((mod) => printer.text('  + ' + mod));
                }
                if (item.note) {
                    printer.text('  (NOTA: ' + item.note + ')');
                }
            });
        }

        printer.text(drawLine('-'));
        printer.feed(1);

        // ── TOTALES ─────────────────────────────────────────────────
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

        // ── TOTAL ───────────────────────────────────────────────────
        printer.align('ct');
        printer.style('b');
        printer.text(drawLine('='));
        printer.text('TOTAL');
        printer.text(fmtMoney(data.total || 0));
        printer.text(drawLine('='));
        printer.style('normal');
        printer.feed(2);

        // ── FOOTER ──────────────────────────────────────────────────
        printer.align('ct');
        printer.text('ESTE DOCUMENTO NO ES UN');
        printer.text('COMPROBANTE FISCAL');
        printer.feed(1);
        printer.text('Gracias por su preferencia');
        printer.text('Vuelva pronto');
        printer.feed(3);

        printer.cut();
        printer.close();
        resolve();
    } catch (e) {
        logger.error(`Error PreCuenta: ${e.message}`);
        try { printer.close(); } catch (_) {}
        reject(e);
    }
});

module.exports = { printPreCheck };
