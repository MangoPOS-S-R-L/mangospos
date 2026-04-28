# Snapshots — estado actual de Supabase pre PRD 2

> Capturas read-only del estado de producción **antes** de aplicar cambios del PRD 2.
> Sirven como rollback si algún `CREATE OR REPLACE` posterior rompe algo.

## Cómo se generaron

Ejecutando los 11 bloques numerados de [`00_capture_current_state.sql`](./00_capture_current_state.sql) en Supabase **producción**, y pegando cada output en su archivo correspondiente acá.

## Inventario

| Archivo | Origen | Cuándo se usa |
|---|---|---|
| `01_fn_compute_item_totals.sql` | `pg_get_functiondef('fn_compute_item_totals')` | Si se rompe la modificación del PRD §6.5 |
| `02_fn_add_item_from_menu.sql` | `pg_get_functiondef('fn_add_item_from_menu')` | Si se rompe la modificación del PRD §6.6 |
| `03_calculate_order_totals.sql` | `pg_get_functiondef('calculate_order_totals')` | Si se rompe el wrapper del PRD §6.3 |
| `04_calculate_check_totals.sql` | `pg_get_functiondef('calculate_check_totals')` | Si se rompe el wrapper del PRD §6.3 |
| `05_trigger_update_order_totals.sql` | `pg_get_functiondef('trigger_update_order_totals')` | Si se rompe la modificación del PRD §6.4 |
| `06_all_triggers_on_order_items_and_orders.txt` | Dump de `pg_trigger` JOIN `pg_class` | Referencia |
| `07_taxes_table_columns.txt` | `information_schema.columns` | Sanity check del schema |
| `08_business_settings_columns.txt` | `information_schema.columns` | Sanity check del schema |
| `09_order_items_columns.txt` | `information_schema.columns` | Sanity check del schema |
| `10_orders_and_checks_columns.txt` | `information_schema.columns` | Sanity check del schema |
| `11_menu_item_taxes_columns.txt` | `information_schema.columns` | Sanity check del schema |

## Regla

**No se aplica ningún cambio del PRD 2 a Supabase hasta que estos 11 archivos existan acá y estén commiteados.**
