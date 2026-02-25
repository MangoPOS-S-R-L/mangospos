# SMOKE_TESTS.md

Fecha: 2026-02-25
Objetivo: Verificación rápida de flujos críticos antes de liberar

## Matriz de smoke tests (mínimo 10)

| ID | Flujo | Prioridad | Resultado esperado |
|---|---|---|---|
| ST-01 | Login usuario válido con negocio | Crítico | Acceso exitoso al shell |
| ST-02 | Login usuario sin membership/business | Crítico | Bloqueo + error claro |
| ST-03 | Crear producto y recargar app | Crítico | Persistencia confirmada |
| ST-04 | Editar producto + toggle disponibilidad | Alta | Cambios persistentes |
| ST-05 | Crear y buscar cliente | Crítico | Coincidencias correctas |
| ST-06 | Editar/eliminar cliente | Alta | CRUD consistente |
| ST-07 | Procesar pago completo | Crítico | Pago registrado + orden cerrada |
| ST-08 | Emisión fiscal post-pago | Crítico | NCF secuencial, no hardcodeado |
| ST-09 | Cierre de caja | Crítico | Cierre por `fn_close_cash_session` |
| ST-10 | Reporte ventas por rango | Crítico | Totales reales no hardcodeados |
| ST-11 | Reporte resumen caja | Alta | Métricas reales de sesiones/movimientos |
| ST-12 | Reintento operación con error de red | Alta | Mensaje de error útil, sin bloqueo permanente |

## Script operativo sugerido (orden)

1. ST-01
2. ST-02
3. ST-03
4. ST-04
5. ST-05
6. ST-06
7. ST-07
8. ST-08
9. ST-09
10. ST-10
11. ST-11
12. ST-12

## Regla de pase

- Release candidate pasa smoke si `12/12` están OK.
- Si falla cualquier prueba crítica (ST-01,02,03,07,08,09,10), se bloquea despliegue.

## Registro de ejecución

| Fecha | Entorno | Ejecutó | OK | FAIL | Observaciones |
|---|---|---|---|---|---|
| YYYY-MM-DD | staging/prod-pre | nombre | 0 | 0 | completar |

