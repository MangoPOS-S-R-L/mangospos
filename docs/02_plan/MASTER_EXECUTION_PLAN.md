# MASTER_EXECUTION_PLAN.md

Fecha: 2026-02-25
Estado: Plan maestro (Fase C, sin implementación)
Base: `AUDIT_REPORT.md`, `BACKEND_REQUIREMENTS.md`, `GAP_ANALYSIS.md`, `docs/01_audit/*`

## 1. Objetivo

Convertir MangoPOS en sistema full-stack productivo (Flutter + Supabase), sin mocks operativos, con seguridad RLS, operaciones atómicas por RPC y validación manual E2E documentada.

## 2. Reglas de gobernanza (gates)

1. No se avanza a Sprint 2 hasta cerrar Sprint 1 al 100%.
2. No se marca módulo DONE sin backend real + pruebas manuales + seguridad.
3. Cualquier cambio de DB requiere:
   - `SUPABASE_CHANGE_SPEC.md`
   - SQL versionado en `/supabase/migrations/`
   - aprobación antes de implementar módulo dependiente.
4. Prohibido introducir fallback inseguro de rol admin o datos fiscales hardcodeados.

## 3. Priorización P0 / P1 / P2

## P0 (bloqueantes de producción)

- Seguridad de acceso: remover `Admin fallback` en login si no hay membership/business.
- Fiscal: eliminar NCF hardcodeado (`create_fiscal_document` mock), usar `ncf_sequences` transaccional.
- Productos: backend consistente en repositorio + queries + CRUD real + disponibilidad.
- Reportes mínimo viable: ventas por rango + resumen de caja real.
- Clientes mínimo viable: CRUD + búsqueda real.
- Caja: cierre mediante `fn_close_cash_session` con cálculo de diferencia correcto.

## P1 (operación diaria completa)

- Dashboard real sin hardcode.
- Inventario mínimo viable (insumos, kardex, mermas/salidas, consumo automático al pago).
- Realtime mesas/sesiones multi-cajero.
- Impuestos dinámicos (CRUD + aplicación efectiva en venta).

## P2 (madurez empresarial)

- Compras/proveedores.
- Impresoras (CRUD + asignaciones + cola de jobs mínima).
- Promos/cupones.
- Multi-sucursal (`branch_id`/filtros).

## 4. Dependencias entre módulos

1. Auth/Seguridad -> habilita todo módulo con scoping por negocio.
2. Fiscal/NCF -> depende de pagos atómicos y ownership de negocio en RPC.
3. Sales/Cashier -> base de reportes y dashboard.
4. Productos + Impuestos -> dependen de catálogo consistente y reglas fiscales.
5. Inventario -> depende de eventos de pago/orden confirmada.
6. Dashboard/Reportes -> dependen de ventas/caja/inventario confiables.
7. Compras/Promos/Multi-sucursal -> dependen de RLS y modelo de negocio consolidado.

## 5. Qué tocar en DB vs Flutter (por dominio)

| Dominio | DB (Supabase) | Flutter |
|---|---|---|
| Auth/Roles | Normalizar lectura de membresía, políticas RLS y ownership en RPC SECURITY DEFINER | `login_viewmodel`, resolvers de business/role, estados de error explícitos |
| Fiscal | Ajustar RPC/función de emisión NCF para secuencia real; eliminar mock | flujo de pago/factura en `sales_repository` y UI de recibo |
| Caja | Forzar uso de `fn_close_cash_session`; índices y validaciones de sesión activa | `cashier_repository(_new)`, viewmodels de caja/pagos |
| Productos | Validar tablas puente (`menu_item_links`, `menu_item_taxes`) + políticas e índices | crear `products_repository` y migrar lógica desde `products_viewmodel` |
| Clientes | `customers` (RLS/indexes/search) | `customers_queries`, `customers_repository`, VM/UI CRUD |
| Reportes | vistas/RPC agregadas para ventas/caja | `reports_queries`, `reports_repository`, VM/UI reportes |
| Inventario | movimientos, triggers/consumo automático, índices kardex | repos/queries/VM inventario |
| Dashboard | vistas/RPC KPI | reemplazo de hardcode en dashboard |
| Impuestos | RLS + aplicación en totales de orden/pago | settings taxes + integración en cálculo ventas |
| Realtime mesas | canales y políticas para `dining_tables/table_sessions` | suscripciones en ventas/caja |
| Compras/Promos | tablas ya existentes + políticas/índices faltantes | nuevos repos/queries/UI |

## 6. Riesgos y mitigaciones

| Riesgo | Nivel | Mitigación |
|---|---|---|
| Dualidad `memberships` vs `user_businesses` | Alto | Definir tabla canónica para runtime POS y mantener compat temporal documentada |
| Repositorios duplicados (`sales`, `cashier`) | Alto | seleccionar implementación oficial por dominio y deprecar rutas alternas |
| Mismatch de naming (`menu_item_menus` vs `menu_item_links`) | Alto | normalizar capa de datos y mapear nombres en un único repositorio |
| RPC SECURITY DEFINER sin validación estricta | Crítico | auditoría de ownership `auth.uid()` + `business_id` por función |
| NCF mock en flujo real | Crítico | reemplazo por secuencia transaccional con tests manuales fiscales |
| Módulos vacíos en UI productiva | Alto | gating estricto por DoD y smoke tests por sprint |

## 7. Definition of Done (aplicable por módulo)

Un módulo solo es DONE si cumple TODO:

1. Backend
   - tablas/columnas existen o migración incluida;
   - RLS activo probado con 3 roles;
   - índices de queries críticas aplicados;
   - RPC atómico para operación crítica;
   - triggers/funciones aplicables validados.
2. Frontend
   - repositorio implementado (no vacío);
   - queries implementadas (no vacías);
   - estados MVVM/Riverpod correctos;
   - loading/error/empty states;
   - validación UI mínima + server-side.
3. Pruebas
   - pasos manuales documentados;
   - smoke tests definidos para flujos críticos.
4. Observabilidad y seguridad
   - sin `catch` vacío;
   - errores útiles;
   - sin fallback inseguro;
   - sin acceso cross-business.
5. Resultado
   - persistencia verificada tras reinicio de app.

## 8. Criterios de salida de Fase C

- `MASTER_EXECUTION_PLAN.md` aprobado.
- `SPRINTS.md` aprobado con backlog y dependencias.
- Para iniciar implementación: preparar `SUPABASE_CHANGE_SPEC.md` + migration SQL por cada módulo que toque DB.

