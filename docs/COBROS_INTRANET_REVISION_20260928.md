# Revision de cobros e intranet

Fecha: 2026-09-28. Caja Windows como Hub; meseros Windows como clientes.

## Corregido

- El Hub respeta `close_order: false`: un abono no libera la mesa ni permite
  podar su log. Al cerrar una subcuenta se retiran solo sus items cuando el
  log contiene su identificador real; la ultima subcuenta libera la mesa.
- El modal dividido bloquea ediciones, doble confirmacion, Escape y salida
  durante el cobro. Terminar la impresion no permite volver a cobrarlo.
- Los reintentos conservan abonos confirmados, indices, importes y fecha en
  la misma instancia del modal. Los envios offline conservan ID y asignacion
  fiscal. Fallar el guardado offline no dispara un cobro online alternativo.
- La recuperacion de duplicados exige orden, subcuenta, metodo, indice,
  importe y vuelto coincidentes. Se detectan respuestas de cuentas cerradas
  que corresponden al ultimo pago, en lugar del abono solicitado.
- El RPC de pago tiene limite de 12 segundos. Un timeout NO cancela el RPC
  ni prueba que no se cobro: se conserva la intencion al reintentar y sigue
  siendo indispensable la deduplicacion existente en el servidor.
- Consultas posteriores de documento/nota y asociacion bancaria del modal
  dividido tienen limite de 3 segundos. La consulta fiscal filtra subcuenta.
  Se mantiene el limite de 8 segundos de emision electronica.
- Se conserva la referencia del abono. Si falla el callback posterior se
  informa que el pago esta registrado y se debe revisar/reimprimir, no cobrar
  otra vez. La pausa visual final baja de 1200 a 300 ms.

## Pendiente antes de certificar continuidad completa

1. Persistir el intento completo antes del primer envio, con recuperacion al
   reiniciar. El progreso del modal es memoria, NO un diario durable. El split
   offline sigue guardandose por abono, no en una transaccion unica.
2. Implementar un comando transaccional de cobro en el Hub. Hoy subsisten
   rutas directas a Supabase; saldo de mesa y credito necesitan servidor.
3. Probar dos equipos cobrando la misma cuenta. El indice existente incluye
   metodo e indice: no sustituye un bloqueo por cuenta en el Hub ni resuelve
   todos los cambios de autoridad nube/Hub/cola propia tras perder un acuse.
4. Persistir y reintentar la metadata bancaria sin repetir el cobro. La
   asociacion es posterior al RPC y el replay no aplica `bank_account_id`.
5. Publicar consistentemente los cierres online a clientes LAN. Los logs con
   posiciones numericas de subcuenta necesitan un mapeo explicito a IDs.
6. Auditar completamente el modal simple y todos los callbacks de impresion.
   Los cambios de UI cubren el modal dividido; los de repositorio son comunes.

## Verificacion

- 533 pruebas Flutter correctas y una prueba preexistente omitida por cambio
  de politica de redondeo: ventas, offline, PIN, Hub y UI de cobros.
- Nuevos escenarios: doble confirmacion, fallo entre abonos, reintento offline,
  cierre de salon, recuperacion exacta, Escape durante el cobro e impresion.
- Analisis estatico de archivos de cobro modificados: sin incidencias.
- No se modifico ni desplego una migracion fiscal en esta revision.

Falta instalar y probar con caja y dos meseros Windows: desconectar WAN sin
apagar LAN, cortar LAN durante el acuse, reiniciar durante un split y verificar
pagos/documentos al reconectar. Probar tambien impresora apagada. Medir p50/p95
de cobro y propagacion real; las pruebas unitarias no son un benchmark.

No se certifica operacion integral por intranet ni ausencia absoluta de fallos.
Ver `INTRANET_WINDOWS_Y_ADMINISTRACION.md` para PIN y administracion pendiente.
