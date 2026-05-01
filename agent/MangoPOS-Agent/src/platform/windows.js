// PRD 7 Fase 1.0 — Helpers Windows-específicos.
//
// PowerShell exec helpers + detección/limpieza de instancias previas
// del agente en el puerto LAN. Cross-platform safe: en Mac/Linux las
// funciones retornan null/false sin error.

const { exec } = require('child_process');
const { logger, LOCAL_PORT } = require('../config');

// Escapa string para insertar dentro de single-quotes de PowerShell:
// dentro de single quotes, una comilla simple se escribe doblada.
const escapePsSingleQuoted = (value) =>
    String(value || '').replace(/'/g, "''");

// Ejecuta un script de PowerShell y devuelve stdout. Lanza Error con
// stderr/message si exit != 0.
const runPowerShell = (script) => new Promise((resolve, reject) => {
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

// Detecta el proceso (PID + nombre) que está escuchando en LOCAL_PORT.
// Retorna null en plataformas no-Windows o si nadie escucha.
const getLocalApiListener = async () => {
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
};

// Si hay un agente previo escuchando en LOCAL_PORT, intenta detenerlo
// para que la instancia nueva pueda hacer bind. Retorna true si se
// detuvo, false si no había nadie o no se puede detener.
const stopExistingAgentOnLocalPort = async () => {
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
};

module.exports = {
    escapePsSingleQuoted,
    runPowerShell,
    getLocalApiListener,
    stopExistingAgentOnLocalPort,
};
