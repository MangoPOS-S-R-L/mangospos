# QA Manual - Ventas y Caja

## 1) Flujo Caja
- Abrir caja con monto inicial (ej. RD$ 5,000).
- Verificar estado visual "Caja Abierta".
- Confirmar que tarjetas de estadísticas cargan (ingresos/egresos/balance/transacciones).

## 2) Bloqueos por caja cerrada
- Cerrar caja.
- Ir a ventas por zona/manual/rápida.
- Verificar que no permite abrir mesa ni iniciar orden y muestra mensaje de caja cerrada.

## 3) Delivery y Self Service bloqueados
- En menú lateral de ventas, validar que ambos botones están deshabilitados.
- Intentar entrar por ruta directa:
  - Delivery: debe mostrar "Delivery no disponible".
  - Self service: debe mostrar "Self service no disponible".

## 4) Cierre de Caja a Ciegas (paso a paso)
- Con caja abierta, pulsar "Cerrar Caja".
- Paso A (Conteo):
  - Probar +/- por denominación.
  - Probar input directo de cantidad.
  - Probar numpad para tarjetas/transferencias con foco activo.
  - Verificar resumen en vivo.
- Confirmar conteo:
  - Validar modal de confirmación intermedia.
  - "Revisar de nuevo" mantiene en paso A.
  - "Confirmar Conteo" avanza a paso B.
- Paso B (Resultado):
  - Validar tabla Esperado/Reportado/Diferencia.
  - Validar estados:
    - diferencia = 0 -> Caja cuadrada
    - diferencia > 0 -> Sobrante detectado
    - diferencia < 0 -> Faltante detectado
  - Probar botón "Imprimir Cierre" (térmica o fallback PDF).
  - Probar botón "Cerrar" y confirmar que sesión queda cerrada.

## 5) Post-cierre
- Verificar que la caja queda en estado "Cerrada".
- Verificar que ventas vuelve a bloquear inicio de nuevas órdenes/mesas.
- Validar que historial de caja y gestión de cierres reflejan el último cierre.
