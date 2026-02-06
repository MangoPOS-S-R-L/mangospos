const escpos = require('escpos');
escpos.USB = require('escpos-usb');

console.log("🔍 Searching for USB Printers...");

try {
    const device = new escpos.USB(); // Initializes connection to the first USB printer found
    console.log("✅ Printer FOUND!");
    console.log("Device Info:", device);

    const printer = new escpos.Printer(device);

    console.log("🖨️  Attempting to print...");

    device.open(function (error) {
        if (error) {
            console.error("❌ Failed to open printer:", error);
            return;
        }

        printer
            .font('a')
            .align('ct')
            .style('bu')
            .size(1, 1)
            .text('MangoPOS Hardware Test')
            .text('Si puedes leer esto,')
            .text('Tu impresora USB funciona!')
            .cut()
            .close();

        console.log("✅ Print command sent successfully.");
    });

} catch (e) {
    console.error("❌ No USB Printer found or Driver Error.");
    console.error("Si usas Windows, asegurate de haber instalado el driver WinUSB con Zadig para tu impresora, o que no esté siendo usada por otro driver.");
    console.error("Error details:", e.message);
}
