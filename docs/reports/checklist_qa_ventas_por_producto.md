# Checklist QA — Ventas por producto

> Guardrail de aceptación para el reporte faltante **Ventas por producto**.
> Objetivo: aprobar solo si el reporte es auditable, claro, responsivo y visualmente consistente con MangoPOS.

## 1. Filtros requeridos

- [ ] Tiene **rango de fecha** visible arriba y coincide con la consulta real.
- [ ] Tiene presets útiles: **Hoy / Ayer / Esta semana / Este mes / Personalizado**.
- [ ] Tiene botón o acción clara de **Limpiar filtros**.
- [ ] Permite filtrar por **producto**.
- [ ] Permite filtrar por **categoría**.
- [ ] Permite filtrar por **empleado**.
- [ ] Permite filtrar por **zona / salón** si aplica.
- [ ] Permite filtrar por **tipo de venta** si aplica.
- [ ] Permite filtrar por **estado**: activo / anulado / todos.
- [ ] La UI muestra siempre el rango aplicado y la **cantidad de registros** o filas resultantes.

## 2. KPIs y columnas mínimas

- [ ] Muestra arriba KPIs útiles y sin ambigüedad: **ventas brutas**, **descuentos**, **ventas netas**, **unidades vendidas** y **tickets**.
- [ ] Si muestra ticket promedio, la etiqueta deja claro que es **promedio por ticket**.
- [ ] La tabla incluye como mínimo estas columnas:
  - [ ] **Producto**
  - [ ] **Categoría**
  - [ ] **Ventas brutas**
  - [ ] **Descuentos**
  - [ ] **Ventas netas**
  - [ ] **Unidades**
  - [ ] **Tickets**
  - [ ] **Ticket promedio**
  - [ ] **% participación**
- [ ] Las columnas monetarias están alineadas y comparables visualmente.
- [ ] El orden por monto, unidades o participación es claro y estable.

## 3. Fórmulas y credibilidad funcional

- [ ] La definición de **ventas brutas** está clara: suma vendida antes de descuentos.
- [ ] La definición de **descuentos** está clara y visible; no queda mezclada dentro del neto sin explicación.
- [ ] **Ventas netas = ventas brutas - descuentos - anulaciones imputables**.
- [ ] **Ticket promedio = ventas netas / tickets**.
- [ ] **% participación = ventas netas del producto / ventas netas totales del reporte**.
- [ ] Si existen anulaciones, no inflan ventas, unidades ni participación.
- [ ] Si un producto cambió de nombre/categoría, QA valida que el reporte use criterio histórico consistente o al menos uno explícito.

## 4. Totales y cierre numérico

- [ ] La tabla tiene **fila total** o totalizadores visibles.
- [ ] La suma de filas cuadra con los KPIs superiores, o la UI explica claramente si es un **top N** parcial.
- [ ] Las unidades totales cuadran con el total de unidades mostrado arriba.
- [ ] Los porcentajes de participación no generan lecturas engañosas.
- [ ] Lo exportado debe coincidir con lo mostrado en pantalla bajo los mismos filtros.

## 5. Responsiveness y usabilidad

- [ ] En desktop el espacio se aprovecha bien; el reporte no queda flotando ni demasiado aireado.
- [ ] En tablet no se rompen chips, filtros, botones ni encabezados.
- [ ] En anchos reducidos no hay overflow crítico ni columnas imposibles de usar.
- [ ] Si hay scroll horizontal, sigue siendo usable y no vuelve ilegible la tabla.
- [ ] La jerarquía visual sigue siendo clara en desktop y tablet.

## 6. Estados de loading, vacío y error

- [ ] El loading comunica que se está recalculando el reporte; no parece congelamiento.
- [ ] El empty state explica que **no hay ventas por producto en el rango/filtros aplicados**.
- [ ] Un rango sin datos no se ve como error técnico.
- [ ] Los errores muestran mensaje humano y acción clara de reintento.
- [ ] No se mezclan datos viejos con error nuevo de forma engañosa.

## 7. Consistencia visual MangoPOS

- [ ] Las tarjetas y contenedores usan **fondo blanco**.
- [ ] Los acentos y acciones usan **colores MangoPOS** de forma consistente.
- [ ] **No hay botones pill** ni bordes exageradamente redondeados.
- [ ] El radio visual se mantiene en **10px**.
- [ ] La pantalla se ve seria, limpia y alineada con el resto del módulo de reportes.

## 8. Criterio de aprobación

Aprobar solo si el reporte permite responder sin explicación extra:

- [ ] Qué período estoy viendo.
- [ ] Cuáles productos vendieron más.
- [ ] Cuántas unidades se vendieron por producto.
- [ ] Cuánto se descontó realmente.
- [ ] Cuál es la venta neta por producto.
- [ ] Si los totales cuadran con el resumen general.
