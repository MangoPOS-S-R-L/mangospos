// PRD 7 Fase 1.0 — Helpers ESC/POS y formatters de tickets.
//
// Constantes de comandos + utilidades de formato (centrado, padding,
// fechas) que usan los templates de impresión (precheck, invoice).

const { PRINTER_WIDTH } = require('../config');

const CMD = {
    RESET: '\x1B\x40',
    CODEPAGE_PC850: '\x1B\x74\x02',
    BOLD_ON: '\x1B\x45\x01',
    BOLD_OFF: '\x1B\x45\x00',
    DOUBLE_STRIKE_ON: '\x1B\x47\x01',
    DOUBLE_STRIKE_OFF: '\x1B\x47\x00',
    ALIGN_LEFT: '\x1B\x61\x00',
    ALIGN_CENTER: '\x1B\x61\x01',
    ALIGN_RIGHT: '\x1B\x61\x02',
    DENSITY_HIGH: '\x1D\x7C\x02',
    SIZE_NORMAL: '\x1D\x21\x00',
    SIZE_DOUBLE_WIDTH: '\x1D\x21\x10',
    SIZE_DOUBLE_HEIGHT: '\x1D\x21\x01',
    SIZE_DOUBLE: '\x1D\x21\x11',
};

const fmtMoney = (amount) =>
    'RD$ ' + (amount || 0).toFixed(2).replace(/\d(?=(\d{3})+\.)/g, '$&,');

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

const drawLine = (char = '-', len = PRINTER_WIDTH) => char.repeat(len);

const titleBlock = (txt) => [drawLine('='), center(txt), drawLine('=')];

const formatDate = () => {
    const now = new Date();
    return now.toLocaleString('es-DO', {
        day: '2-digit', month: '2-digit', year: 'numeric',
        hour: '2-digit', minute: '2-digit', hour12: true,
    });
};

// Fecha ASCII-only para impresoras térmicas que no manejan acentos.
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

module.exports = {
    CMD,
    PRINTER_WIDTH,
    fmtMoney,
    padRight,
    padLeft,
    center,
    drawLine,
    titleBlock,
    formatDate,
    getSafeDate,
};
