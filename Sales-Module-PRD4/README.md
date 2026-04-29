# Sales-Module-PRD4 — Artefactos del PRD 4

Carpeta dedicada a los artefactos de trabajo del **PRD 4 (Unificación de Modos de Venta)**.

PRD 4 es **mayoritariamente frontend Dart** (no toca SQL del backend), así que esta carpeta tiene principalmente:

- Documentos de diseño (`f4.X_*.md`)
- Scripts de validación SQL (si hace falta hacer queries de diagnóstico contra producción)
- NO hay migraciones de schema ni cambios de RPCs (eso fue scope del PRD 2)

> Para SQL operacional ver `Sales-Module-PRD2/` (motor) y `Sales-Module-PRD3/` (cleanup) cuando se inicie.

---

## Inventario esperado al cierre del PRD

| Archivo | Propósito | Fase |
|---|---|---|
| `README.md` | Este documento | — |
| `f4.1_gap_analysis.md` | Mapa de features en zone vs manual vs quick | F4.1 |
| `f4.2_design_notes.md` | Decisión de arquitectura unificada | F4.2 |
| `f4.6_smoke_test_checklist.md` | Lista de validación pre-deploy | F4.6 |
| `audit/` | Queries SQL de diagnóstico si hace falta | — |

---

## Convención

Los documentos siguen el patrón del PRD 2: header con metadata + secciones numeradas. El idioma es español.

Cualquier query SQL ejecutada para diagnosticar problemas durante PRD 4 se guarda en `audit/` con el formato `NN_descripcion.sql`.
