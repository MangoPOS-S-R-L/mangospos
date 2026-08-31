#!/usr/bin/env bash
# Genera la API key (JWT HS256) de la API de lectura de MangoPOS.
#
# La key es un JWT firmado con el JWT_SECRET del stack de Supabase, con role=analytics_ro.
# PostgREST hace SET LOCAL ROLE analytics_ro al recibirla, y a partir de ahi el unico acceso
# posible es SELECT sobre el esquema analytics, filtrado al negocio de analytics.api_clients.
#
# Uso:
#   export SUPABASE_JWT_SECRET='...'        # env JWT_SECRET del stack (Coolify)
#   ./scripts/mint_analytics_api_key.sh <user_uuid_analitico> [dias_de_vigencia]
#
# Ejemplo:
#   ./scripts/mint_analytics_api_key.sh 11111111-1111-1111-1111-111111111111 365
#
# El JWT_SECRET NUNCA se comparte con el cliente: solo se le entrega el token resultante.

set -euo pipefail

USER_ID="${1:-}"
DAYS="${2:-365}"

if [[ -z "$USER_ID" ]]; then
  echo "Uso: $0 <user_uuid_analitico> [dias_de_vigencia]" >&2
  exit 1
fi

if [[ -z "${SUPABASE_JWT_SECRET:-}" ]]; then
  echo "Falta SUPABASE_JWT_SECRET en el entorno (es el JWT_SECRET del stack de Supabase)." >&2
  exit 1
fi

if ! [[ "$USER_ID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
  echo "El user id no parece un UUID: $USER_ID" >&2
  exit 1
fi

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

IAT=$(date +%s)
EXP=$(( IAT + DAYS * 86400 ))

HEADER='{"alg":"HS256","typ":"JWT"}'
PAYLOAD=$(printf '{"iss":"supabase","role":"analytics_ro","sub":"%s","aud":"authenticated","iat":%s,"exp":%s}' \
  "$USER_ID" "$IAT" "$EXP")

SIGNING_INPUT="$(printf '%s' "$HEADER" | b64url).$(printf '%s' "$PAYLOAD" | b64url)"
SIG=$(printf '%s' "$SIGNING_INPUT" \
  | openssl dgst -sha256 -hmac "$SUPABASE_JWT_SECRET" -binary \
  | b64url)

echo "$SIGNING_INPUT.$SIG"
echo >&2
echo "Vigencia: $DAYS dias (expira $(date -r "$EXP" '+%Y-%m-%d' 2>/dev/null || date -d "@$EXP" '+%Y-%m-%d'))" >&2
echo "Rol: analytics_ro   Usuario: $USER_ID" >&2
