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
#   VPS=root@otra.ip SERVICE=<id> ./scripts/deploy_edge_functions.sh

set -euo pipefail

VPS="${VPS:-root@31.97.40.114}"
SERVICE="${SERVICE:-n84o0s8s0w08cko8c48gsog4}"
REMOTE="/data/coolify/services/${SERVICE}/volumes/functions"
DRY="${DRY:-0}"

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
# SIN --delete a proposito: el volumen del servidor puede tener archivos que
# este repo no conoce (la carpeta salio del repo mangopos-backend y se ha
# tocado a mano). Borrar lo que no vemos es como se rompen las funciones
# vecinas. Los *_test.ts se quedan en casa: el runtime no los usa.
RSYNC_OPTS=(-avz --exclude '*_test.ts' --exclude '.env*' -e "ssh -S $CTRL")

for dir in "_shared" "${FUNCS[@]}"; do
  echo "→ $dir"
  rsync "${RSYNC_OPTS[@]}" "$LOCAL/$dir/" "$VPS:$REMOTE/$dir/"
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
echo "Listo. Verifica que responda:"
echo "  curl -s -X POST https://supabase.mangopos.do/functions/v1/${FUNCS[0]}"
echo
echo "En emit-document la respuesta sana es {\"ok\":true,\"mode\":\"batch\",...}:"
echo "corre la cola de emision, asi que un 200 con ok:true significa que la"
echo "funcion nueva arranco y proceso lo que hubiera pendiente."
