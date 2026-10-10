const escpos = require('escpos');
const { CMD } = require('./escpos_helpers');
const { printPreCheck } = require('./templates/precheck');
const { printInvoice } = require('./templates/invoice');

async function renderNetworkContent(content = {}, job = {}, encoding = 'cp850') {
    if (content.type === 'raw_hex') {
        const hex = String(content.dataHex || job.dataHex || '').replace(/\s/g, '');
        if (!hex || hex.length % 2 || !/^[0-9a-f]+$/i.test(hex)) throw new Error('Invalid raw hex ticket');
        return Buffer.from(hex, 'hex');
    }
    if (content.type === 'raw_base64' || content.type === 'raw') {
        const value = content.dataBase64 || job.dataBase64 || content.content;
        if (typeof value !== 'string' || !value || !/^[A-Za-z0-9+/]*={0,2}$/.test(value) || value.length % 4 === 1) {
            throw new Error('Invalid raw base64 ticket');
        }
        return Buffer.from(value, 'base64');
    }
    const chunks = [];
    const device = {
        write(data, callback) { chunks.push(Buffer.isBuffer(data) ? Buffer.from(data) : Buffer.from(data, 'binary')); callback?.(); return this; },
        close(callback) { callback?.(); return this; },
    };
    const printer = new escpos.Printer(device, { encoding });
    device.write(CMD.RESET + CMD.CODEPAGE_PC850 + CMD.DOUBLE_STRIKE_ON);
    if (content.type === 'precheck') await printPreCheck(device, printer, content.data);
    else if (content.type === 'invoice') await printInvoice(device, printer, content.data);
    else {
        if (content.type === 'text') printer.text(content.content || '');
        else {
            printer.align('ct').style('b').text(content.title || 'Mango POS').style('normal').align('lt');
            if (content.body) printer.text(content.body);
        }
        printer.feed(2).cut().close();
    }
    return Buffer.concat(chunks);
}
module.exports = { renderNetworkContent };
