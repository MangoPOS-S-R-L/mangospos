const escpos = require('escpos');
// const device = new escpos.Network('localhost'); // Dummy device
// const printer = new escpos.Printer(device); 

// Example: Function to generate BASE64 string for a receipt
function generateReceiptBase64() {
    // Note: Since escpos library writes to a device, we can capture the buffer by mocking the device write method or using an in-memory buffer approach if the library supports it.
    // However, the standard library is device-centric.
    // Here is a conceptual example of what commands to send.

    // Command Buffer (Manual Construction for clarity)
    const commands = [];

    // Init
    commands.push(0x1B, 0x40);

    // Center Align
    commands.push(0x1B, 0x61, 1);

    // Title (Double Height/Width) -> GS ! n
    commands.push(0x1D, 0x21, 0x11);
    commands.push(...Buffer.from('MANGO POS\n'));
    commands.push(0x1D, 0x21, 0x00); // Normal text

    commands.push(...Buffer.from('123 Main St, City\n'));
    commands.push(...Buffer.from('Tel: 555-0199\n\n'));

    // Left Align
    commands.push(0x1B, 0x61, 0);
    commands.push(...Buffer.from('Order #1001           Table: 5\n'));
    commands.push(...Buffer.from('Date: 2026-02-07 13:05\n'));
    commands.push(...Buffer.from('--------------------------------\n'));

    // Items
    commands.push(...Buffer.from('1x  Burger             $12.00\n'));
    commands.push(...Buffer.from('2x  Coke               $ 4.00\n'));
    commands.push(...Buffer.from('1x  Fries              $ 3.50\n'));
    commands.push(...Buffer.from('--------------------------------\n'));

    // Right Align Total
    commands.push(0x1B, 0x61, 2);
    commands.push(...Buffer.from('TOTAL: $19.50\n'));

    // Feed & Cut
    commands.push(0x0A, 0x0A, 0x0A, 0x0A);
    commands.push(0x1D, 0x56, 66, 0); // Partial cut

    const buffer = Buffer.from(commands);
    return buffer.toString('base64');
}

console.log('--- RECEPT RAW (BASE64) ---');
console.log(generateReceiptBase64());
