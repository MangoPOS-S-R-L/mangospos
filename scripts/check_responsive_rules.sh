#!/usr/bin/env bash
# PRD 6 — Responsive lint rules (script, no analyzer plugin para mantener simple).
#
# Falla si encuentra:
# 1. MediaQuery.physicalSize (anula DPI scaling de Windows)
# 2. window.physicalSize / view.physicalSize
# 3. textScaleFactor: 1.0 hardcodeado (bloquea accesibilidad)
# 4. TextScaler.linear(1.0) hardcodeado (lo mismo)
#
# Excepciones permitidas marcadas con `// ignore: prd6_responsive`.
#
# Uso:
#   bash scripts/check_responsive_rules.sh
# Exit 0 = OK; Exit 1 = violations encontradas.

set -euo pipefail

cd "$(dirname "$0")/.."

violations=0

scan() {
  local pattern="$1"
  local desc="$2"
  # -P perl regex; -n line numbers; -r recursive; --include solo dart;
  # excluir tests y generated/freezed/g.dart.
  local hits
  hits=$(grep -P -n -r --include='*.dart' \
    --exclude-dir='.dart_tool' \
    --exclude='*.g.dart' \
    --exclude='*.freezed.dart' \
    --exclude='*.gr.dart' \
    -e "$pattern" lib/ 2>/dev/null || true)

  # Filtrar líneas con escape comment.
  hits=$(echo "$hits" | grep -v 'ignore: prd6_responsive' || true)

  if [ -n "$hits" ]; then
    echo "❌ $desc"
    echo "$hits" | sed 's/^/   /'
    echo
    violations=$((violations + 1))
  fi
}

scan 'MediaQuery\s*\.\s*of\s*\([^)]*\)\s*\.\s*physicalSize' \
  'MediaQuery.of(...).physicalSize prohibido — usar MediaQuery.sizeOf(...)'

scan '(MediaQuery|window|view)\s*\.\s*physicalSize' \
  'physicalSize prohibido — anula DPI scaling de Windows. Usar MediaQuery.sizeOf'

scan 'textScaleFactor\s*:\s*1\.0' \
  'textScaleFactor: 1.0 hardcodeado prohibido — bloquea accesibilidad'

scan 'TextScaler\s*\.\s*linear\s*\(\s*1\.0\s*\)' \
  'TextScaler.linear(1.0) hardcodeado prohibido — bloquea accesibilidad'

if [ "$violations" -eq 0 ]; then
  echo "✅ PRD 6 responsive rules: 0 violations."
  exit 0
else
  echo "PRD 6 responsive rules: $violations categoría(s) con violations."
  echo "Si la violación es intencional, agrega: // ignore: prd6_responsive"
  exit 1
fi
