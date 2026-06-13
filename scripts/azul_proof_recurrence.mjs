#!/usr/bin/env node
// azul_proof_recurrence.mjs — Prueba de cobro RECURRENTE (MIT) vía API con un
// token DataVault, para enviar a Azul como evidencia del go-live.
//
// Qué demuestra: que un token DataVault creado por el cliente en la Payment Page
// de Azul (con su verificación 3D Secure al registrar) se puede cobrar después
// server-to-server por el Web Service, SIN volver a pedir 3DS — exactamente
// como correrá la suscripción mes a mes (merchantInitiatedIndicator=STANDING_ORDER,
// ForceNo3DS=1). Es la misma forma que arma `chargeWithToken` en producción.
//
// Corre mTLS DIRECTO (sin el sidecar) para que sea autónomo y fácil de mostrar.
// IMPORTANTE: ejecútalo desde tu Mac / una IP pública que NO sea la del VPS.
// En sandbox Azul bloquea con Incapsula la IP del VPS (31.97.40.114); tu IP
// residencial pasa sin problema (validado 2026-06-09).
//
// Uso:
//   node scripts/azul_proof_recurrence.mjs <DataVaultToken> [montoPesos]
//
//   montoPesos por defecto = 1 (RD$1.00). El monto va en centavos al API.
//
// Variables de entorno (con defaults de PRUEBAS):
//   AZUL_CERT_PATH   default ~/azul-certs/mangopos-azul.crt
//   AZUL_KEY_PATH    default ~/azul-certs/mangopos-azul.key
//   AZUL_API_URL     default https://pruebas.azul.com.do/webservices/JSON/Default.aspx
//   AZUL_MERCHANT_ID default 39038540035   (Store)
//   AZUL_AUTH1       default splitit        (placeholder de pruebas)
//   AZUL_AUTH2       default splitit
//
// Salida: imprime el REQUEST (con el token) y el RESPONSE crudo de Azul. Si
// IsoCode == "00" → APROBADA: copia ambos bloques al correo de Azul.

import fs from 'node:fs';
import https from 'node:https';
import os from 'node:os';
import path from 'node:path';

const HOME = os.homedir();

const CERT_PATH = process.env.AZUL_CERT_PATH || path.join(HOME, 'azul-certs', 'mangopos-azul.crt');
const KEY_PATH = process.env.AZUL_KEY_PATH || path.join(HOME, 'azul-certs', 'mangopos-azul.key');
const API_URL = process.env.AZUL_API_URL || 'https://pruebas.azul.com.do/webservices/JSON/Default.aspx';
const STORE = process.env.AZUL_MERCHANT_ID || '39038540035';
const AUTH1 = process.env.AZUL_AUTH1 || 'splitit';
const AUTH2 = process.env.AZUL_AUTH2 || 'splitit';

const token = process.argv[2];
const montoPesos = process.argv[3] ? Number(process.argv[3]) : 1;

function die(msg) {
  console.error(`\n❌ ${msg}\n`);
  process.exit(1);
}

if (!token || token.length < 8) {
  die(
    'Falta el DataVaultToken.\n' +
      '   Uso: node scripts/azul_proof_recurrence.mjs <DataVaultToken> [montoPesos]\n\n' +
      '   Para sacar el token de una tarjeta registrada en la Payment Page:\n' +
      "     select data_vault_token, brand, last4, status, created_at\n" +
      "       from azul_payment_methods where status='verified' order by created_at desc limit 5;",
  );
}
if (!Number.isFinite(montoPesos) || montoPesos <= 0) die('El monto en pesos debe ser un número > 0.');

let cert, key;
try {
  cert = fs.readFileSync(CERT_PATH);
  key = fs.readFileSync(KEY_PATH);
} catch (e) {
  die(`No pude leer cert/key (${e.message}).\n   AZUL_CERT_PATH=${CERT_PATH}\n   AZUL_KEY_PATH=${KEY_PATH}`);
}

// OrderNumber: Azul valida alfanumérico ≤15 SIN guiones bajos (validado 2026-06-09).
const orderNumber = ('MPREC' + Date.now().toString().slice(-9)).slice(0, 15);

const amountCents = Math.round(montoPesos * 100);

// Mismo body que arma `chargeWithToken` en producción (la recurrencia real).
const requestBody = {
  Channel: 'EC',
  Store: STORE,
  PosInputMode: 'E-Commerce',
  TrxType: 'Sale',
  Amount: String(amountCents),
  Itbis: '000', // sin impuesto separado en la prueba → "000" (Azul rechaza "0")
  CurrencyPosCode: '$',
  OrderNumber: orderNumber,
  DataVaultToken: token,
  AcquirerRefData: '1',
  merchantInitiatedIndicator: 'STANDING_ORDER', // cobro recurrente iniciado por el comercio (MIT)
  ForceNo3DS: '1', // MIT no lleva 3DS: no hay tarjetahabiente presente
};

const u = new URL(API_URL);
// El JSON WS de Azul selecciona la operación con un flag de query SIN valor.
u.search = '?ProcessPayment';
const bodyStr = JSON.stringify(requestBody);

const options = {
  hostname: u.hostname,
  port: u.port || 443,
  path: u.pathname + u.search,
  method: 'POST',
  cert,
  key,
  headers: {
    'Content-Type': 'application/json',
    Accept: 'application/json',
    'Content-Length': Buffer.byteLength(bodyStr),
    Auth1: AUTH1,
    Auth2: AUTH2,
    // UA de browser para no chocar con heurísticas anti-bot de Incapsula.
    'User-Agent':
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36',
  },
};

const line = '─'.repeat(72);
console.log(`\n${line}\nAZUL — PRUEBA DE COBRO RECURRENTE (MIT) CON TOKEN DataVault`);
console.log(line);
console.log(`Endpoint : POST ${u.origin}${u.pathname}${u.search}`);
console.log(`Store    : ${STORE}`);
console.log(`OrderNo  : ${orderNumber}   Monto: RD$${montoPesos.toFixed(2)} (${amountCents} ¢)`);
console.log(`\nREQUEST (ProcessPayment / Sale):`);
console.log(JSON.stringify(requestBody, null, 2));

const t0 = Date.now();
const req = https.request(options, (res) => {
  const chunks = [];
  res.on('data', (c) => chunks.push(c));
  res.on('end', () => {
    const raw = Buffer.concat(chunks).toString('utf8');
    const ms = Date.now() - t0;
    console.log(`\nRESPONSE  (HTTP ${res.statusCode}, ${ms} ms):`);
    let parsed;
    try {
      parsed = JSON.parse(raw);
    } catch {
      console.log(raw.slice(0, 2000));
      die(
        res.statusCode === 403
          ? 'HTTP 403 — Incapsula bloqueó esta IP. Corre el script desde tu Mac / IP residencial, no desde el VPS.'
          : 'Azul devolvió algo que no es JSON (ver arriba).',
      );
    }
    console.log(JSON.stringify(parsed, null, 2));
    console.log(`\n${line}`);
    if (res.statusCode === 200 && parsed.IsoCode === '00') {
      console.log('✅ APROBADA  (IsoCode 00)');
      console.log(`   AuthorizationCode: ${parsed.AuthorizationCode ?? '—'}`);
      console.log(`   AzulOrderId      : ${parsed.AzulOrderId ?? '—'}`);
      console.log(`   RRN              : ${parsed.RRN ?? '—'}`);
      console.log(`\n→ Copia los bloques REQUEST y RESPONSE al correo de Azul como evidencia.`);
    } else {
      console.log(`⚠️  No aprobada. IsoCode=${parsed.IsoCode ?? '—'}  ResponseMessage=${parsed.ResponseMessage ?? '—'}`);
      if (parsed.ErrorDescription) console.log(`   ErrorDescription: ${parsed.ErrorDescription}`);
      if (parsed.IsoCode === '63') {
        console.log('   (63 BIN NOT FOUND: esa BIN no está ruteada para Sale en pruebas — usa otra tarjeta de las #3–#6.)');
      }
    }
    console.log(`${line}\n`);
  });
});

req.on('error', (e) => die(`Error de red/TLS: ${e.message}`));
req.write(bodyStr);
req.end();
