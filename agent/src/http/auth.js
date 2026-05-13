// PRD 7 Fase 1.2 — Middleware de autenticación JWT (HS256).
// Sprint 6 — Multi-tenant safety: valida membresía contra Supabase
// cuando el JWT no trae business_id en claims (caso típico con JWTs
// nativos de Supabase auth).
//
// Reglas (PRD §6.4 + Sprint 6):
//   RF-14: todos los endpoints excepto /health requieren
//          `Authorization: Bearer <jwt>`.
//   RF-15: validar el JWT contra JWT_SECRET (Supabase HS256).
//   RF-16: el `restaurant_id`/`business_id` debe coincidir con el
//          RESTAURANT_ID del agente. Validación en cascada:
//          1. Si el JWT trae el claim explícito → fast path.
//          2. Sino, buscar `business_members` por `claims.sub` en Supabase
//             (con cache 5min). Si el RESTAURANT_ID está en la lista
//             del usuario → allow. Sino → 403.
//   RF-17: NO almacenamos el JWT — solo se valida en cada request.
//
// Modo legacy/dev: si JWT_SECRET no está configurado, el middleware
// es un no-op y deja pasar todo. Permite rollout gradual.

const jwt = require('jsonwebtoken');
const { logger, JWT_SECRET, RESTAURANT_ID, AUTH_ENABLED } = require('../config');
const membershipCache = require('./membership_cache');

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

const requireAuth = async (req, res, next) => {
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
        // Fast path: el JWT trae el claim directamente (custom JWTs).
        const claimRid = extractRestaurantId(claims);
        if (claimRid && String(claimRid) === String(RESTAURANT_ID)) {
            req.auth = { claims, source: 'claim' };
            return next();
        }

        // Sprint 6 — Slow path con cache: el JWT no trae business_id
        // (caso típico de Supabase auth). Buscamos al usuario en
        // `business_members` y verificamos que RESTAURANT_ID esté
        // entre sus negocios.
        const userId = claims.sub;
        if (userId && membershipCache.isEnabled()) {
            try {
                const decision = await membershipCache.checkUserBusiness(
                    userId,
                    RESTAURANT_ID,
                );
                if (decision.allowed) {
                    req.auth = {
                        claims,
                        source: `membership:${decision.source}:${decision.reason}`,
                    };
                    return next();
                }
                if (decision.reason === 'supabase_unreachable') {
                    logger.warn(
                        `[auth] Supabase no responde para validar membresía de ${req.ip}; ` +
                        'devolviendo 503 para que el cliente reintente',
                    );
                    return res.status(503).json({
                        error: 'membership_check_unavailable',
                        detail: 'Supabase no responde. Reintenta en unos segundos.',
                    });
                }
                logger.warn(
                    `[auth] usuario ${userId.substring(0, 8)}… no pertenece a ` +
                    `restaurant=${RESTAURANT_ID} (reason=${decision.reason})`,
                );
                return res.status(403).json({ error: 'not_a_member' });
            } catch (err) {
                logger.error(`[auth] membership check excepcion: ${err.message}`);
                return res.status(503).json({
                    error: 'membership_check_unavailable',
                    detail: err.message,
                });
            }
        }

        // Sin claim ni cache de membresía disponible: legacy hard-deny.
        logger.warn(
            `[auth] restaurant_id mismatch desde ${req.ip}: token=${claimRid} ` +
            `esperado=${RESTAURANT_ID} (sin Supabase configurado para fallback)`,
        );
        return res.status(403).json({ error: 'restaurant_id_mismatch' });
    }

    req.auth = { claims, source: 'no_restaurant_check' };
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
    if (membershipCache.isEnabled()) {
        logger.info(
            `[auth] JWT enforcement activo (restaurant_id=${RESTAURANT_ID}) ` +
            'con validación de membresía via Supabase (Sprint 6).',
        );
    } else {
        logger.info(
            `[auth] JWT enforcement activo (restaurant_id=${RESTAURANT_ID}) ` +
            '— solo claim, sin lookup a Supabase (SUPABASE_URL/KEY no configurados).',
        );
    }
};

module.exports = { requireAuth, logStartupMode };
