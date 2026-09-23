# Indicador de preparación offline

Implementado localmente el 22 de septiembre de 2026. Sin despliegue ni cambios de datos en producción.

En móvil y escritorio aparece una franja bajo la cabecera con «Preparando datos offline», «Verificando datos offline», «Preparación offline pendiente» o «Datos offline listos». «Ver detalles» abre la lista de copias de este equipo y «Actualizar descargas» ejecuta la descarga existente. Sin internet, el botón cambia a «Revisar datos guardados» y no inicia peticiones remotas.

## Qué verifica

El estado se calcula leyendo el almacenamiento, incluso después de reiniciar la aplicación. No depende de un booleano de éxito guardado anteriormente.

- Catálogo con productos identificados, nombre y precio.
- Impuestos descargados; distingue una lista vacía válida de datos ausentes.
- Opciones de cada producto: modificadores y combos. Un grupo referenciado debe existir.
- Configuración del negocio.
- Zonas y copia de mesas de cada zona.
- Impresoras asignadas a todas las áreas usadas por los productos, incluidos destinos múltiples. Valida negocio, estado activo e identificación del destino; no sondea físicamente la impresora. Considera cocina configurada sin impresión.
- Equipo vinculado y usuarios activos con PIN descargado y permisos dentro de su vigencia actual de 24 horas.

La revisión se renueva al abrir el panel, tras el progreso de descargas y cada minuto, también sin WAN. Los fallos de actualización identifican el módulo y mantienen el indicador pendiente aunque todavía haya una copia anterior. El panel muestra la hora de revisión, no la presenta como hora de última descarga.

## Cambios complementarios necesarios

La descarga general ahora guarda explícitamente que un producto no tiene modificadores y descarga las opciones de los combos. La preparación espera la escritura de configuración y mesas; incluye las zonas virtuales presentes en el catálogo de zonas. Los fallos parciales de mesas e impresoras se comunican al coordinador.

El coordinador publica progreso y errores, impide ejecuciones solapadas, limita la espera de cada módulo y no inicia los módulos restantes si detecta pérdida de conexión. Al cambiar de negocio se destruye el coordinador anterior: una consulta en vuelo puede terminar para ese negocio, pero no inicia el siguiente módulo. Cada nuevo ciclo queda vinculado a un solo negocio.

## Validación

- Suite completa: **1,594 aprobadas, 1 omitida, ninguna fallida**.
- 20 pruebas nuevas: inspección del almacenamiento, progreso/fallo/reintento/timeout/cierre del coordinador, descarga real del preparador con HTTP simulado y controles del panel.
- Pruebas de widget a 320 y 1280 px, sin desbordamientos; actualización manual, bloqueo de doble pulsación y revisión local sin iniciar descarga.
- Análisis estático de los 14 archivos seleccionados: sin incidencias.

## Alcance

«Datos offline listos» verifica las copias listadas para ventas, mesas y cocina. No certifica impresión física, salud del Hub, arranque web offline, integridad remota de sincronización ni cobertura de todos los módulos. Las descargas adicionales de inventario y secuencias fiscales siguen en el ciclo y sus errores se muestran, pero no se incluyen en la inspección de copias de esta primera versión. Tampoco se ha probado todavía en el hardware del evento.

La instalación/publicación y el ensayo de corte real continúan pendientes.

## Ajuste tras la captura del equipo sin vincular

La falta de vinculación ya no se presenta como un fallo de red. El panel explica que los datos están guardados cuando solo falta el PIN y ofrece «Vincular este equipo», que abre la pantalla existente. La vinculación sigue siendo una acción del propietario/administrador; no se registra un equipo automáticamente. Al volver, o al actualizar la vinculación, se revisa otra vez el estado local. Validación del ajuste: 23 pruebas focalizadas aprobadas y análisis estático sin incidencias.
