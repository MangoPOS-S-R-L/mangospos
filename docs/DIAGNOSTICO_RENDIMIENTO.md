# Línea base de rendimiento

El diagnóstico está **apagado por defecto**. No envía métricas a ningún servidor ni guarda datos de clientes, pedidos o importes.

## Medición comparable en Windows

1. En un negocio de prueba, abre MangoPOS en el equipo de caja. En el menú del usuario administrador, entra a **Diagnóstico de rendimiento**, selecciona **Equipo: caja** y pulsa **Iniciar**.
2. En PowerShell, desde la carpeta del proyecto, ejecuta `powershell -ExecutionPolicy Bypass -File tools/perf/measure-windows.ps1 -Role caja -DurationSeconds 300`.
3. Durante la medición, deja la app quieta un minuto, abre mesas, agrega productos y realiza pagos de prueba. Anota si se cortó internet o si trabajó por Hub.
4. Pulsa **Detener** y **Copiar reporte**. Conserva el CSV que generó PowerShell.
5. Repite el mismo recorrido y duración en un equipo de mesero con `-Role mesero`. Un administrador puede abrir temporalmente el diagnóstico en ese equipo, seleccionar **Equipo: mesero** y luego volver al rol de mesero para hacer el recorrido.

El CSV contiene CPU normalizado al total de núcleos, memoria residente y memoria privada cada cinco segundos. El panel muestra tiempos p50/p95 de apertura de mesa, RPC de apertura, confirmación de pago, RPC de pago y preparación offline, además de frames lentos y memoria RSS. Un `p95` requiere varias muestras; no saques conclusiones de una sola venta.

No compares CPU o memoria entre máquinas de distinta capacidad como si fueran equivalentes. Si la app se cierra, el script conserva las muestras tomadas hasta ese momento. El diagnóstico del panel es local y se pierde al reiniciar la aplicación.
