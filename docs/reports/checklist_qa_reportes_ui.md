# Checklist QA — Reportes (UI perfecta + credibilidad funcional)

> Objetivo: usar este documento como guardrail de aceptación para el módulo de reportes antes de darlo por bueno.
> Alcance: ventas, finanzas/caja, compras, inventario, impuestos y comprobantes fiscales.
> Regla: **no aprobar por “se ve bien”**. Solo aprobar si el reporte es claro, consistente, confiable y exportable.

## Contexto revisado

Base inspeccionada:
- `CLAUDE.md`
- `lib/presentation/reports/view/reports_view.dart`
- `lib/presentation/reports/viewmodel/reports_viewmodel.dart`
- `lib/data/repositories/reports_repository.dart`
- servicios de exportación PDF/CSV
- captura local `assets/Imagenes/reportes.png`

## Criterio maestro de aprobación

Un reporte se considera aprobado solo si cumple estas 4 condiciones al mismo tiempo:

- **Se entiende en 5 segundos**: jerarquía visual evidente, KPIs correctos y etiquetas sin ambigüedad.
- **Se puede auditar**: totales, subtotales, rango y filtros explican exactamente qué se está viendo.
- **No engaña**: estados vacíos, anulados, descuentos, impuestos y cierres de caja no maquillan la realidad.
- **Se puede sacar fuera del sistema**: exportación PDF/CSV conserva contexto suficiente para uso operativo/fiscal.

---

## 1) Filtros y contexto visible

### 1.1 Rango de fechas
- [ ] El rango activo se ve siempre arriba, sin necesidad de inferirlo.
- [ ] El rango mostrado coincide con la consulta real; no hay desfase por rango inclusivo/exclusivo.
- [ ] Si el usuario elige un rango personalizado, la UI refleja exactamente las fechas seleccionadas.
- [ ] “Hoy”, “Ayer”, “Esta semana” y “Este mes” dejan un estado visual inequívoco.
- [ ] Al cambiar el rango, el contenido se recarga sin estados confusos ni mezcla de datos viejos y nuevos.
- [ ] El usuario entiende si el rango está en hora local del negocio (no UTC crudo, no ISO técnico).

### 1.2 Persistencia y consistencia de filtros
- [ ] Al entrar a un reporte, los filtros visibles coinciden con los datos renderizados.
- [ ] El cambio de categoría no deja filtros “heredados” engañosos o fuera de contexto.
- [ ] Si existe refresh, no resetea filtros sin intención explícita.
- [ ] Toda exportación usa exactamente los mismos filtros activos que ve el usuario.

### 1.3 Filtro por tipo de comprobante
- [ ] En comprobantes fiscales existe un filtro claro por tipo de comprobante/NCF, no solo un resumen agregado.
- [ ] El filtro permite validar al menos Consumo, Crédito Fiscal, Nota de Débito, Nota de Crédito y tipos especiales relevantes.
- [ ] Cuando el filtro está activo, el resumen, tabla y exportación responden al mismo subconjunto.
- [ ] Si no hay datos para un tipo, la UI lo dice explícitamente; no aparenta error.

---

## 2) Jerarquía visual de KPIs

### 2.1 Orden correcto de lectura
- [ ] El primer KPI de cada reporte representa la verdad principal del módulo (ej. ventas netas, flujo neto, total facturado).
- [ ] Los KPIs secundarios no compiten visualmente con el KPI principal.
- [ ] Colores, tamaños y pesos tipográficos ayudan a priorizar, no decoran sin sentido.
- [ ] No hay más KPIs de los que un usuario puede escanear cómodamente en una primera pasada.

### 2.2 Claridad semántica
- [ ] Cada KPI tiene título corto y específico; evita etiquetas vagas como “Total” sin contexto.
- [ ] Cada KPI tiene subtítulo útil que explique su fórmula o alcance.
- [ ] “Ventas brutas”, “ventas netas”, “anuladas”, “subtotal”, “ITBIS”, “propina de ley” y “flujo neto” se distinguen sin ambigüedad.
- [ ] Los KPIs no mezclan montos, conteos y tasas sin una jerarquía clara.

### 2.3 Legibilidad
- [ ] Los valores importantes no se cortan ni elipsan en desktop ni tablet.
- [ ] La moneda RD$ usa formato consistente en todos los reportes.
- [ ] Los porcentajes usan precisión consistente y justificable.
- [ ] Las tarjetas no requieren hover para entenderse; hover solo añade polish.

---

## 3) Densidad visual y tablas/listados

### 3.1 Densidad correcta
- [ ] La pantalla no se siente vacía ni exageradamente aireada para datos operativos.
- [ ] La pantalla no se siente apretada ni “enterprise ugly”.
- [ ] Las filas muestran suficiente información por línea sin obligar a abrir drill-down innecesario.
- [ ] Se evita desperdiciar altura vertical en secciones con datos repetitivos.

### 3.2 Escaneabilidad
- [ ] El usuario puede encontrar top productos, categorías, empleados, zonas o tipos fiscales sin fatiga visual.
- [ ] Los encabezados de columnas/segmentos son inequívocos.
- [ ] Los rankings muestran orden real y estable por monto o relevancia.
- [ ] Si hay barras o charts, refuerzan el dato; no sustituyen detalle auditable.

### 3.3 Tabla fiscal
- [ ] La tabla de comprobantes fiscales muestra columnas suficientes para validar un documento sin abrir otro sistema.
- [ ] El scroll horizontal, si existe, sigue siendo usable y no rompe la lectura del detalle.
- [ ] Columnas monetarias están alineadas y comparables visualmente.
- [ ] Estados como “Activo” vs “Anulado” se distinguen de inmediato.
- [ ] Filas anuladas no parecen válidas ni se confunden con documentos activos.

---

## 4) Totales, subtotales y cierre numérico

### 4.1 Totales visibles
- [ ] Todo listado/tablas clave tiene total o subtotales visibles cuando aplica.
- [ ] El usuario puede verificar que el breakdown cuadra con el KPI resumen o entiende por qué no cuadra.
- [ ] Si una sección muestra solo top N, la UI lo deja claro y no aparenta cobertura total.
- [ ] Cuando hay cortes por tipo/método/categoría, queda claro si el total es completo o parcial.

### 4.2 Integridad matemática
- [ ] Ventas netas = ventas completadas - ventas anuladas, y esa relación se comunica bien.
- [ ] Flujo neto de caja = ventas + entradas manuales - salidas manuales, sin inconsistencias visuales.
- [ ] Total fiscal = impuestos + propina de ley, sin diferencias silenciosas.
- [ ] Subtotal + impuestos + propina de ley = total facturado en comprobantes activos, salvo casos documentados.
- [ ] Las cifras exportadas coinciden con las que se muestran en pantalla.

---

## 5) UX de rango de fechas

- [ ] El date picker abre con un rango coherente respecto al estado actual.
- [ ] La interacción para rango personalizado no obliga al usuario a adivinar si la fecha final es inclusiva.
- [ ] Tras elegir rango, el chip/etiqueta refleja el nuevo estado inmediatamente.
- [ ] El usuario puede volver rápido a presets comunes sin fricción.
- [ ] No hay saltos visuales bruscos, loaders bloqueantes innecesarios ni “blink” incómodo al cambiar rango.
- [ ] Si el rango es grande, la UI sigue siendo usable y la espera se comunica con elegancia.

---

## 6) Descuentos, cortesías y devoluciones/anulaciones

> Esto es crítico para credibilidad. Si el reporte oculta descuentos o cortesías, el negocio “se ve mejor” de lo que realmente pasó.

- [ ] El reporte deja claro si los montos son antes o después de descuentos.
- [ ] Las cortesías/promociones/descuentos tienen visibilidad explícita cuando afectan ventas o ticket promedio.
- [ ] Las anulaciones no inflan ventas, impuestos ni comprobantes válidos.
- [ ] Si no se soportan aún descuentos/cortesías en el resumen, eso debe estar identificado como criterio pendiente, no invisible.
- [ ] El usuario puede explicar la diferencia entre venta bruta, descuentos/cortesías, anulaciones y venta neta usando solo la pantalla.

---

## 7) Claridad fiscal e impuestos

### 7.1 Comprensión del usuario
- [ ] El reporte separa claramente base gravable, impuesto, propina de ley y total.
- [ ] “Ventas exentas” y “ventas gravadas” no se mezclan ni se interpretan mal.
- [ ] La tasa efectiva mostrada tiene sentido frente a la base gravable real.
- [ ] Los labels de impuestos incluyen nombre y tasa cuando eso mejora la auditoría.

### 7.2 Credibilidad matemática
- [ ] Los impuestos mostrados en resumen coinciden con el breakdown por tipo.
- [ ] La propina de ley no aparece mezclada como si fuera ITBIS.
- [ ] En comprobantes fiscales, el detalle por documento soporta verificación de subtotal → impuesto(s) → total.
- [ ] Los documentos anulados no contaminan los totales de activos.

---

## 8) Credibilidad del cierre de caja / finanzas

> Este bloque no se aprueba por estética; se aprueba por confianza operativa.

- [ ] La diferencia acumulada de caja no se presenta sin contexto operativo suficiente.
- [ ] El usuario puede distinguir aperturas, cierres, ventas, depósitos, retiros y gastos sin esfuerzo.
- [ ] “Sesiones abiertas” y “sesiones cerradas” no se prestan a lectura ambigua.
- [ ] Si un número representa conteo y no monto, la UI lo comunica claramente.
- [ ] El reporte no sugiere que la caja “cuadró” si realmente hubo diferencias relevantes.
- [ ] El resumen financiero permite defender un cierre frente a supervisión/administración.

---

## 9) Responsiveness y comportamiento cross-device

- [ ] En desktop ancho, el layout aprovecha el espacio y no queda “flotando”.
- [ ] En tablet, las tarjetas refluye sin cortes raros, saltos de línea feos o columnas inútiles.
- [ ] En anchos reducidos, chips, botones de exportación y selector de rango no se pisan.
- [ ] Los DataTable horizontales siguen siendo operables en pantallas más estrechas.
- [ ] No hay overflow, clipping, textos truncados críticos ni elementos imposibles de tocar.
- [ ] El orden vertical móvil/tablet sigue respetando la jerarquía de lectura.

---

## 10) Estados vacíos, loading y error

### 10.1 Loading
- [ ] El loading comunica que se están cargando reportes, no que la app se congeló.
- [ ] Si ya hay datos previos visibles, el refresh no destruye la percepción de continuidad.
- [ ] Los botones sensibles se deshabilitan con intención clara mientras se recalcula.

### 10.2 Empty
- [ ] Cada empty state explica *qué* falta: ventas, movimientos, impuestos, documentos, etc.
- [ ] Un empty state por rango vacío no parece un fallo técnico.
- [ ] Los empty states mantienen el layout limpio y consistente con el resto del módulo.

### 10.3 Error
- [ ] Los errores tienen mensaje humano, no stacktrace maquillado.
- [ ] Existe una acción obvia de reintento.
- [ ] Un error en una sección no debería inutilizar silenciosamente otras áreas si ya hay datos válidos.
- [ ] No se mezclan datos viejos con error nuevo de forma engañosa.

---

## 11) Exportación PDF/CSV lista para operación

### 11.1 Contexto mínimo obligatorio en exportes
- [ ] Todo PDF/CSV incluye nombre del reporte, rango, fecha/hora de generación y filtros activos relevantes.
- [ ] Si hay filtro por tipo de comprobante, debe salir en el archivo exportado.
- [ ] El nombre del archivo es entendible para operación, no solo técnico.

### 11.2 Fidelidad contra pantalla
- [ ] Lo exportado coincide con lo visible en la UI del mismo momento.
- [ ] Si la UI muestra top N, el export debe indicar si exporta top N o dataset completo.
- [ ] En CSV, las columnas sirven para trabajar después en Excel/Sheets sin limpieza dolorosa.
- [ ] En PDF fiscal, el detalle tiene suficiente contexto para revisión administrativa/DGII interna.

### 11.3 Calidad práctica
- [ ] El PDF no se rompe por demasiadas columnas o textos largos.
- [ ] El CSV no usa valores ambiguos para fechas, montos o estados.
- [ ] Exportar no requiere adivinar qué se va a llevar; el usuario tiene expectativa clara.

---

## 12) Checklist por módulo

### Ventas
- [ ] KPI principal = ventas netas, no un número menos útil.
- [ ] Se ven ventas brutas, anuladas, ticket promedio e items vendidos con relación clara.
- [ ] El breakdown por método, producto, categoría, empleado, zona y hora es consistente entre sí.
- [ ] Si hay descuentos/cortesías, afectan claramente la narrativa del reporte.

### Finanzas / Caja
- [ ] Se entiende flujo neto, entradas, salidas y diferencia acumulada.
- [ ] Estado de sesiones aporta confianza real, no solo conteos.
- [ ] Los movimientos por tipo no esconden retiros/gastos relevantes.

### Compras
- [ ] Monto ordenado vs recibido se diferencia sin ambigüedad.
- [ ] Estados de órdenes tienen orden y lectura clara.
- [ ] Top proveedores es útil para operación, no decorativo.

### Inventario
- [ ] El valor de stock se entiende como estimado y no como efectivo disponible.
- [ ] Bajo mínimo y agotados resaltan riesgo operativo real.
- [ ] Movimientos recientes por tipo permiten lectura rápida.

### Impuestos
- [ ] Se distinguen impuestos, base gravable, exentas y propina de ley.
- [ ] La tasa efectiva no induce a error.
- [ ] El breakdown soporta conciliación básica.

### Comprobantes fiscales
- [ ] La tabla es auditable y usable.
- [ ] Existe filtro útil por tipo de comprobante.
- [ ] Los anulados se distinguen y no contaminan totales activos.
- [ ] El detalle por impuesto por documento es coherente y exportable.

---

## 13) Señales de no aprobación inmediata

No aprobar si ocurre cualquiera de estas:

- [ ] El usuario no puede explicar de dónde sale un total principal.
- [ ] El rango visible no coincide con los datos.
- [ ] Falta visibilidad de descuentos/cortesías pese a impactar montos.
- [ ] Falta filtro útil para tipo de comprobante en fiscal.
- [ ] La tabla fiscal no permite validar rápidamente activos vs anulados.
- [ ] No hay totales/subtotales claros donde operativamente hacen falta.
- [ ] Exportación pierde contexto crítico o no coincide con pantalla.
- [ ] En tablet/móvil se rompen chips, botones o tablas.
- [ ] Error/empty/loading generan duda sobre la veracidad del dato.

---

## 14) Observaciones QA sobre la implementación actual (para orientar revisión)

Estas no son cambios pedidos; son focos de revisión al probar:

- La base actual ya tiene buena dirección visual: tarjetas limpias, chips de rango, breakdowns y exportación por categoría.
- El rango en UI usa patrón `from` + `to exclusivo`; QA debe verificar muy bien que nunca se comunique una fecha final incorrecta.
- En fiscal hay tabla detallada con columnas dinámicas de impuestos, pero **debe validarse la usabilidad real del scroll horizontal y la ausencia/presencia de totalizadores**.
- Hay resumen por tipo de NCF, pero **no se observa un filtro explícito por tipo de comprobante en la UI actual**; esto debe tratarse como criterio duro de aceptación.
- Exportes PDF/CSV ya existen, pero QA debe exigir contexto suficiente en archivo final, especialmente filtros activos y legibilidad fiscal.
- Hay manejo de loading/error/empty, pero debe validarse que no mezcle datos viejos con error nuevo de forma confusa.
- No se aprecia en la base revisada una visibilidad fuerte de **descuentos/cortesías** dentro del módulo de reportes; esto merece prueba específica antes de aprobar “UI perfecta”.

---

## Veredicto QA esperado

Aprobar solo cuando el módulo pueda responder con claridad estas preguntas, sin explicaciones verbales extra:

- ¿Qué período estoy viendo?
- ¿Cuál es el número principal y por qué?
- ¿Qué parte del monto fue anulada, descontada, gravada o cargada como ley?
- ¿La caja y los impuestos cuadran razonablemente?
- ¿Puedo exportar esto y defenderlo fuera de la app?
