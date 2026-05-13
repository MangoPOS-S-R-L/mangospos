// Sprint 2.1 — mDNS / Bonjour advertiser.
//
// Anuncia este agent en la LAN como `_mangoprint._tcp` para que los
// clientes Flutter lo descubran automáticamente, sin que el cajero
// tenga que configurar IP/puerto manualmente.
//
// Los clientes escanean LAN, leen el TXT record (business_id, agent_uuid,
// version) y se conectan al puerto anunciado.
//
// Si la red del local bloquea multicast (algunos routers corporativos lo
// hacen), el advertiser falla silenciosamente y el cliente sigue
// usando IP manual. Cero impacto.

const { Bonjour } = require('bonjour-service');
const {
    logger,
    LOCAL_PORT,
    AGENT_ID,
    AGENT_NAME,
    AGENT_UUID,
    RESTAURANT_ID,
} = require('../config');

const SERVICE_TYPE = 'mangoprint';
const PROTOCOL = 'tcp';

let bonjour = null;
let advertisement = null;

const start = () => {
    if (advertisement) {
        logger.warn('[mdns] start() llamado pero advertisement ya activo');
        return;
    }

    try {
        bonjour = new Bonjour();

        // TXT records: metadata legible para el cliente Dart al escanear.
        // Mantener todo string (mDNS TXT solo soporta strings).
        const txt = {
            agent_id: AGENT_ID || 'unknown',
            agent_uuid: AGENT_UUID || '',
            business_id: RESTAURANT_ID || '',
            version: '2.0.0',
            platform: process.platform,
            // Marca para que el cliente Dart distinga agents nuevos
            // (con cloud queue support) vs legacy.
            cloud_queue: AGENT_UUID ? 'true' : 'false',
        };

        const name = AGENT_NAME || `MangoPOS Print Hub (${AGENT_ID || 'agent'})`;

        advertisement = bonjour.publish({
            name,
            type: SERVICE_TYPE,
            protocol: PROTOCOL,
            port: LOCAL_PORT,
            txt,
        });

        advertisement.on('up', () => {
            logger.info(
                `[mdns] Anunciado como "${name}" en _${SERVICE_TYPE}._${PROTOCOL}.local:${LOCAL_PORT}`,
            );
        });

        advertisement.on('error', (err) => {
            logger.warn(`[mdns] error: ${err.message}`);
        });
    } catch (err) {
        // mDNS puede fallar si: port multicast bloqueado, OS sin soporte,
        // permiso denegado en algunos OS. No es fatal — el agent sigue
        // funcionando, solo no se auto-descubre. El cliente puede usar
        // IP manual / device_agents.agent_url.
        logger.warn(`[mdns] No se pudo iniciar advertiser: ${err.message}. Continuando sin auto-discovery.`);
        advertisement = null;
        if (bonjour) {
            try { bonjour.destroy(); } catch (_) { /* noop */ }
            bonjour = null;
        }
    }
};

const stop = () => {
    if (advertisement) {
        try {
            advertisement.stop(() => {
                logger.info('[mdns] Advertisement detenido.');
            });
        } catch (err) {
            logger.warn(`[mdns] error al detener: ${err.message}`);
        }
        advertisement = null;
    }
    if (bonjour) {
        try {
            bonjour.destroy();
        } catch (err) {
            logger.warn(`[mdns] error al destruir bonjour: ${err.message}`);
        }
        bonjour = null;
    }
};

module.exports = { start, stop, SERVICE_TYPE, PROTOCOL };
