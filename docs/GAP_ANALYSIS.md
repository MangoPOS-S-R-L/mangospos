# GAP_ANALYSIS.md — Análisis de Brechas
> Generado: 2026-02-24 | MangoPOS Flutter + Supabase

| Módulo | Estado Actual | Backend Necesario | Prioridad | Complejidad |
|--------|--------------|-------------------|-----------|-------------|
| **Autenticación** | ⚠️ Funcional con vulnerabilidad de fallback rol | Lógica de roles robusta; validar `user_businesses` | P0 | Baja |
| **Ventas — Mesas** | ✅ Real (RPC Supabase) | — | — | — |
| **Ventas — Carrito / Orden** | ✅ Real (`fn_add_item_from_menu`) | — | — | — |
| **Ventas — Pago** | ✅ Real (sin atomicidad total) | Rollback transaccional completo | P1 | Media |
| **Ventas — Envío a cocina** | ✅ Real | — | — | — |
| **Ventas — Split bill** | ✅ Real | — | — | — |
| **Ventas — Delivery** | ❌ Solo UI | Repositorio + RPC delivery; asignación repartidor | P2 | Alta |
| **Ventas — Self Service** | ❌ Solo UI | Repositorio + QR code flow | P3 | Alta |
| **Caja — Apertura/Cierre** | ⚠️ Parcial (diferencia incorrecta) | Llamar RPC `fn_close_cash_session` correctamente | P1 | Baja |
| **Caja — Movimientos manuales** | ✅ Real | — | — | — |
| **KDS / Cocina** | ✅ Funcional | Verificar `fn_start_preparing_order` en schema | P1 | Baja |
| **Productos — CRUD** | ❌ Repositorio vacío (0 bytes) | CRUD en `menu_items`, categorías, modificadores | P0 | Media |
| **Productos — Disponibilidad** | ❌ Sin repositorio | Toggle `is_available` en `menu_items` | P0 | Baja |
| **Productos — Modificadores** | ❌ Sin implementación | CRUD `modifier_groups` + `modifiers` | P1 | Media |
| **Productos — Combos** | ❌ Sin implementación | Tabla `combos` + relaciones | P2 | Media |
| **Productos — Menú config** | ❌ Sin implementación | `menus`, `menu_schedules`, items → menús | P2 | Media |
| **Dashboard — Stats reales** | ❌ Hardcodeado | Vistas agregadas `orders`, `payments` | P1 | Alta |
| **Reportes — Ventas** | ❌ Repositorio vacío | Queries sobre `orders`, `payments`, `order_items` | P1 | Alta |
| **Reportes — Compras** | ❌ Repositorio vacío | Queries sobre `purchases`, `purchase_items` | P2 | Media |
| **Reportes — Inventario** | ❌ Repositorio vacío | Queries `inventory_movements`, `inventory_items` | P2 | Alta |
| **Reportes — Finanzas** | ❌ Repositorio vacío | Queries multi-tabla cruzadas | P2 | Alta |
| **Inventario — Kardex** | ❌ Sin repositorio | `inventory_movements` + `inventory_items` | P1 | Alta |
| **Inventario — Salidas** | ❌ Sin repositorio | INSERT `inventory_movements` (waste/sale) | P1 | Media |
| **Inventario — Transferencias** | ❌ Sin repositorio | `inventory_movements` (transfer_in/transfer_out) | P2 | Media |
| **Inventario — Cuadre stock** | ❌ Sin repositorio | `inventory_movements` (adjustment) | P2 | Alta |
| **Inventario — Mermas** | ❌ Sin repositorio | `inventory_movements` (waste) | P2 | Media |
| **Inventario — Recetas** | ❌ Sin repositorio | `recipes`, `recipe_ingredients` | P2 | Alta |
| **Inventario — Insumos** | ❌ Sin repositorio | `inventory_items`, `warehouses` | P1 | Media |
| **Clientes — Lista/CRUD** | ❌ Queries vacías | SELECT/INSERT/UPDATE/DELETE en `customers` | P1 | Media |
| **Clientes — Historial** | ❌ Sin implementación | `orders` filtradas por `customer_id` | P2 | Media |
| **Compras — Proveedores** | ❌ Sin repositorio | CRUD en `suppliers` | P2 | Baja |
| **Compras — Órdenes** | ❌ Sin repositorio | `purchase_orders`, `purchase_order_items` | P2 | Media |
| **Compras — Registro** | ❌ Sin repositorio | `purchases`, actualizar `inventory_items` | P2 | Alta |
| **Compras — Crédito proveedores** | ❌ Sin repositorio | `supplier_credits`, cuentas por pagar | P3 | Media |
| **Usuarios — Lista/Creación** | ⚠️ Solo UI | `user_businesses` + Supabase Auth invite | P1 | Alta |
| **Usuarios — Roles granulares** | ⚠️ Básico (role string) | Permisos granulares en `memberships` | P2 | Alta |
| **Sucursales** | ❌ Sin repositorio | CRUD en `warehouses`/branches + filtro en queries | P2 | Muy Alta |
| **Cajas — Config** | ⚠️ Parcial | CRUD en `cash_registers` | P1 | Baja |
| **Impresoras — Config** | ⚠️ Servicios existen | CRUD en `printers`, `printer_categories` | P1 | Alta |
| **Impresoras — Comandas/Recibos** | ⚠️ Integración incompleta | Generación ESC/POS + jobs queue | P1 | Alta |
| **Fiscal — NCF** | ❌ MOCK hardcodeado (`B0200000001`) | Lógica real `ncf_sequences`, secuencias DGII | P0 | Muy Alta |
| **Fiscal — e-CF** | ❌ No implementado | API DGII electronic CF | P3 | Muy Alta |
| **Fidelidad — Puntos/Membresías** | ❌ Sin repositorio | `loyalty_points`, `membership_levels` | P3 | Alta |
| **Promos — Descuentos/Cupones** | ❌ Sin repositorio | `promotions`, `coupons`, aplicación en orden | P2 | Alta |
| **Promos — Gift Cards** | ❌ Sin repositorio | `gift_cards`, consumo parcial | P3 | Alta |
| **Venta a Crédito** | ❌ Sin repositorio | `customer_credits`, `credit_sales` | P2 | Alta |
| **Turnos RRHH** | ❌ Sin repositorio | `shifts`, `employee_schedules` | P3 | Media |
| **Monedas / Regionales** | ❌ Sin repositorio | `currencies`, `exchange_rates`, settings | P3 | Media |
| **Impuestos — Config dinámica** | ❌ Sin repositorio | CRUD `taxes`, aplicación dinámica en ventas | P1 | Media |
| **Monitor Ventas (real-time)** | ❌ Sin repositorio | Supabase Realtime stream en `orders` | P2 | Media |
| **Tiempo real — Mesas** | ❌ Sin suscripción | Supabase Realtime en `dining_tables` | P1 | Media |
| **Tiempo real — Caja** | ❌ Sin suscripción | Supabase Realtime en `payments` | P2 | Media |
| **Multi-sucursal** | ❌ Sin filtro en ningún módulo | `branch_id` en todas las queries del sistema | P2 | Muy Alta |
| **Offline Mode** | ❌ Sin implementación | SQLite local + sync estrategia | P2 | Muy Alta |
| **KPI / Indicadores** | ❌ Sin repositorio | Vistas materializadas o RPCs de agregación | P3 | Alta |

---

## LEYENDA

| Símbolo | Significado |
|---------|-------------|
| ✅ | Completamente funcional con Supabase |
| ⚠️ | Parcialmente funcional — tiene bugs o lagunas |
| ❌ | Sin backend real — vacío o hardcodeado |

| Prioridad | Significado |
|-----------|-------------|
| P0 | Bloqueante — impide operación en producción |
| P1 | Alta — primera iteración de producción |
| P2 | Media — sprint 2-3 |
| P3 | Baja — sprint 4+ |

| Complejidad | Días estimados |
|-------------|----------------|
| Baja | 1-3 días |
| Media | 3-7 días |
| Alta | 1-2 semanas |
| Muy Alta | 2+ semanas o integración externa |
