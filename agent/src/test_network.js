const escpos = require('escpos');
escpos.Network = require('escpos-network');

// CONFIGURA AQUI LA IP DE TU IMPRESORA
const PRINTER_IP = '192.168.0.172'; // <--- CAMBIA ESTO POR LA IP REAL
const PRINTER_PORT = 9100;

console.log(`🔍 Intentando conectar a impresora de red en ${PRINTER_IP}:${PRINTER_PORT}...`);

try {
    const device = new escpos.Network(PRINTER_IP, PRINTER_PORT);
    const printer = new escpos.Printer(device);

    console.log("🖨️  Enviando prueba de impresión...");

    device.open(function (error) {
        if (error) {
            console.error("❌ No se pudo conectar a la impresora:", error);
            return;
        }

        console.log("✅ Conexión establecida! Imprimiendo...");

        printer
            .font('a')
            .align('ct')
            .style('bu')
            .size(1, 1)
            .text('MangoPOS Network Test')
            .text(`IP: ${PRINTER_IP}`)
            .text('Si lees esto, funciona por RED!')
            .cut()
            .close();

        console.log("✅ Comando enviado. Revisa la impresora.");
    });

} catch (e) {
    console.error("❌ Error inesperado:", e);
}
