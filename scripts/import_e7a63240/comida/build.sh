#!/bin/bash
# Arma los 3 .sql a partir de las plantillas y de _productos.sql (la lista).
set -eu
cd "$(dirname "$0")"
build() {
  awk -v f=_productos.sql '
    /^--@@PRODUCTOS@@$/ { while ((getline l < f) > 0) print l; close(f); next }
    { print }' "$1" > "$2"
}
build _tpl_diagnostico.sql 00_diagnostico_comida.sql
build _tpl_import.sql      IMPORT_COMIDA.sql
build _tpl_rollback.sql    99_rollback_comida.sql
echo "ok: $(grep -c "^  ('" _productos.sql) productos"
