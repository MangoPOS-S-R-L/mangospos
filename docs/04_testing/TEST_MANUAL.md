# TEST_MANUAL.md

Fecha: 2026-02-25
Ámbito: Validación manual Sprint 1 (P0)
Entorno objetivo: Staging/producción controlada con Supabase aplicado

## 1. Objetivo

Validar de extremo a extremo que los bloqueantes P0 quedaron resueltos con backend real, persistencia, seguridad y manejo de errores.

## 2. Precondiciones

1. Migración Supabase aplicada: `20260225_0001_sprint1_p0_fiscal_roles.sql`.
2. Usuario de prueba con `user_businesses` válido y rol permitido.
3. Usuario de prueba sin `user_businesses` (caso negativo login).
4. Datos mínimos:
   - 1 negocio activo
   - 1 caja registradora activa
   - métodos de pago (`cash`, `card`, `transfer`)
   - categorías/menús base
5. App compilada desde commit actual con cambios Sprint 1.

## 3. Casos de prueba manual (detallados)

## Caso 01 — Login bloquea usuario sin membresía

Pasos:
1. Iniciar sesión con usuario sin fila válida en `user_businesses`.
2. Observar resultado en pantalla.

Resultado esperado:
- Login rechazado.
- Mensaje claro: usuario sin negocio/rol asignado.
- No se mantiene sesión activa.

## Caso 02 — Login exitoso con role mapping válido

Pasos:
1. Iniciar sesión con usuario `role = admin|manager|cashier|waiter|cook|chef|delivery`.
2. Verificar acceso al shell principal.

Resultado esperado:
- Login exitoso.
- `activeRole` asignado correctamente en app.
- `businessId` no nulo en sesión.

## Caso 03 — Crear producto (persistencia real)

Pasos:
1. Ir a Productos.
2. Crear producto con nombre, precio, categoría y menú.
3. Refrescar vista y reiniciar app.

Resultado esperado:
- Producto persiste en `menu_items`.
- Vínculo de menú persiste en `menu_item_links`.
- Producto visible al reabrir app.

## Caso 04 — Editar producto (incluye vínculos)

Pasos:
1. Editar producto existente.
2. Cambiar precio/categoría/menú e impuestos.
3. Guardar y refrescar.

Resultado esperado:
- Cambios persistidos en `menu_items`.
- Vínculos actualizados en `menu_item_links` y `menu_item_taxes`.

## Caso 05 — Toggle disponibilidad de producto

Pasos:
1. Desde la tabla de productos, alternar disponibilidad.
2. Refrescar lista.

Resultado esperado:
- `menu_items.is_active` cambia en DB.
- Estado visual coincide tras refresh.

## Caso 06 — CRUD clientes + búsqueda

Pasos:
1. Crear cliente con nombre/teléfono/email.
2. Editar datos.
3. Buscar por nombre, luego por teléfono/email/rnc.
4. Eliminar cliente.

Resultado esperado:
- Operaciones persisten en `customers`.
- Búsqueda devuelve coincidencias por múltiples campos.
- Eliminación efectiva.

## Caso 07 — Reporte ventas por rango real

Pasos:
1. Registrar pagos en rango temporal actual.
2. Abrir Reportes > Ventas.
3. Ver total y cantidad de transacciones/items.

Resultado esperado:
- Totales reflejan datos reales de `payments` + `order_items`.
- No aparecen valores hardcodeados fijos.

## Caso 08 — Reporte resumen de caja real

Pasos:
1. Abrir/cerrar sesiones de caja y crear movimientos manuales.
2. Abrir Reportes > Finanzas.

Resultado esperado:
- Métricas basadas en `cash_register_sessions` y `cash_transactions`.
- Totales de entradas/salidas coherentes.

## Caso 09 — Cierre de caja usa RPC atómico

Pasos:
1. Abrir sesión de caja.
2. Cerrar sesión desde flujo de pagos/caja.
3. Revisar DB/logs.

Resultado esperado:
- Se invoca `fn_close_cash_session`.
- No hay `update` directo de cierre con `difference = endAmount - 0`.

## Caso 10 — Emisión fiscal sin NCF hardcodeado

Pasos:
1. Procesar pago y consultar `fiscal_documents` de la orden.
2. Repetir con otra orden.

Resultado esperado:
- `ncf_number` no es fijo (`B0200000001`).
- NCF secuencial por configuración activa.
- Negocio correcto en documento fiscal.

## Caso 11 — Idempotencia de emisión fiscal

Pasos:
1. Reintentar emisión fiscal para misma orden/pago.

Resultado esperado:
- Retorna documento existente o no duplica emisión.

## Caso 12 — Revisión de errores útiles (sin catch silencioso en flujos P0)

Pasos:
1. Forzar error de red al guardar producto/reportes/clientes.
2. Forzar credenciales inválidas en login.

Resultado esperado:
- Mensajes comprensibles para usuario.
- Sin fallos silenciosos en flujos P0 cubiertos.

## 4. Evidencia requerida por ejecución

Para cada caso:
1. Fecha/hora
2. Usuario/rol
3. Resultado (OK/FAIL)
4. Captura o log
5. ID de registros DB (cuando aplique)

## 5. Criterio de aceptación Sprint 1

Sprint 1 se considera cerrado solo si:
1. Casos 01-12 en estado OK.
2. Sin fallback admin.
3. Sin NCF hardcodeado activo.
4. Cierre de caja confirmado vía RPC.
5. Reportes y CRUD P0 con datos reales persistentes.

