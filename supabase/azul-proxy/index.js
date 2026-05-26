// azul-proxy — sidecar HTTP que traduce llamadas internas a llamadas mTLS contra Azul.
//
// Nace porque Supabase Edge Runtime no expone Deno.createHttpClient ni
// Deno.Command, y restringe lecturas de FS — así que las edge functions no
// pueden hacer mTLS directo. Este sidecar corre Node.js plano y SÍ puede.
//
// Arquitectura:
//   [Edge Function] --POST /call--> [azul-proxy] --mTLS POST--> [Azul]
//                        ^                            ^
//                  x-proxy-auth: TOKEN          cert + key + Auth1/Auth2
//
// Solo escucha en red Docker interna (sin puerto público). El TOKEN compartido
// evita que otros contenedores del mismo Docker net abusen el endpoint.
//
// API:
//   POST /call
//     headers:
//       content-type: application/json
//       x-proxy-auth: <AZUL_PROXY_AUTH_TOKEN>
//     body:
//       { "method": "ProcessPayment"|"ProcessDataVault"|"VerifyPayment", "body": {...} }
//     response 200:
//       { "ok": bool, "httpStatus": number, "durationMs": number, "body": {...} }
//     response 4xx/5xx:
//       { "error": { "code": string, "message": string, "detail"?: any } }
//
//   GET /health  → { "ok": true, "certLoaded": bool, "uptime": number }

const http = require('http');
const https = require('https');
const fs = require('fs');
const url = require('url');
const zlib = require('zlib');

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

const PORT = parseInt(process.env.AZUL_PROXY_PORT || '3000', 10);
const BIND = process.env.AZUL_PROXY_BIND || '0.0.0.0';
const AUTH_TOKEN = required('AZUL_PROXY_AUTH_TOKEN');
const CERT_PATH = required('AZUL_CERT_PATH');
const KEY_PATH = required('AZUL_KEY_PATH');
const AZUL_API_URL = required('AZUL_API_URL');
const AUTH1 = required('AZUL_AUTH1');
const AUTH2 = required('AZUL_AUTH2');
const MAX_BODY_BYTES = 64 * 1024;
const UPSTREAM_TIMEOUT_MS = 30_000;

const ALLOWED_METHODS = new Set([
  'ProcessPayment',
  'ProcessDataVault',
  'VerifyPayment',
]);

function required(name) {
  const v = process.env[name];
  if (!v || v.trim() === '') {
    console.error(`[azul-proxy] FATAL: missing env var ${name}`);
    process.exit(1);
  }
  return v;
}

// ---------------------------------------------------------------------------
// Cargar cert + key una sola vez en startup
// ---------------------------------------------------------------------------

let cert, key, certLoadError;
try {
  cert = fs.readFileSync(CERT_PATH);
  key = fs.readFileSync(KEY_PATH);
  console.log(
    `[azul-proxy] loaded cert (${cert.length} bytes) and key (${key.length} bytes)`,
  );
} catch (e) {
  certLoadError = e;
  console.error(`[azul-proxy] FATAL: failed to read cert/key: ${e.message}`);
  process.exit(1);
}

const azulHost = new url.URL(AZUL_API_URL).hostname;

// Pre-build el agent mTLS — reusa conexiones, evita handshake por call.
const mtlsAgent = new https.Agent({
  cert,
  key,
  keepAlive: true,
  maxSockets: 16,
  // Azul usa cert público válido; no necesitamos rejectUnauthorized:false.
});

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function sendJson(res, status, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(body),
  });
  res.end(body);
}

function sendError(res, status, code, message, detail) {
  sendJson(res, status, { error: { code, message, ...(detail ? { detail } : {}) } });
}

function constantTimeEquals(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string') return false;
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) {
    diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return diff === 0;
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let total = 0;
    req.on('data', (c) => {
      total += c.length;
      if (total > MAX_BODY_BYTES) {
        reject(new Error('Request body too large'));
        req.destroy();
        return;
      }
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

function postToAzul(method, payload) {
  const t0 = Date.now();
  return new Promise((resolve, reject) => {
    const target = new url.URL(`${AZUL_API_URL.replace(/\/$/, '')}?Method=${method}`);
    const bodyStr = JSON.stringify(payload);
    const opts = {
      hostname: target.hostname,
      port: target.port || 443,
      path: target.pathname + target.search,
      method: 'POST',
      agent: mtlsAgent,
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'Accept-Encoding': 'gzip, deflate',
        'Accept-Language': 'en-US,en;q=0.9,es;q=0.8',
        'Content-Length': Buffer.byteLength(bodyStr),
        'Auth1': AUTH1,
        'Auth2': AUTH2,
        // Incapsula (WAF de Azul) hace fingerprinting agresivo. UA de browser
        // real es lo más cercano a "request humana" que podemos enviar; sin
        // esto y sin que Azul whitelistee la IP, devuelve 403 incluso con
        // mTLS válido. El User-Agent NO altera el cert ni el payload — solo
        // sortea heurísticas anti-bot.
        'User-Agent':
          'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36',
      },
      timeout: UPSTREAM_TIMEOUT_MS,
    };

    const upstreamReq = https.request(opts, (upstreamRes) => {
      // Diagnóstico: en cada call mostramos status + headers de respuesta.
      // Útil para ver qué WAF intermedia (Incapsula, Cloudflare, etc).
      console.log(
        `[azul-proxy] ${method} → status=${upstreamRes.statusCode} headers=${JSON.stringify(upstreamRes.headers)}`,
      );
      const encoding = (upstreamRes.headers['content-encoding'] || '').toLowerCase();
      // Si Azul nos devuelve gzip/deflate, lo decodificamos en stream antes de juntar.
      let stream = upstreamRes;
      if (encoding === 'gzip') stream = upstreamRes.pipe(zlib.createGunzip());
      else if (encoding === 'deflate') stream = upstreamRes.pipe(zlib.createInflate());

      const chunks = [];
      stream.on('data', (c) => chunks.push(c));
      stream.on('end', () => {
        const raw = Buffer.concat(chunks).toString('utf8');
        let parsed;
        try {
          parsed = JSON.parse(raw);
        } catch (e) {
          return reject(
            Object.assign(new Error('Azul returned non-JSON'), {
              code: 'azul_non_json',
              httpStatus: upstreamRes.statusCode,
              rawBody: raw.slice(0, 2000),
            }),
          );
        }
        resolve({
          ok: upstreamRes.statusCode === 200 && parsed.IsoCode === '00',
          httpStatus: upstreamRes.statusCode,
          durationMs: Date.now() - t0,
          body: parsed,
        });
      });
      stream.on('error', (e) => {
        reject(
          Object.assign(new Error(`Decode error: ${e.message}`), {
            code: 'decode_error',
            httpStatus: upstreamRes.statusCode,
          }),
        );
      });
    });

    upstreamReq.on('timeout', () => {
      upstreamReq.destroy(new Error(`Upstream timeout after ${UPSTREAM_TIMEOUT_MS}ms`));
    });
    upstreamReq.on('error', (e) => {
      reject(
        Object.assign(new Error(`Network/TLS error: ${e.message}`), {
          code: 'network_error',
          httpStatus: 0,
          cause: e,
        }),
      );
    });

    upstreamReq.write(bodyStr);
    upstreamReq.end();
  });
}

// ---------------------------------------------------------------------------
// Server
// ---------------------------------------------------------------------------

const server = http.createServer(async (req, res) => {
  const parsed = url.parse(req.url, true);
  const path = parsed.pathname;

  // CORS no aplica — solo network interno. Pero respondemos OPTIONS para sanidad.
  if (req.method === 'OPTIONS') {
    res.writeHead(204);
    return res.end();
  }

  if (path === '/health' && req.method === 'GET') {
    return sendJson(res, 200, {
      ok: true,
      certLoaded: !certLoadError,
      uptime: process.uptime(),
      azulHost,
    });
  }

  if (path === '/call' && req.method === 'POST') {
    const provided = req.headers['x-proxy-auth'] || '';
    if (!constantTimeEquals(String(provided), AUTH_TOKEN)) {
      return sendError(res, 401, 'unauthorized', 'Bad x-proxy-auth token');
    }

    let bodyStr;
    try {
      bodyStr = await readBody(req);
    } catch (e) {
      return sendError(res, 413, 'body_too_large', e.message);
    }

    let payload;
    try {
      payload = JSON.parse(bodyStr);
    } catch (e) {
      return sendError(res, 400, 'bad_json', e.message);
    }

    const { method, body } = payload;
    if (!ALLOWED_METHODS.has(method)) {
      return sendError(res, 400, 'bad_method', `Unknown Azul method: ${method}`);
    }
    if (!body || typeof body !== 'object') {
      return sendError(res, 400, 'bad_payload', 'Missing or invalid "body"');
    }

    try {
      const result = await postToAzul(method, body);
      return sendJson(res, 200, result);
    } catch (e) {
      return sendError(res, 502, e.code || 'upstream_error', e.message, {
        httpStatus: e.httpStatus,
        rawBody: e.rawBody,
      });
    }
  }

  return sendError(res, 404, 'not_found', `${req.method} ${path}`);
});

server.listen(PORT, BIND, () => {
  console.log(`[azul-proxy] listening on ${BIND}:${PORT} → ${azulHost} (mTLS)`);
});

// Shutdown limpio en SIGTERM (docker stop)
const shutdown = (sig) => {
  console.log(`[azul-proxy] ${sig} received, closing server...`);
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(1), 10_000).unref();
};
process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
