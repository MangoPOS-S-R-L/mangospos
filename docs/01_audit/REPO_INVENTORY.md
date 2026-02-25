# REPO_INVENTORY.md

Fecha: 2026-02-25
Fase: A — Inventario real del repositorio (sin cambios de código funcional)
Fuente de verdad cruzada: `AUDIT_REPORT.md`, `BACKEND_REQUIREMENTS.md`, `GAP_ANALYSIS.md`

## 1) Mapa módulo -> pantallas -> repos -> queries -> estado

Leyenda estado:
- `real`: conectado a Supabase con persistencia observable.
- `mock`: UI/estado hardcodeado o simulación sin backend real.
- `vacio`: repositorio/query/pantalla sin implementación (0 bytes o ausente).

| Módulo | Pantallas (Flutter) | Repositorios/servicios usados | Queries datasource | Estado | Evidencia breve |
|---|---|---|---|---|---|
| Auth | `login_view`, `register_step1_view`, `register_step2_view` | `auth_remote_ds`, `business_remote_ds` | N/A (queries inline) | real | Usa `profiles`, `user_businesses`, `businesses`, `memberships`. |
| Dashboard | `dashboard_view` | Ninguno | Ninguno | mock | Sin llamadas Supabase en la vista. |
| Sales (core POS) | `sales_by_zone_view`, `manual_sale_view`, `sale_quick_view`, `table_order_screen`, `payment_dialog`, etc. | `sales_repository`, `sales_repository_improved`, `zones_repository` | `sales_queries.dart` (no vacío) | real | RPCs y tablas reales para órdenes/items/pagos/mesas. |
| Cashier | `cashier_view`, `open_close_cash_view`, `cash_closures_view` (`income_expense_view`, `sales_history_view` vacíos) | `cashier_repository`, `sales_repository` (`cashier_repository_new` en payments) | `cashier_queries.dart` | real (parcial) | Flujo apertura/cierre con RPC en repo + consultas directas desde ViewModel. |
| Kitchen/KDS | `kitchen_view`, `kitchen_display_screen` | `kitchen_repository` | `kitchen_queries.dart` | real (parcial) | Usa `kds_active_items`, `order_items`, RPCs cocina + realtime. |
| Customers | `customers_view`, `customer_detail_view` | `customers_repository` | `customers_queries.dart` | real (parcial) | CRUD directo en `customers`; archivo queries está vacío. |
| Products | `products_view` (`products_categories_view` vacío) | Sin `products_repository` (0 bytes); ViewModel consulta Supabase directo | `products_queries.dart` | real (parcial) | CRUD real en `menu_items`/`categories`/`menus`, pero repositorio oficial vacío. |
| Reports | `reports_view` (`sales_report_view` vacío) | `reports_repository` (0 bytes) | `reports_queries.dart` (0 bytes) | mock/vacio | ViewModel de reportes es catálogo estático (sin backend). |
| Inventory | `inventory_outflow_view`, `requirements_view`, `stock_reconciliation_view` | Ninguno | Ninguno | vacio | Módulo completo en 0 bytes. |
| Purchases | `purchases_list_view`, `purchases_register_view` | Ninguno | Ninguno | vacio | Presentación/estado/viewmodel en 0 bytes. |
| Promos | `discounts_view` | Ninguno | Ninguno | vacio | Presentación/estado/viewmodel en 0 bytes. |
| Branches | `restaurant_info_view` | Ninguno | Ninguno | vacio | Carpeta completa en 0 bytes. |
| Printing (top-level) | `printing_plugins_view` | Ninguno en este módulo | Ninguno | vacio | Módulo top-level vacío; la implementación real está en Settings/Printing. |
| Settings (menus/taxes/users/zones/printing) | `settings_view` + submódulos `more settings/*` | `menu_repository`, `menu_item_repository`, `category_repository`, `tax_repository`, `employee_repository`, `permissions_repository`, `zones_repository`, `printing_repository` | N/A (consultas en repos) | real (parcial) | Varias áreas funcionales; otras rutas de settings siguen vacías. |
| Tickets/Billing | `command_config_view`, `prebill_config_view` | Ninguno | Ninguno | vacio | Estado/view/viewmodel en 0 bytes. |
| Split Bill (nuevo UI) | widgets/VM de split | `sales_repository` | Reusa `sales_queries` | real (parcial) | Reusa operaciones de ventas; requiere validación E2E. |

## 2) Archivos 0 bytes

### 2.1 Críticos de app (`lib/`) detectados

- Datasources queries vacíos:
  - `lib/data/datasources/queries/cashier_queries.dart`
  - `lib/data/datasources/queries/customers_queries.dart`
  - `lib/data/datasources/queries/kitchen_queries.dart`
  - `lib/data/datasources/queries/products_queries.dart`
  - `lib/data/datasources/queries/reports_queries.dart`
  - `lib/data/datasources/queries/reservations_queries.dart`
- Repositorios vacíos:
  - `lib/data/repositories/products_repository.dart`
  - `lib/data/repositories/reports_repository.dart`
  - `lib/data/repositories/reservations_repository.dart`
- SQL vacío:
  - `lib/databasecode/ncf_generation.sql`
- Interfaces de dominio vacías:
  - `lib/domain/repositories/i_cashier_repository.dart`
  - `lib/domain/repositories/i_customers_repository.dart`
  - `lib/domain/repositories/i_kitchen_repository.dart`
  - `lib/domain/repositories/i_products_repository.dart`
  - `lib/domain/repositories/i_reports_repository.dart`
  - `lib/domain/repositories/i_reservations_repository.dart`
  - `lib/domain/repositories/i_sales_repository.dart`
- Presentación/estado/viewmodel vacíos (módulos incompletos):
  - `branches/*`
  - `inventory/*`
  - `promos/*`
  - `purchases/*`
  - `printing/*`
  - `tickets_billing/*`
  - partes de `cashier`, `customers`, `products`, `reports`, `sales`, `settings/*`

Resumen: `64` archivos en `lib/` con tamaño 0.

### 2.2 Archivos 0 bytes de dependencias/vendor

- Detectados en `agent/node_modules`, `agent/dist/node_modules`, `agent/MangoPOS-Agent/node_modules`.
- Total vendor 0 bytes: `75`.
- No se consideran bloqueantes funcionales del POS Flutter.

## 3) Llamadas Supabase / RPC por archivo

Formato: `archivo | tablas(.from) | rpc | realtime/channel`

| Archivo | Tablas | RPC | Realtime |
|---|---|---|---|
| `lib/data/repositories/sales_repository.dart` | `orders,order_items,order_checks,table_sessions,dining_tables,zones,payments,payment_methods,cash_transactions,fiscal_documents,v_order_detail` | `get_table_live, fn_mark_order_takeout` + RPCs vía `SalesQueries.*` | - |
| `lib/data/repositories/sales_repository_improved.dart` | `orders,order_items,order_checks,table_sessions,dining_tables,zones,payments,payment_methods,cash_transactions` | RPCs vía `SalesQueries.*` | - |
| `lib/data/datasources/queries/sales_queries.dart` | N/A | `fn_open_table, fn_open_manual_or_quick, fn_add_item_from_menu, fn_update_item_qty, fn_update_item_notes, fn_delete_item, fn_move_item_to_check, fn_toggle_item_takeout, fn_confirm_order_to_kitchen, fn_close_order_and_table, fn_create_split_bill, fn_process_payment_v2, generate_ncf, create_fiscal_document` | - |
| `lib/data/repositories/cashier_repository.dart` | `cash_registers,cash_register_sessions` | `fn_open_cash_session, fn_close_cash_session, fn_get_cash_session_summary` | - |
| `lib/data/repositories/cashier_repository_new.dart` | `payment_methods,cash_register_sessions,cash_transactions` | - | - |
| `lib/data/repositories/kitchen_repository.dart` | `kds_active_items,order_items` | `fn_start_preparing_order, fn_mark_order_ready` | - |
| `lib/data/repositories/customers_repository.dart` | `customers` | - | - |
| `lib/data/repositories/zones_repository.dart` | `zones,dining_tables,v_zone_table_status` | - | `zones:status` |
| `lib/data/repositories/printing_repository.dart` | `printers,print_areas,print_area_printers,print_jobs` | - | - |
| `lib/data/repositories/menu_repository.dart` | `menus,v_menus_with_counts` | - | - |
| `lib/data/repositories/menu_item_repository.dart` | `menu_items,menu_item_links,menu_item_taxes,v_menu_items_list` | - | - |
| `lib/data/repositories/category_repository.dart` | `categories` | - | - |
| `lib/data/repositories/tax_repository.dart` | `taxes` | - | - |
| `lib/data/repositories/employee_repository.dart` | `employees,employee_roles,roles,v_employees_summary` | `create_new_user` | - |
| `lib/data/repositories/permissions_repository.dart` | `permissions,user_permission_overrides` | `fn_user_effective_permissions` | - |
| `lib/data/repositories/menu_lite_repository.dart` | `categories,menus` | - | - |
| `lib/data/repositories/printing_service.dart` | `menu_items,orders` | - | - |
| `lib/data/utils/business_id_resolver.dart` | `memberships,user_businesses,employees` | - | - |
| `lib/core/business/business_resolver.dart` | `user_businesses,memberships,businesses` | - | - |
| `lib/presentation/auth/login/login_viewmodel.dart` | `profiles,user_businesses` | - | - |
| `lib/presentation/auth/register/register_step2_viewmodel.dart` | `businesses,profiles,memberships,user_businesses` | - | - |
| `lib/presentation/products/viewmodel/products_viewmodel.dart` | `user_businesses,menu_items,categories,menus,menu_item_menus,menu_item_taxes` | - | - |
| `lib/presentation/cashier/viewmodel/cashier_viewmodel.dart` | `businesses,payments,cash_transactions,orders,table_sessions,dining_tables` | - | - |
| `lib/presentation/sales/viewmodel/menu_browser_viewmodel.dart` | `categories,menu_items` | - | - |
| `lib/presentation/sales/view/quick_sale_view.dart` | `menu_items` | - | - |
| `lib/presentation/settings/more settings/menus/categories/viewmodel/category_viewmodel.dart` | `user_businesses,memberships,businesses` | - | - |
| `lib/presentation/settings/more settings/menus/menus/viewmodel/menus_viewmodel.dart` | `user_businesses,memberships,businesses` | - | - |
| `lib/presentation/settings/more settings/system settings/zones_tables/viewmodel/zones_tables_viewmodel.dart` | `zones,dining_tables` | - | `rt:settings_tables:$businessId, rt:settings_zones:$businessId` |
| `lib/presentation/settings/more settings/printing/printers/viewmodel/printers_viewmodel.dart` | `discovery_jobs` | - | `realtime:discovery_jobs:${_activeJobId!}, realtime:printers:$b` |
| `lib/presentation/kitchen/viewmodel/kitchen_viewmodel.dart` | - | - | `rt:kitchen_items:$businessId` |
| `lib/presentation/sales/viewmodel/sales_viewmodel.dart` | - | - | `order_view_$orderId` |
| `lib/presentation/sales/viewmodel/sales_by_zone_viewmodel.dart` | - | - | `sales_by_zone_$businessId` |

## 4) Tablas usadas por módulo

| Módulo | Tablas/Vistas observadas |
|---|---|
| Auth | `profiles, user_businesses, businesses, memberships` |
| Sales | `orders, order_items, order_checks, table_sessions, dining_tables, zones, payments, payment_methods, cash_transactions, fiscal_documents, v_order_detail, categories, menu_items` |
| Cashier | `cash_registers, cash_register_sessions, payments, cash_transactions, orders, table_sessions, dining_tables, businesses` |
| Kitchen/KDS | `kds_active_items, order_items` |
| Customers | `customers` |
| Products | `menu_items, categories, menus, menu_item_menus, menu_item_taxes, user_businesses` |
| Settings - Menú | `menus, v_menus_with_counts, menu_items, menu_item_links, menu_item_taxes, v_menu_items_list, categories` |
| Settings - Impuestos | `taxes` |
| Settings - Usuarios/Roles | `employees, employee_roles, roles, v_employees_summary, permissions, user_permission_overrides` |
| Settings - Zonas/Mesas | `zones, dining_tables, v_zone_table_status` |
| Settings - Printing | `printers, print_areas, print_area_printers, print_jobs, discovery_jobs` |
| Reports | Sin tablas consumidas en capa reportes actual (`reports_repository` vacío) |
| Inventory | Sin tablas consumidas (módulo vacío) |
| Purchases | Sin tablas consumidas (módulo vacío) |
| Promos | Sin tablas consumidas (módulo vacío) |
| Branches | Sin tablas consumidas (módulo vacío) |
| Tickets/Billing | Sin tablas consumidas (módulo vacío) |

## 5) Hallazgos de inventario (solo repositorio)

- Existen dualidades funcionales activas: `sales_repository.dart` y `sales_repository_improved.dart`; `cashier_repository.dart` y `cashier_repository_new.dart`.
- El módulo de productos sí tiene backend real, pero está implementado directamente en `products_viewmodel.dart`; `products_repository.dart` está vacío.
- `reports_repository.dart`, `products_queries.dart`, `reports_queries.dart`, `customers_queries.dart`, `cashier_queries.dart`, `kitchen_queries.dart`, `reservations_queries.dart` están vacíos.
- Hay rutas con placeholders para submódulos (`menu/modifier-groups`, `menu/modifiers`, `reservations`) en `app_router.dart`.
- El inventario confirma lo documentado como P0/P1 en `GAP_ANALYSIS.md`: Dashboard/Reportes/Inventario/Promos/Compras no están completos end-to-end.

