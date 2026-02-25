# SPRINTS.md

Fecha: 2026-02-25
Estado: Plan de ejecución por sprints (sin implementación)

## Sprint 1 — Bloqueantes P0 (Producción mínima)

Objetivo: eliminar riesgos críticos de seguridad/fiscal y habilitar operación mínima real.

1. Seguridad login
   - remover fallback `PosRole.administrador` sin membership/business;
   - bloquear con error explícito y acción de soporte.
2. Fiscal NCF
   - quitar uso efectivo de NCF hardcodeado;
   - emisión transaccional con secuencia real.
3. Productos mínimo viable
   - implementar `products_repository` + `products_queries`;
   - CRUD real `menu_items/categories/modificadores` mínimo;
   - toggle disponibilidad.
4. Reportes mínimo viable
   - `reports_repository` + queries:
     - ventas por rango (`orders/payments/order_items`);
     - resumen caja (`cash_register_sessions/cash_transactions`).
5. Clientes mínimo viable
   - `customers_queries` + repository + CRUD + búsqueda.
6. Caja cierre
   - cierre por `fn_close_cash_session` obligatorio;
   - diferencia correcta y mensajes de validación.

Criterio de cierre Sprint 1:
- 0 P0 abiertos;
- smoke tests P0 aprobados;
- sin fallback inseguro ni NCF hardcodeado activo.

## Sprint 2 — P1 (Operación diaria completa)

Objetivo: reemplazar hardcode operativo y cerrar circuito inventario/impuestos/realtime.

1. Dashboard real
   - reemplazar hardcode por vistas/RPC de agregación.
2. Inventario MV
   - insumos (`inventory_items`), kardex (`inventory_movements`), salidas/mermas;
   - consumo automático al pagar (hook en pago/trigger).
3. Realtime mesas
   - suscripción `dining_tables` y `table_sessions` multi-cajero.
4. Impuestos dinámicos
   - CRUD `taxes` + aplicación real en ventas.

Criterio de cierre Sprint 2:
- dashboard y reportes sin data ficticia;
- inventario se mueve automáticamente en ventas pagadas;
- sincronía básica multi-caja funcional.

## Sprint 3 — P2 (Módulos empresariales)

Objetivo: ampliar cobertura operativa empresarial.

1. Compras/proveedores
   - `suppliers`, `purchase_orders`, entrada a inventario.
2. Impresoras
   - CRUD impresoras, asignación categorías/áreas, cola de jobs mínima.
3. Promos/cupones
   - promociones/cupones aplicados a orden sin evadir impuestos.
4. Multi-sucursal (si aplica)
   - `branch_id`/filtros en queries críticas.

Criterio de cierre Sprint 3:
- flujo compras->inventario operativo;
- impresión y promos funcionales en flujo real.

## Sprint 4 — Hardening & Deploy

Objetivo: endurecer seguridad/performance y dejar release-ready.

1. Auditoría RLS total.
2. Performance
   - índices faltantes + revisión de queries pesadas.
3. Seguridad RPC
   - revisión de `SECURITY DEFINER` con validación ownership.
4. Release readiness
   - checklist deploy + rollback + backups.

Criterio de cierre Sprint 4:
- checklist de despliegue completo;
- rollback probado en staging;
- smoke tests críticos aprobados.

## Backlog transversal (todos los sprints)

1. No romper ventas/KDS/caja parcial existentes.
2. Todo cambio DB con migration versionada.
3. Documentar pruebas manuales por historia crítica.
4. Mantener trazabilidad `requisito -> evidencia -> prueba`.

## Gate obligatorio antes de implementar cualquier módulo con DB

Si el módulo requiere cambio en Supabase:
1. crear `SUPABASE_CHANGE_SPEC.md`;
2. crear SQL versionado en `/supabase/migrations/`;
3. esperar confirmación antes de implementar.

