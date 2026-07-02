// PRD 7 Fase 1.0 — Path Windows USB sin Zadig (winspool.drv).
//
// Resuelve el bug de "USB no imprime sin instalar Zadig" usando
// OpenPrinter/WritePrinter del print spooler nativo de Windows. El
// PowerShell inline declara `RawPrinterHelper` (P/Invoke) y manda los
// bytes RAW al driver estándar instalado por el OEM o uno genérico.
//
// Si la impresora no está instalada en Windows como printer (caso
// raro), el caller debe caer al path libusb (escpos-usb).

const { spawn } = require('child_process');
const { escapePsSingleQuoted } = require('../platform/windows');

// Timeout duro para que un winspool colgado no bloquee la cola del
// agente para siempre. PRD 7 Fase 2 agregará reintentos con backoff.
const WINSPOOL_TIMEOUT_MS = 30000;

const printRawViaWinspoolWindows = (printerConfig, base64Payload) => {
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
  # Fallback difuso alineado con el discovery: no exigir "PortName -match
  # '^USB'" (descartaba termicas 2Connect/ZJiang/POS80 con puerto custom
  # POS001/CP001/GP001). Mismos filtros de exclusion que Win32_Printer usa
  # para listar impresoras locales imprimibles.
  $target = Get-CimInstance Win32_Printer |
    Where-Object {
      $_.Local -eq $true -and
      $_.PortName -notmatch '^(PORTPROMPT|FILE|XPSPort|SHRFAX|FaxPort|nul|IP_|WSD-|http|lpr)' -and
      $_.DriverName -notmatch '(XPS|PDF|OneNote|Fax|Send To OneNote|Microsoft Print)' -and (
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
            reject(new Error(`WINSPOOL_TIMEOUT (${WINSPOOL_TIMEOUT_MS / 1000}s)`));
        }, WINSPOOL_TIMEOUT_MS);

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
};

module.exports = { printRawViaWinspoolWindows, WINSPOOL_TIMEOUT_MS };
