# AUDIT_DIFF.md

Fecha: 2026-02-25
Fase: B — Auditoría comparativa (sin cambios de código)
Comparativo: `docs` vs `repo Flutter` vs `uso/schema Supabase`
Fuentes de verdad usadas: `AUDIT_REPORT.md`, `BACKEND_REQUIREMENTS.md`, `GAP_ANALYSIS.md`

## 1) Resumen ejecutivo de diferencias

1. La documentación histórica en `/docs` (ej. `PROJECT_STRUCTURE.md`) describe un proyecto React (`src/pages/*.tsx`) y no representa el estado ejecutable actual en Flutter (`lib/presentation/*`).
2. El repo Flutter sí tiene backend real en ventas/cocina/caja parcial, pero conserva módulos enteros vacíos (inventario, compras, promos, reportes backend, etc.), consistente con `AUDIT_REPORT.md` y `GAP_ANALYSIS.md`.
3. El schema de Supabase está más completo que el uso real desde Flutter: existen múltiples tablas/RPCs en DB no consumidas todavía por la app.
4. Hay desajustes de naming/enum entre código Flutter y DB que pueden producir errores funcionales o semánticos.

## 2) Diff docs vs repo vs Supabase usage

| Área | Documentación | Repo Flutter (real) | Supabase (schema/uso) | Diferencia |
|---|---|---|---|---|
| Estructura frontend | `/docs/PROJECT_STRUCTURE.md` reporta rutas React (`src/pages/*.tsx`) | Rutas reales en `lib/app/router/*`, vistas en `lib/presentation/*` | N/A | Documentación legacy no alineada al runtime actual. |
| Ventas core | `GAP_ANALYSIS`: ventas mesas/orden/pago = funcional parcial | `sales_repository.dart` + `sales_queries.dart` activos | RPCs existen (`fn_open_table`, `fn_add_item_from_menu`, `fn_process_payment_v2`) | Alineado en lo principal. |
| Caja cierre | `AUDIT_REPORT`: cierre no usa RPC correctamente | Coexisten `cashier_repository.dart` (con RPC) y `cashier_repository_new.dart` (update directo) | `fn_close_cash_session` existe | Riesgo de comportamiento dual por repos duplicados. |
| Fiscal NCF | `AUDIT_REPORT`: NCF mock hardcodeado | `sales_repository` usa `create_fiscal_document` | `create_fiscal_document` sigue con `'B0200000001'` mock; también existe `generate_ncf` | No alineado con requisito fiscal de producción. |
| Productos | `AUDIT_REPORT`: repo vacío | `products_repository.dart` vacío, pero `products_viewmodel.dart` hace CRUD directo | DB sí tiene `menu_items/categories/menus` | Funciona parcialmente pero fuera de arquitectura objetivo (sin repo). |
| Reportes | `AUDIT_REPORT`: repositorio vacío | `reports_repository.dart` y `reports_queries.dart` vacíos; VM es catálogo estático | DB tiene datos base (`orders/payments/cash_*`) para agregación | Gap funcional confirmado. |
| Inventario | `GAP_ANALYSIS`: P1, sin repo | `inventory/*` vacío | DB tiene `inventory_items`, `inventory_movements`, `consume_inventory_from_order` | Backend existe, frontend no lo consume. |
| Compras/proveedores | `GAP_ANALYSIS`: P2, sin repo | `purchases/*` vacío | DB tiene `suppliers`, `purchase_orders`, `purchase_order_items` | Backend existe, frontend no implementado. |
| Promos/cupones | `GAP_ANALYSIS`: P2/P3, sin repo | `promos/*` vacío | DB tiene `promotions`, `coupons`, `coupon_usage`, `gift_cards` | Backend existe, frontend no implementado. |
| Realtime | Documentación pide más sincronía multi-cajero | Realtime activo en KDS/zonas/algunas vistas | Canales presentes; no hay cobertura transversal (caja/reportes/dashboard) | Cobertura parcial. |

## 3) Mismatches de naming / enums (evidencia y riesgo)

## 3.1 Roles y cocina

- Flutter usa `PosRole.cocina` en `lib/services/session/session_controller.dart`.
- Login mapea `roleStr == 'kitchen'` a `PosRole.cocina` en `lib/presentation/auth/login/login_viewmodel.dart`.
- DB define `user_role` enum con valor `cook` y `user_businesses.role` check con valor `chef` (no `kitchen`, no `cook` en esa tabla).

Impacto:
- Ambigüedad y potencial mapeo incorrecto entre roles de app y roles persistidos.

## 3.2 Modelo dual de roles

- DB tiene `member_role` enum (`owner/admin/manager/staff/viewer`) y `user_role` enum (`admin/manager/cashier/waiter/cook/delivery/owner`).
- Además `user_businesses.role` es `text` con check distinto (`owner/admin/cashier/chef/waiter`).

Impacto:
- Tres taxonomías de rol simultáneas; alto riesgo de autorización inconsistente.

## 3.3 Origen de orden

- DB `order_origin`: `dine_in, manual, quick, delivery, self_service`.
- Comentario en modelo Flutter `TableSession.origin` menciona `quick_sale`.

Impacto:
- Riesgo de filtros/lógica por literal incorrecto (`quick` vs `quick_sale`).

## 3.4 Naming de tablas de menú/impuestos

- Código usa `menu_item_menus` (ej. `products_viewmodel.dart`), pero schema tiene `menu_item_links`.
- Código usa columna `menu_item_id` en `menu_item_taxes`; schema define `item_id`.

Impacto:
- Fallos directos en CRUD de vínculos menú/impuestos según ruta usada.

## 3.5 Categorías

- `BACKEND_REQUIREMENTS.md` menciona `menu_categories` (o similar).
- Schema y código usan `categories`.

Impacto:
- Desalineación documental; no bloquea si se estandariza en documentación técnica.

## 4) Dualidad `memberships` vs `user_businesses` (documentación + plan, sin consolidar aún)

Estado observado:
- `current_user_business_ids()` hace `UNION` de ambas tablas.
- Políticas/funciones RLS mezclan `memberships` y `user_businesses`.
- Flutter consulta principalmente `user_businesses` (login/resolvers) pero también toca `memberships` en registro y settings.

Riesgos:
- Inconsistencia de origen de verdad para autorización.
- Usuarios visibles en una tabla y no en la otra.
- Difícil auditar permisos efectivos por negocio.

Plan propuesto (documental, no ejecutar en esta fase):
1. Definir una tabla `authoritative` para acceso operativo POS (recomendado: `user_businesses` por uso actual en app).
2. Mantener la otra tabla como compatibilidad temporal (`read-only` para app).
3. Publicar matriz de mapeo de roles entre ambas tablas + reglas de precedencia.
4. Migración en dos etapas:
   - Etapa A: escritura dual controlada + vistas de compatibilidad.
   - Etapa B: corte de lecturas a tabla canónica y deprecación de la secundaria.
5. Validar RLS con 3 roles por tabla crítica después del corte.

Nota: no se consolida en esta fase, solo se documenta el camino.

## 5) Diferencias contra BACKEND_REQUIREMENTS (estructura vs uso real)

- Tablas requeridas y existentes en DB pero sin consumo Flutter efectivo hoy: `inventory_*`, `purchase_*`, `promotions/coupons/gift_cards`, `currencies`, `shifts`, varias de fidelidad.
- Operaciones críticas que el documento exige con RPC atómico:
  - Ventas: parcialmente cumplido.
  - Caja cierre: técnicamente disponible en DB, uso inconsistente por repos dual.
  - NCF transaccional: no cumplido por `create_fiscal_document` mock.

## 6) Conclusión de Fase B

- El gap principal no es ausencia total de backend, sino **desalineación entre arquitectura objetivo y consumo real desde Flutter**, más **naming/roles inconsistentes**.
- Antes de Sprint 1 de implementación, se debe fijar:
  1. Canonical naming de roles y tablas puente (`menu_item_links`/`menu_item_taxes.item_id`).
  2. Estrategia oficial de `memberships` vs `user_businesses`.
  3. Ruta única de repositorio por dominio (eliminar dualidades activas por selección, no por borrado aún).

