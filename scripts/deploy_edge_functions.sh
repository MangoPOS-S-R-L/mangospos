#!/usr/bin/env bash
# Despliega Edge Functions al Supabase self-hosted de Coolify.
#
# POR QUE UN SCRIPT Y NO UN SCP A MANO:
#   1. El host corre MAS DE UN STACK de Supabase (produccion y un clon). Copiar
#      al volumen equivocado deja el codigo viejo corriendo en produccion y a
#      uno buscando el bug donde no esta. El script identifica el contenedor
#      POR EL VOLUMEN que monta, no por el nombre.
#   2. `_shared/` viaja siempre: emit-document no arranca sin el, y olvidarlo
#      deja el contenedor sirviendo una version a medias.
#   3. Una sola conexion SSH (ControlMaster) = una sola vez la clave, aunque
#      sean varios rsync y un restart.
#
# NO usa `supabase functions deploy`: eso es para Supabase Cloud. En este setup
# el edge-runtime sirve archivos de un volumen montado (ver
# mangopos-backend/docs/spikes/D-1-edge-functions-validation.md).
#
# Uso:
#   ./scripts/deploy_edge_functions.sh                    # emit-document + _shared
#   ./scripts/deploy_edge_functions.sh emit-document alanube-webhook
#   DRY=1 ./scripts/deploy_edge_functions.sh              # muestra que haria
#   CHECK=1 ./scripts/deploy_edge_functions.sh ...        # lista que archivos difieren
#                                                         # del VPS (checksum), sin copiar
#                                                         # ni reiniciar
#   SKIP_SHARED="azul-api.ts" ./scripts/deploy_edge_functions.sh ...
#                                                         # deja esos archivos de _shared
#                                                         # como estan en el VPS
#   VPS=root@otra.ip SERVICE=<id> ./scripts/deploy_edge_functions.sh
#
# ANTES DE DESPLEGAR, CHECK=1: `_shared` viaja completo, y si el VPS tiene un
# archivo mas nuevo que el repo (alguien desplego sin commitear) se pisa en
# silencio. Lo que salga en la lista y no sea tuyo va en SKIP_SHARED.

set -euo pipefail

VPS="${VPS:-root@31.97.40.114}"
SERVICE="${SERVICE:-n84o0s8s0w08cko8c48gsog4}"
REMOTE="/data/coolify/services/${SERVICE}/volumes/functions"
DRY="${DRY:-0}"
CHECK="${CHECK:-0}"
# Nombres de archivo dentro de _shared, separados por espacio.
SKIP_SHARED="${SKIP_SHARED:-}"

# _shared no se lista: va siempre, porque todo lo demas depende de el.
FUNCS=("$@")
[[ ${#FUNCS[@]} -eq 0 ]] && FUNCS=("emit-document")

cd "$(dirname "$0")/.."
LOCAL="supabase/functions"

for f in "${FUNCS[@]}"; do
  [[ -d "$LOCAL/$f" ]] || { echo "ERROR: no existe $LOCAL/$f" >&2; exit 1; }
done

echo "VPS:      $VPS"
echo "Destino:  $REMOTE"
echo "Funciones: _shared ${FUNCS[*]}"
[[ -n "$SKIP_SHARED" ]] && echo "Sin tocar en _shared: $SKIP_SHARED"
echo

if [[ "$DRY" == "1" ]]; then
  echo "(DRY=1) No se copia nada."
  exit 0
fi

# ── Conexion unica ────────────────────────────────────────────────────────
CTRL="/tmp/mangopos-deploy-$$.sock"
cleanup() { ssh -S "$CTRL" -O exit "$VPS" 2>/dev/null || true; }
trap cleanup EXIT

echo "Abriendo conexion SSH (te va a pedir la clave una sola vez)..."
ssh -M -S "$CTRL" -o ControlPersist=10m -fN "$VPS"
SSH=(ssh -S "$CTRL" "$VPS")

# ── El volumen tiene que existir: si no, el SERVICE esta mal ──────────────
"${SSH[@]}" "test -d '$REMOTE'" || {
  echo "ERROR: $REMOTE no existe en el VPS." >&2
  echo "Revisa el id del servicio con:" >&2
  echo "  ssh $VPS \"docker ps --format '{{.Names}}' | grep -i edge\"" >&2
  exit 1
}

# SIN --delete a proposito: el volumen del servidor puede tener archivos que
# este repo no conoce (la carpeta salio del repo mangopos-backend y se ha
# tocado a mano). Borrar lo que no vemos es como se rompen las funciones
# vecinas. Los *_test.ts se quedan en casa: el runtime no los usa.
RSYNC_OPTS=(-avz --exclude '*_test.ts' --exclude '.env*' -e "ssh -S $CTRL")

# Opciones por carpeta en OPTS: SKIP_SHARED solo aplica a _shared. Sin
# mapfile a proposito: el bash de macOS es 3.2.
set_opts_for() {
  OPTS=("${RSYNC_OPTS[@]}")
  if [[ "$1" == "_shared" ]]; then
    for skip in $SKIP_SHARED; do OPTS+=(--exclude "/$skip"); done
  fi
}

# ── Solo revisar ──────────────────────────────────────────────────────────
if [[ "$CHECK" == "1" ]]; then
  echo "(CHECK=1) Archivos que se copiarian (por checksum). No se toca nada."
  for dir in "_shared" "${FUNCS[@]}"; do
    echo "→ $dir"
    set_opts_for "$dir"
    rsync "${OPTS[@]}" -n --checksum "$LOCAL/$dir/" "$VPS:$REMOTE/$dir/" \
      | grep -vE '^(sending|sent |total size|Transfer starting|building file list|$)' || true
  done
  exit 0
fi

# ── Que contenedor sirve ESE volumen (asi se distingue del clon) ──────────
echo "Buscando el contenedor que monta ese volumen..."
CONTAINER=$("${SSH[@]}" bash -s <<REMOTE_EOF
for c in \$(docker ps --format '{{.Names}}'); do
  if docker inspect -f '{{range .Mounts}}{{.Source}} {{end}}' "\$c" 2>/dev/null | grep -q '$REMOTE'; then
    echo "\$c"
  fi
done
REMOTE_EOF
)
CONTAINER=$(echo "$CONTAINER" | head -1)

if [[ -z "$CONTAINER" ]]; then
  echo "ERROR: ningun contenedor monta $REMOTE. ¿Stack apagado o id equivocado?" >&2
  exit 1
fi
echo "Contenedor: $CONTAINER"
echo

# ── Respaldo antes de tocar nada ──────────────────────────────────────────
# El rollback tiene que ser una sola linea, no una arqueologia de git a las
# 11 de la noche con el negocio facturando.
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP="/tmp/functions-backup-${STAMP}.tgz"
echo "Respaldando lo que hay hoy en $BACKUP ..."
"${SSH[@]}" "cd '$REMOTE' && tar czf '$BACKUP' _shared ${FUNCS[*]} 2>/dev/null" || true
echo "Rollback: ssh $VPS \"cd $REMOTE && tar xzf $BACKUP && docker restart $CONTAINER\""
echo

# ── Copia ─────────────────────────────────────────────────────────────────
for dir in "_shared" "${FUNCS[@]}"; do
  echo "→ $dir"
  set_opts_for "$dir"
  rsync "${OPTS[@]}" "$LOCAL/$dir/" "$VPS:$REMOTE/$dir/"
done

# ── Reinicio + verificacion ───────────────────────────────────────────────
echo
echo "Reiniciando $CONTAINER..."
"${SSH[@]}" "docker restart '$CONTAINER'" >/dev/null
sleep 4

echo
echo "── Ultimas lineas del log ──"
"${SSH[@]}" "docker logs --tail 25 '$CONTAINER' 2>&1" || true

echo
echo "Listo. El reinicio sano se ve arriba como 'shutdown signal received: 15'"
echo "seguido de 'main function started'."
echo
echo "NO llames emit-document para verificar: CUALQUIER peticion (GET incluido)"
echo "corre la cola y manda comprobantes reales a la DGII. El 2026-09-17 eso"
echo "envio dos facturas ANULADAS que quedaron aceptadas."
echo
echo "Para ver que el codigo nuevo carga, llama sin token a una funcion que corte"
echo "en la autenticacion (responde 401 'Falta el Bearer token', no ejecuta nada):"
echo "  curl -s -X POST -H 'Content-Type: application/json' -d '{}' \\"
echo "    https://supabase.mangopos.do/functions/v1/provision-ecf"
echo "Y para emit-document, mira el log en la proxima venta electronica:"
echo "  ssh $VPS \"docker logs --since 15m $CONTAINER 2>&1 | grep -i 'boot error\\|emit'\""
