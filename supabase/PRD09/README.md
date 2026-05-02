# PRD 9 — Módulo de Inventario · Migraciones SQL

Esta carpeta agrupa los archivos SQL del PRD 9 ([../../PRD%20Ventas/PRD_09_modulo_inventario.md](../../PRD%20Ventas/PRD_09_modulo_inventario.md)) por fase. **No están auto-aplicados** — viven aquí para revisión y se mueven a `supabase/migrations/` con el formato `YYYYMMDD_NNNN_prd9_fX_*.sql` cuando se aprueban.

## Orden de aplicación

| # | Archivo | Fase PRD | Estado |
|---|---|---|---|
| 1 | `001_phase0_schema.sql` | Fase 0 — Schema completo | Listo para revisión |
| 2 | `002_phase2_receive_goods.sql` | Fase 2 — RPC `receive_goods` + capas | Pendiente |
| 3 | `003_phase3_costed_consumption.sql` | Fase 3 — Costeo en venta | Pendiente |
| 4 | `004_phase4_transfers.sql` | Fase 4 — `transfer_send/receive` | Pendiente |
| 5 | `005_phase5_adjustments.sql` | Fase 5 — `adjust_inventory` | Pendiente |
| ... | (Fases 6-9 cuando lleguen) | | |

## Reglas

1. Cada archivo es **idempotente** (`if not exists`, `or replace`, `if not exists` en policies).
2. `ALTER TYPE ADD VALUE` va **fuera del `begin/commit`** porque no se puede usar en la misma transacción.
3. Cada archivo debe poder aplicarse en una BD que ya tiene los anteriores aplicados sin error.
4. Antes de mover a `supabase/migrations/`: probar contra una BD sandbox restaurada de prod.

## Cómo aplicar manualmente (sandbox)

```bash
psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f supabase/PRD09/001_phase0_schema.sql
```

Para auto-aplicar vía Supabase CLI: copiarlo a `supabase/migrations/YYYYMMDD_NNNN_prd9_f0_inventory_schema.sql` con el timestamp del momento del release.
