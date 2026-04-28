# Sales-Module-PRD2 — SQL artifacts

Carpeta dedicada a los archivos SQL del **PRD 2 (Refactor del Motor de Impuestos)**.

> **Regla del proyecto:** todo SQL que se cree para PRD 2 vive acá.
> Para PRDs futuros, usar `Sales-Module-PRD3/`, `Sales-Module-PRD4/`, etc.

---

## Convención de nombres

```
NN_<phase>_<descripcion-corta>.sql
```

Donde:
- `NN` = orden secuencial (`01`, `02`, …) para ejecución determinista.
- `<phase>` = fase del PRD (`f2.2`, `f2.3`, etc.) según [PRD_02_refactor_motor.md §5](../PRD%20Ventas/PRD_02_refactor_motor.md).
- `<descripcion-corta>` = qué hace, en kebab-case.

**Ejemplos:**

| Archivo | Propósito |
|---|---|
| `01_f2.2_create_order_item_tax_lines.sql` | Crear la tabla nueva (PRD §6.1) |
| `02_f2.2_fn_recalc_totals.sql` | Función nueva (PRD §6.2) |
| `03_f2.2_deprecate_calculate_totals.sql` | Wrappers de compat (PRD §6.3) |
| `04_f2.2_trigger_update_order_totals.sql` | Trigger refactor (PRD §6.4) |
| `05_f2.2_fn_compute_item_totals.sql` | Modificación + escritura a tabla nueva (PRD §6.5) |
| `06_f2.2_fn_add_item_from_menu.sql` | Eliminar fallback business_settings (PRD §6.6) |
| `99_f2.2_parity_test.sql` | Test de paridad (PRD §7.2) |

Los archivos `99_*` son scripts de validación (lectura), no de aplicación.

---

## Convenciones de contenido

Cada archivo SQL debe empezar con un **header estandarizado**:

```sql
-- =============================================================================
-- File:        NN_<phase>_<name>.sql
-- PRD:         2 (Refactor del Motor de Impuestos)
-- Phase:       F2.X
-- Author:      Cristian
-- Date:        YYYY-MM-DD
-- Reversible:  yes/no
-- Rollback:    <ruta del archivo de rollback, o "destructive — ver PRD §9">
--
-- Purpose:
--   <1-3 líneas explicando qué hace y por qué>
--
-- Apply order:
--   1. Staging primero. Validar con script `99_*_parity_test.sql`.
--   2. Producción sólo si staging dio paridad 100% por 24h.
-- =============================================================================
```

---

## Directorio de rollbacks

Los scripts inversos viven en `rollback/` con el mismo prefijo numérico:

```
Sales-Module-PRD2/
├── 01_f2.2_create_order_item_tax_lines.sql
├── 02_f2.2_fn_recalc_totals.sql
├── ...
└── rollback/
    ├── 01_drop_order_item_tax_lines.sql
    ├── 02_restore_calculate_order_totals.sql
    └── ...
```

Para funciones modificadas (`fn_compute_item_totals`, `fn_add_item_from_menu`, etc.), el rollback es restaurar la versión vigente al momento del deploy. **Antes de aplicar cualquier `CREATE OR REPLACE`, exportar la versión actual y guardarla en `rollback/`.**

---

## Estado actual

| Fase | Estado |
|---|---|
| F2.1 Diseño y validación | **EN CURSO** — ver `f2.1_design_notes.md` |
| F2.2 Backend: tabla nueva + consolidación | Pendiente |
| F2.3 Frontend: motor unificado | Pendiente |
| F2.4 Integración y QA | Pendiente |
| F2.5 Deploy a producción | Pendiente |
