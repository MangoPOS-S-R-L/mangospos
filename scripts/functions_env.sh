#!/usr/bin/env bash
# Revisa (y opcionalmente aplica) una variable de entorno nueva del contenedor
# de Edge Functions de PRODUCCION, sin sorpresas.
#
# POR QUE: el contenedor solo toma variables nuevas al RECREARLO, y recrearlo
# aplica TODO lo que hoy diga la config en disco de Coolify, no solo la
# variable nueva. El 2026-08-29 el disco decia ALANUBE_BASE_URL=sandbox con el
# contenedor vivo en produccion: un recreate a ciegas habria mandado la
# facturacion electronica al sandbox en silencio.
#
# Coolify guarda las variables en SU base y solo escribe .env y
# docker-compose.yml al disco cuando reinicia o despliega el servicio; y eso
# reinicia TODO el stack (base incluida) y aplica cualquier otro cambio que
# alguien haya dejado en Coolify. ADD=1 escribe solo esta variable en el
# disco, igual que la tiene Coolify, para no depender de eso.
#
# Este script compara el contenedor VIVO con lo que saldria del disco y solo
# recrea (con APPLY=1) si la UNICA diferencia es la variable esperada. Recrea
# solo edge functions (--no-deps): la base, auth y rest no se tocan.
#
# Uso:
#   ./scripts/functions_env.sh                  # solo lectura
#   ADD=1 ./scripts/functions_env.sh            # pide la llave y la escribe en
#                                               # disco (con respaldo); no reinicia
#   APPLY=1 ./scripts/functions_env.sh          # recrea si es seguro
#   VAR=OTRA_VARIABLE ./scripts/functions_env.sh
#
# Nunca imprime valores de secretos: solo nombres y, de VAR, una huella
# (sha256 recortado) y cuantos bytes tiene. Las de SHOW se ven completas.
# Con ADD=1 la llave se escribe sin eco y viaja por la conexion SSH, no por la
# linea de comandos.

set -euo pipefail

VPS="${VPS:-root@31.97.40.114}"
SERVICE="${SERVICE:-n84o0s8s0w08cko8c48gsog4}"
VAR="${VAR:-ECF_CREDENTIALS_KEY}"
APPLY="${APPLY:-0}"
ADD="${ADD:-0}"
# Variables que no son secretas: se muestran completas.
SHOW="${SHOW:-ALANUBE_BASE_URL ALANUBE_WEBHOOK_URL SUPABASE_URL AZUL_CURRENCY_CODE}"

NEWVAL=""
if [[ "$ADD" == "1" ]]; then
  echo "Pega la llave tal como está en Coolify (desde tu gestor de contraseñas)."
  printf "No se verá al pegarla. Luego Enter: "
  IFS= read -r -s NEWVAL
  echo
  NEWVAL=$(printf '%s' "$NEWVAL" | tr -d '[:space:]')
  if [[ ! "$NEWVAL" =~ ^[A-Za-z0-9+/]+=*$ ]]; then
    echo "ERROR: eso no parece una llave en base64." >&2
    exit 1
  fi
  BYTES=$(printf '%s' "$NEWVAL" | python3 -c 'import base64,sys; print(len(base64.b64decode(sys.stdin.read(), validate=True)))' 2>/dev/null || echo 0)
  if [[ "$VAR" == "ECF_CREDENTIALS_KEY" && "$BYTES" != "32" ]]; then
    echo "ERROR: la llave debe ser de 32 bytes (openssl rand -base64 32); esta tiene $BYTES." >&2
    exit 1
  fi
  echo "Huella de la llave pegada: $(printf '%s' "$NEWVAL" | shasum -a 256 | cut -c1-12)"
fi

echo "VPS: $VPS   servicio: $SERVICE   variable: $VAR"
echo "(te va a pedir la clave SSH una vez)"

# Los parametros van como primeras lineas del script remoto, NO como argumentos
# de ssh: ssh junta los argumentos en un texto y el VPS lo vuelve a partir por
# espacios (SHOW se partia y ADD llegaba como otra cosa). Asi la llave tampoco
# aparece en la linea de comandos de ningun proceso.
{
printf 'NEWVAL=%q\nSERVICE=%q\nVAR=%q\nAPPLY=%q\nSHOW=%q\nADD=%q\n' \
  "$NEWVAL" "$SERVICE" "$VAR" "$APPLY" "$SHOW" "$ADD"
cat <<'REMOTE'
set -euo pipefail
# Todo en main(): bash lee la funcion completa antes de correrla, asi ningun
# comando que lea stdin se come el resto del script que viene por el pipe.
main() {
FUNCS_VOL="/data/coolify/services/$SERVICE/volumes/functions"
command -v python3 >/dev/null || { echo "ERROR: el VPS no tiene python3." >&2; exit 1; }

# El contenedor se busca por el volumen que monta: el VPS tiene un clon del
# stack con contenedores casi iguales.
C=""
for c in $(docker ps --format '{{.Names}}'); do
  if docker inspect -f '{{range .Mounts}}{{.Source}} {{end}}' "$c" 2>/dev/null | grep -q "$FUNCS_VOL"; then
    C="$c"; break
  fi
done
[ -n "$C" ] || { echo "ERROR: ningun contenedor monta $FUNCS_VOL." >&2; exit 1; }

# Proyecto, carpeta y archivos de compose: los que uso Coolify, segun las
# etiquetas del propio contenedor.
label() { docker inspect -f "{{index .Config.Labels \"$1\"}}" "$C"; }
SVC=$(label com.docker.compose.service)
PROJECT=$(label com.docker.compose.project)
WORKDIR=$(label com.docker.compose.project.working_dir)
FILES=$(label com.docker.compose.project.config_files)
COMPOSE=(docker compose -p "$PROJECT" --project-directory "$WORKDIR")
IFS=',' read -r -a FILE_LIST <<< "$FILES"
for f in "${FILE_LIST[@]}"; do COMPOSE+=(-f "$f"); done

echo "Contenedor: $C   (servicio compose: $SVC, proyecto: $PROJECT)"
echo "Config:     $FILES"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

snapshot() {
  docker inspect -f '{{json .Config.Env}}' "$C" > "$TMP/live.json"
  docker image inspect -f '{{json .Config.Env}}' "$(docker inspect -f '{{.Image}}' "$C")" > "$TMP/image.json"
  "${COMPOSE[@]}" config --format json > "$TMP/disk.json" 2> "$TMP/config.err" || {
    echo "ERROR: docker compose config fallo:" >&2; cat "$TMP/config.err" >&2; return 1
  }
}

# Codigos: 0 listo para recrear · 3 falta en disco (lo demas coincide) ·
#          10 ya aplicada · 2 bloqueado
check() {
python3 - "$TMP" "$SVC" "$VAR" "$SHOW" <<'PY'
import base64, hashlib, json, sys

tmp, svc, var, show = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4].split()

def env_list(path):
    out = {}
    for kv in json.load(open(path)) or []:
        k, _, v = kv.partition("=")
        out[k] = v
    return out

live = env_list(f"{tmp}/live.json")
image = env_list(f"{tmp}/image.json")
env = json.load(open(f"{tmp}/disk.json"))["services"][svc].get("environment") or {}
if isinstance(env, list):
    env = dict(e.partition("=")[::2] for e in env)
# `docker compose config` imprime un "$" literal como "$$" (su forma escapada),
# pero el contenedor recibe "$". Sin esto AZUL_CURRENCY_CODE="$" sale siempre
# como diferencia.
disk = {k: "" if v is None else str(v).replace("$$", "$") for k, v in env.items()}

def key_bytes(v):
    try:
        return len(base64.b64decode(v, validate=True))
    except Exception:
        return None

def describe(v):
    if not v:
        return "no está"
    n = key_bytes(v)
    size = f"{n} bytes" if n is not None else "NO es base64"
    return f"sí (huella {hashlib.sha256(v.encode()).hexdigest()[:12]}, {size})"

print("\nValores vivos (no secretos):")
for k in show:
    print(f"  {k} = {live.get(k, '(no está)')}")

print(f"\n{var}")
print(f"  contenedor vivo: {describe(live.get(var))}")
print(f"  config en disco: {describe(disk.get(var))}")

changed = [k for k in sorted(disk) if k != var and live.get(k) != disk[k]]
lost = [k for k in sorted(live) if k != var and k not in disk and image.get(k) != live[k]]

print()
if changed or lost:
    print("OJO: recrear el contenedor cambiaría TAMBIÉN esto (vivo ≠ disco):")
    for k in changed:
        if k in show:
            print(f"  {k}: vivo={live.get(k)!r}  disco={disk[k]!r}")
        else:
            print(f"  {k}  ({'no está en el vivo' if k not in live else 'valor distinto'})")
    for k in lost:
        print(f"  {k}  (está en el vivo y se perdería)")
else:
    print("Fuera de esa variable, el contenedor vivo y el disco coinciden.")

live_v, disk_v = live.get(var), disk.get(var)
if live_v and live_v == disk_v:
    print(f"\nYa aplicada: el contenedor tiene {var}.")
    sys.exit(10)
if live_v and disk_v != live_v:
    print(f"\nPELIGRO: el contenedor ya tiene {var} y el disco tiene OTRO valor (o ninguno).")
    print("Cambiar la llave deja sin descifrar las claves ya guardadas. No se recrea.")
    sys.exit(2)
if changed or lost:
    print("\nNo se recrea: corrige primero esas diferencias en Coolify.")
    sys.exit(2)
if not disk_v:
    print(f"\nTodavía no está en disco.")
    sys.exit(3)
if var == "ECF_CREDENTIALS_KEY" and key_bytes(disk_v) != 32:
    print("\nLa llave en disco no son 32 bytes en base64 (openssl rand -base64 32). No se recrea.")
    sys.exit(2)
sys.exit(0)
PY
}

# Agrega VAR al bloque environment del servicio, con el mismo estilo (lista o
# mapa) y sangria que la primera entrada. Texto, no YAML: no reordena ni
# reescribe nada mas del archivo.
add_compose_line() {
python3 - "$1" "$SVC" "$VAR" <<'PY'
import re, sys

path, svc, var = sys.argv[1:4]
lines = open(path).read().split("\n")

def indent(l):
    return len(l) - len(l.lstrip())

def meaningful(l):
    s = l.strip()
    return s and not s.startswith("#")

svc_re = re.compile(r"^(\s*)['\"]?" + re.escape(svc) + r"['\"]?:\s*$")
start = next((n for n, l in enumerate(lines) if svc_re.match(l)), None)
if start is None:
    sys.exit(f"no encontré el servicio {svc} en {path}")

env_at = None
for n in range(start + 1, len(lines)):
    if not meaningful(lines[n]):
        continue
    if indent(lines[n]) <= indent(lines[start]):
        break
    if re.match(r"^\s*environment:\s*$", lines[n]):
        env_at = n
        break
if env_at is None:
    sys.exit(f"{svc} no tiene un bloque 'environment:' de varias líneas")

first = next((n for n in range(env_at + 1, len(lines)) if meaningful(lines[n])), None)
if first is None or indent(lines[first]) <= indent(lines[env_at]):
    sys.exit(f"el bloque environment de {svc} está vacío")

pad = lines[first][: indent(lines[first])]
ref = "${" + var + "}"
if lines[first].lstrip().startswith("-"):
    new = f"{pad}- '{var}={ref}'"
else:
    new = f"{pad}{var}: '{ref}'"
lines.insert(env_at + 1, new)
open(path, "w").write("\n".join(lines))
print(f"  compose: {new.strip()}")
PY
}

snapshot
set +e; check; RC=$?; set -e

if [ "$RC" -eq 3 ]; then
  if [ "$ADD" != "1" ] || [ -z "$NEWVAL" ]; then
    echo "Coolify la escribe al disco solo al reiniciar el stack completo. Para escribir"
    echo "SOLO esta variable (con respaldo, sin reiniciar nada):"
    echo "  ADD=1 ./scripts/functions_env.sh"
    exit 0
  fi
  COMPOSE_FILE="${FILE_LIST[0]}"
  ENV_FILE="$WORKDIR/.env"
  [ -f "$ENV_FILE" ] || { echo "ERROR: no existe $ENV_FILE" >&2; exit 1; }
  if grep -q "^$VAR=" "$ENV_FILE" || grep -q "$VAR" "$COMPOSE_FILE"; then
    echo "ERROR: $VAR ya aparece en $ENV_FILE o en el compose; revísalo a mano." >&2
    exit 1
  fi
  STAMP=$(date +%Y%m%d-%H%M%S)
  cp -p "$ENV_FILE" "$ENV_FILE.bak-$STAMP"
  cp -p "$COMPOSE_FILE" "$COMPOSE_FILE.bak-$STAMP"
  restore() {
    cp -p "$ENV_FILE.bak-$STAMP" "$ENV_FILE"
    cp -p "$COMPOSE_FILE.bak-$STAMP" "$COMPOSE_FILE"
    echo "Se restauraron .env y docker-compose.yml como estaban. No se cambió nada." >&2
  }
  echo
  echo "Escribiendo $VAR en disco (respaldos *.bak-$STAMP)..."
  [ -z "$(tail -c1 "$ENV_FILE")" ] || echo >> "$ENV_FILE"
  printf '%s=%s\n' "$VAR" "$NEWVAL" >> "$ENV_FILE"
  echo "  .env: $VAR=(oculta)"
  add_compose_line "$COMPOSE_FILE" || { restore; exit 1; }

  snapshot || { restore; exit 1; }
  set +e; check; RC=$?; set -e
  if [ "$RC" -ne 0 ]; then
    echo "ERROR: después de escribirla el chequeo no quedó limpio." >&2
    restore
    exit 1
  fi
fi

[ "$RC" -eq 0 ] || exit 0
if [ "$APPLY" != "1" ]; then
  echo
  echo "Listo para aplicar. Recrea SOLO edge functions (unos segundos sin funciones):"
  echo "  APPLY=1 ./scripts/functions_env.sh"
  exit 0
fi

echo
echo "Recreando solo $SVC..."
"${COMPOSE[@]}" up -d --no-deps --force-recreate "$SVC"
sleep 5
NEW=$("${COMPOSE[@]}" ps -q "$SVC")
if docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$NEW" | grep -q "^$VAR="; then
  echo "OK: el contenedor nuevo tiene $VAR."
else
  echo "ERROR: el contenedor nuevo NO tiene $VAR." >&2
fi
echo
echo "── Últimas líneas del log ──"
docker logs --tail 15 "$NEW" 2>&1 || true
}
main < /dev/null
REMOTE
} | ssh "$VPS" bash -s
