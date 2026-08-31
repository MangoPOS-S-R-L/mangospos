#!/usr/bin/env bash
# Genera la API key de lectura DENTRO del VPS.
#
# El host corre mas de un stack de Supabase (produccion y un clon), asi que NO se puede
# tomar "el primer contenedor de postgrest que aparezca": el secreto del clon produce un
# token con firma invalida (JWSInvalidSignature).
#
# Solucion: la clave anon de produccion es publica y esta firmada con el JWT_SECRET de
# produccion. Se prueba el secreto de cada contenedor contra ella y se usa el que valida.
#
# Uso:  ./mint_analytics_api_key_vps.sh <user_uuid> [dias]

set -euo pipefail

USER_ID="${1:-}"
DAYS="${2:-365}"
[[ -z "$USER_ID" ]] && { echo "Uso: $0 <user_uuid> [dias]" >&2; exit 1; }

# Clave anon de produccion (publica, viaja dentro de la app). Es la piedra de toque.
ANON_H='eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9'
ANON_P='eyJpc3MiOiJzdXBhYmFzZSIsImlhdCI6MTc3MjgzOTUwMCwiZXhwIjo0OTI4NTEzMTAwLCJyb2xlIjoiYW5vbiJ9'
ANON_S='LHw1pkCZ3DySAmly08hFoykgbG0CCC7k7Igh2izbCAg'

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
firma()  { printf '%s.%s' "$1" "$2" | openssl dgst -sha256 -hmac "$3" -binary | b64url; }

SECRET=""
echo "Buscando el contenedor cuyo secreto firma la clave anon de produccion..." >&2

while read -r cid nombre; do
  [[ -z "$cid" ]] && continue
  s=$(docker exec "$cid" printenv PGRST_JWT_SECRET 2>/dev/null || true)
  [[ -z "$s" ]] && s=$(docker exec "$cid" printenv JWT_SECRET 2>/dev/null || true)
  [[ -z "$s" ]] && { printf '  %-45s sin secreto\n' "$nombre" >&2; continue; }

  if [[ "$(firma "$ANON_H" "$ANON_P" "$s")" == "$ANON_S" ]]; then
    printf '  %-45s COINCIDE  <-- produccion\n' "$nombre" >&2
    SECRET="$s"
  else
    printf '  %-45s no coincide (otro stack)\n' "$nombre" >&2
  fi
done < <(docker ps --format '{{.ID}} {{.Names}}' \
         | while read -r id name; do
             img=$(docker inspect -f '{{.Config.Image}}' "$id" 2>/dev/null || echo '')
             case "$img$name" in *[Pp]ostg[Rr][Ee][Ss][Tt]*|*rest*) echo "$id $name";; esac
           done)

if [[ -z "$SECRET" ]]; then
  echo >&2
  echo "Ningun contenedor firmo la clave anon. Manda la salida de:" >&2
  echo "  docker ps --format '{{.Names}}  {{.Image}}'" >&2
  exit 1
fi

IAT=$(date +%s); EXP=$(( IAT + DAYS * 86400 ))
H=$(printf '%s' '{"alg":"HS256","typ":"JWT"}' | b64url)
P=$(printf '{"iss":"supabase","role":"analytics_ro","sub":"%s","aud":"authenticated","iat":%s,"exp":%s}' \
      "$USER_ID" "$IAT" "$EXP" | b64url)
S=$(firma "$H" "$P" "$SECRET")

echo >&2; echo "=== API KEY ===" >&2
echo "$H.$P.$S"
echo >&2
echo "Rol: analytics_ro   Usuario: $USER_ID" >&2
echo "Expira: $(date -d "@$EXP" '+%Y-%m-%d' 2>/dev/null || date -r "$EXP" '+%Y-%m-%d')" >&2
