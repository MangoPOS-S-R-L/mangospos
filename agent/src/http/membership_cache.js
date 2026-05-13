// Sprint 6 — Cache de membresías user_id → business_ids.
//
// Por qué existe:
//   Los JWTs de Supabase NO incluyen business_id en los claims (el
//   usuario puede pertenecer a varios negocios; el JWT solo trae `sub`).
//   El agent recibe el JWT y debe verificar que el usuario realmente
//   pertenezca al business para el que está configurado (RESTAURANT_ID).
//
//   La verificación es una query a `business_members`. Hacer eso en
//   CADA request lo mata: el dashboard de salud refresca cada vez que
//   cambia un job, y un cajero saturado puede tirar 10 requests/seg.
//
// Estrategia:
//   - Cache positivo (5 min): user_id → Set<business_id>. Si llega un
//     request del mismo user_id, miramos el cache antes de Supabase.
//   - Cache negativo (30s): user_id que NO pertenece al RESTAURANT_ID
//     se rechazan rápido sin re-query.
//   - Si Supabase está caído y hay cache POSITIVO (aunque expirado), lo
//     usamos con warning. Mejor que cortar al cajero.
//   - Si no hay cache y Supabase no responde → 503 (no rechazo definitivo,
//     el cliente puede reintentar).

const { createClient } = require('@supabase/supabase-js');
const {
    logger,
    SUPABASE_URL,
    SUPABASE_KEY,
    CLOUD_WORKER_ENABLED,
} = require('../config');

const POSITIVE_TTL_MS = 5 * 60 * 1000;     // 5 min
const NEGATIVE_TTL_MS = 30 * 1000;          // 30 s
const STALE_GRACE_MS = 10 * 60 * 1000;      // 10 min de "supabase caído pero confiamos en cache"

// Map<user_id, { businessIds: Set<string>, cachedAt: number }>
const positive = new Map();
// Map<`${user_id}|${business_id}`, { cachedAt: number }>
const negative = new Map();

let supabaseClient = null;

const getClient = () => {
    if (supabaseClient) return supabaseClient;
    if (!SUPABASE_URL || !SUPABASE_KEY) return null;
    try {
        supabaseClient = createClient(SUPABASE_URL, SUPABASE_KEY, {
            auth: { persistSession: false, autoRefreshToken: false },
        });
        return supabaseClient;
    } catch (err) {
        logger.error(`[membership_cache] init Supabase falló: ${err.message}`);
        return null;
    }
};

const isFreshPositive = (entry) =>
    entry && Date.now() - entry.cachedAt < POSITIVE_TTL_MS;

const isWithinStaleGrace = (entry) =>
    entry && Date.now() - entry.cachedAt < STALE_GRACE_MS;

const isFreshNegative = (entry) =>
    entry && Date.now() - entry.cachedAt < NEGATIVE_TTL_MS;

/**
 * Consulta Supabase: ¿pertenece `userId` al business `businessId`?
 *
 * Probamos primero `business_members` (path principal de la app), y si
 * no devuelve nada usamos `user_businesses` (path legacy de
 * business_resolver). Resilencia para setups mixtos.
 *
 * Retorna Set<string> de business_ids del usuario, o null si Supabase
 * falló. Cachea el resultado positivo si trajo algo.
 */
const fetchBusinessIdsForUser = async (userId) => {
    const client = getClient();
    if (!client) return null;

    try {
        // Path 1: business_members (canónico).
        const { data: members, error: membersErr } = await client
            .from('business_members')
            .select('business_id')
            .eq('user_id', userId);
        if (membersErr) {
            logger.warn(
                `[membership_cache] business_members error: ${membersErr.message}`,
            );
        }
        const ids = new Set();
        if (Array.isArray(members)) {
            for (const row of members) {
                const bid = row?.business_id;
                if (bid) ids.add(String(bid));
            }
        }

        // Path 2: user_businesses (legacy). Solo si business_members
        // vino vacío — algunos setups antiguos solo tienen esta tabla.
        if (ids.size === 0) {
            const { data: legacy, error: legacyErr } = await client
                .from('user_businesses')
                .select('business_id')
                .eq('user_id', userId);
            if (legacyErr) {
                logger.warn(
                    `[membership_cache] user_businesses error: ${legacyErr.message}`,
                );
            }
            if (Array.isArray(legacy)) {
                for (const row of legacy) {
                    const bid = row?.business_id;
                    if (bid) ids.add(String(bid));
                }
            }
        }

        return ids;
    } catch (err) {
        logger.warn(`[membership_cache] fetch excepcion: ${err.message}`);
        return null;
    }
};

/**
 * Decide si `userId` puede operar contra `businessId`. Devuelve un
 * objeto `{ allowed, reason, source }` donde:
 *   - allowed: boolean
 *   - reason: 'fresh' | 'stale_grace' | 'supabase_query' | 'negative_cache' | 'not_member' | 'supabase_unreachable'
 *   - source: 'cache' | 'supabase'
 *
 * No es async-only — usa cache fresco antes de await.
 */
const checkUserBusiness = async (userId, businessId) => {
    if (!userId || !businessId) {
        return { allowed: false, reason: 'missing_params', source: 'none' };
    }
    const negKey = `${userId}|${businessId}`;

    // Cache negativo: usuario ya rechazado recientemente.
    const negEntry = negative.get(negKey);
    if (isFreshNegative(negEntry)) {
        return { allowed: false, reason: 'negative_cache', source: 'cache' };
    }

    // Cache positivo fresco.
    const posEntry = positive.get(userId);
    if (isFreshPositive(posEntry)) {
        const has = posEntry.businessIds.has(String(businessId));
        if (has) {
            return { allowed: true, reason: 'fresh', source: 'cache' };
        }
        // El user existe en cache pero NO incluye este business → no es
        // miembro. Cachear negativo para no insistir.
        negative.set(negKey, { cachedAt: Date.now() });
        return { allowed: false, reason: 'not_member', source: 'cache' };
    }

    // No hay cache fresco → consultar Supabase.
    const ids = await fetchBusinessIdsForUser(userId);
    if (ids === null) {
        // Supabase falló. Si tenemos cache positivo dentro del "stale
        // grace", lo usamos con warning para no cortar al cajero.
        if (isWithinStaleGrace(posEntry)) {
            logger.warn(
                `[membership_cache] Supabase no responde; usando cache stale ` +
                `para user=${userId.substring(0, 8)}…`,
            );
            const has = posEntry.businessIds.has(String(businessId));
            return {
                allowed: has,
                reason: has ? 'stale_grace' : 'stale_grace_not_member',
                source: 'cache',
            };
        }
        return {
            allowed: false,
            reason: 'supabase_unreachable',
            source: 'supabase',
        };
    }

    // Refrescar cache.
    positive.set(userId, { businessIds: ids, cachedAt: Date.now() });
    const has = ids.has(String(businessId));
    if (!has) {
        negative.set(negKey, { cachedAt: Date.now() });
        return { allowed: false, reason: 'not_member', source: 'supabase' };
    }
    return { allowed: true, reason: 'supabase_query', source: 'supabase' };
};

/**
 * Limpieza periódica: borra entradas que están más allá del stale grace
 * (positivas) o que ya vencieron (negativas). Corre cada 5 min.
 */
const cleanup = () => {
    const now = Date.now();
    for (const [userId, entry] of positive.entries()) {
        if (now - entry.cachedAt > STALE_GRACE_MS) {
            positive.delete(userId);
        }
    }
    for (const [key, entry] of negative.entries()) {
        if (now - entry.cachedAt > NEGATIVE_TTL_MS) {
            negative.delete(key);
        }
    }
};

let cleanupTimer = null;

const start = () => {
    if (cleanupTimer) return;
    cleanupTimer = setInterval(cleanup, 5 * 60 * 1000);
    if (cleanupTimer.unref) cleanupTimer.unref();
};

const stop = () => {
    if (cleanupTimer) {
        clearInterval(cleanupTimer);
        cleanupTimer = null;
    }
};

const isEnabled = () => CLOUD_WORKER_ENABLED && !!SUPABASE_URL && !!SUPABASE_KEY;

const stats = () => ({
    positiveSize: positive.size,
    negativeSize: negative.size,
    enabled: isEnabled(),
});

module.exports = {
    start,
    stop,
    checkUserBusiness,
    isEnabled,
    stats,
};
