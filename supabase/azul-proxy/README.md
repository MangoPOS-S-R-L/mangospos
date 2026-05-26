# azul-proxy

Sidecar HTTP que les permite a las Edge Functions de Supabase hacer llamadas
mTLS contra el API de Azul.

## ¿Por qué existe?

Supabase Edge Runtime (versión 1.67.4 verificada en producción):

- **No expone `Deno.createHttpClient`** → no se puede pasar `{ cert, key }` a `fetch`.
- **Bloquea `Deno.Command`** → no se puede ejecutar `curl` como subprocess.
- **Restringe `Deno.readTextFile`** a paths internos del runtime → no podemos
  leer el cert ni la key montados en `/home/deno/functions/azul-certs/`.

Resultado: no hay forma directa de hacer mTLS desde una Edge Function. Este
sidecar es un proceso Node.js plano que SÍ puede, y vive en el mismo Docker
network que las Edge Functions, así que estas le hablan por HTTP interno.

## Arquitectura

```
[Flutter app]
    ↓ HTTPS + Bearer/apikey
[Supabase Kong gateway]
    ↓
[Edge Function: azul-tokenize-card | azul-charge | etc.]
    ↓ HTTP interno + x-proxy-auth header
[azul-proxy:3000]  ← este sidecar
    ↓ HTTPS + mTLS + Auth1/Auth2
[pruebas.azul.com.do]
```

## API

### `POST /call`

Headers:
- `Content-Type: application/json`
- `x-proxy-auth: <AZUL_PROXY_AUTH_TOKEN>`  (secret compartido con el caller)

Body:
```json
{
  "method": "ProcessPayment" | "ProcessDataVault" | "VerifyPayment",
  "body": { "Channel": "EC", "Store": "...", ... }
}
```

Respuesta `200`:
```json
{
  "ok": true,
  "httpStatus": 200,
  "durationMs": 412,
  "body": { "IsoCode": "00", "AzulOrderId": "...", ... }
}
```

Respuesta `4xx/5xx`:
```json
{ "error": { "code": "unauthorized" | "bad_method" | "upstream_error" | ..., "message": "..." } }
```

### `GET /health`

Respuesta:
```json
{ "ok": true, "certLoaded": true, "uptime": 1234.5, "azulHost": "pruebas.azul.com.do" }
```

Usado por el healthcheck de Docker.

## Variables de entorno

| Var | Requerido | Descripción |
| --- | --- | --- |
| `AZUL_PROXY_AUTH_TOKEN` | sí | Secret de auth entre edge function ↔ sidecar |
| `AZUL_API_URL`          | sí | `https://pruebas.azul.com.do/webservices/JSON/Default.aspx` |
| `AZUL_AUTH1`            | sí | Header `Auth1` de Azul (en pruebas: `splitit`) |
| `AZUL_AUTH2`            | sí | Header `Auth2` de Azul (en pruebas: `splitit`) |
| `AZUL_CERT_PATH`        | sí | Path al cert firmado por BPD-SCA (ej. `/certs/mangopos-azul.crt`) |
| `AZUL_KEY_PATH`         | sí | Path a la private key (ej. `/certs/mangopos-azul.key`) |
| `AZUL_PROXY_PORT`       | no | Puerto, default `3000` |
| `AZUL_PROXY_BIND`       | no | Bind address, default `0.0.0.0` |

## Seguridad

- **NO exponer públicamente.** En el docker-compose, no agregar `ports:`.
  Solo accesible desde otros containers en la misma red Docker.
- El TOKEN compartido es defensa en profundidad: si otro container hostil
  apareciera en la red, no puede llamarnos.
- Comparación constant-time del token (anti timing-attack).
- Body máximo: 64 KB (rechaza payloads abusivos).
- Timeout upstream: 30 s.
- Corre como usuario `node` (no root).
- El cert y la key llegan vía bind-mount read-only — nunca quedan en la imagen.

## Deploy

Se monta como service `azul-proxy` en el `docker-compose.yml` del stack de
Supabase. Ver `DEPLOY.md` (raíz de `supabase/`) para los detalles del compose.
