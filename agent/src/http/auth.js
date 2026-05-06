// PRD 7 Fase 1.2 — Middleware de autenticación JWT (HS256).
//
// Reglas (PRD §6.4):
//   RF-14: todos los endpoints excepto /health requieren
//          `Authorization: Bearer <jwt>`.
//   RF-15: validar el JWT contra JWT_SECRET (Supabase HS256).
//   RF-16: el claim `restaurant_id`/`business_id` del JWT debe coincidir
//          con el RESTAURANT_ID configurado, o 403.
//   RF-17: NO almacenamos el JWT — solo se valida en cada request.
//
// Modo legacy/dev: si JWT_SECRET no está configurado, el middleware
// es un no-op y deja pasar todo. Permite rollout gradual sin romper
// despliegues actuales.

const jwt = require('jsonwebtoken');
const { logger, JWT_SECRET, RESTAURANT_ID, AUTH_ENABLED } = require('../config');

const extractRestaurantId = (claims) => {
    if (!claims || typeof claims !== 'object') return null;
    return (
        claims.restaurant_id ||
        claims.business_id ||
        claims.app_metadata?.restaurant_id ||
        claims.app_metadata?.business_id ||
        claims.user_metadata?.restaurant_id ||
        claims.user_metadata?.business_id ||
        null
    );
};

const requireAuth = (req, res, next) => {
    if (!AUTH_ENABLED) return next();

    const header = req.headers.authorization || '';
    const match = header.match(/^Bearer\s+(.+)$/i);
    if (!match) {
        return res.status(401).json({ error: 'missing_bearer_token' });
    }

    const token = match[1].trim();
    let claims;
    try {
        claims = jwt.verify(token, JWT_SECRET, { algorithms: ['HS256'] });
    } catch (err) {
        logger.warn(`[auth] JWT inválido desde ${req.ip}: ${err.message}`);
        return res.status(401).json({ error: 'invalid_token', detail: err.message });
    }

    if (RESTAURANT_ID) {
        const claimRid = extractRestaurantId(claims);
        if (!claimRid || String(claimRid) !== String(RESTAURANT_ID)) {
            logger.warn(
                `[auth] restaurant_id mismatch desde ${req.ip}: token=${claimRid} esperado=${RESTAURANT_ID}`,
            );
            return res.status(403).json({ error: 'restaurant_id_mismatch' });
        }
    }

    req.auth = { claims };
    next();
};

const logStartupMode = () => {
    if (!AUTH_ENABLED) {
        logger.warn(
            '[auth] JWT_SECRET no configurado — el agente acepta requests sin auth (modo legacy/dev). ' +
            'Para activar Fase 1.2: setear JWT_SECRET y RESTAURANT_ID en .env.',
        );
        return;
    }
    if (!RESTAURANT_ID) {
        logger.warn(
            '[auth] JWT_SECRET configurado pero RESTAURANT_ID no — se valida la firma pero NO el tenant. ' +
            'Recomendado: setear RESTAURANT_ID para enforce RF-16.',
        );
        return;
    }
    logger.info(`[auth] JWT enforcement activo (restaurant_id=${RESTAURANT_ID})`);
};

module.exports = { requireAuth, logStartupMode };
