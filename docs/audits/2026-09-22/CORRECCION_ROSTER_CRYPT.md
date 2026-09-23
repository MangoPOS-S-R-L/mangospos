# Descarga de usuarios offline: crypt(text, text)

La captura muestra que la vinculación terminó, pero `fn_sync_roster` falló con código 42883 al comprobar el token mediante `crypt(text, text)`. La migración de mayo que corrigió `fn_device_bind` y el trigger de PIN no incluyó esta función. La implementación original de `fn_sync_roster` mantiene una llamada a `crypt` sin schema; depende del `search_path` instalado.

Se creó `supabase/migrations/20260922_0001_sync_roster_pgcrypto.sql`. Obtiene el schema donde está instalada pgcrypto, califica la llamada y fija el search_path. Preserva la definición instalada, la firma y las autorizaciones de la función; no registra equipos, rota tokens ni cambia usuarios. Aborta si la función o la extensión no existen o si la definición no coincide con el caso esperado. Puede ejecutarse dos veces. La resolución por schema coincide con la [documentación de extensiones de Supabase](https://supabase.com/docs/guides/database/extensions).

## Aplicación pendiente

1. Abrir el SQL Editor del Supabase de MangoPOS (`supabase.mangopos.do`, instalación propia; no los proyectos Cloud de otras aplicaciones).
2. Ejecutar el archivo completo `20260922_0001_sync_roster_pgcrypto.sql`.
3. En el equipo ya vinculado, pulsar **Sincronizar ahora**. No desvincular ni volver a registrar el equipo por este error.
4. Confirmar una fecha de sincronización y usuarios con PIN disponible. Volver al panel de preparación y revisar el estado.

No se aplicó en producción: no hay un proyecto Cloud de MangoPOS accesible con la sesión CLI; el SSH documentado al VPS rechazó autenticación (`Permission denied`). Tampoco había una sesión abierta del panel de Supabase en el navegador inspeccionado. No se intentó aplicar SQL a proyectos de otras aplicaciones.

## Validación

`bash supabase/tests/offline_roster_pgcrypto_local_test.sh` levanta PostgreSQL 15 desechable y reproduce el 42883 con la función original del repositorio. Luego aplica la migración dos veces y verifica token válido, aislamiento de negocio, rechazo de token vacío/inválido/revocado, conservación del token y ACL, SECURITY DEFINER, actualización de last_seen y resistencia a una función `public.crypt` homónima. Todas las comprobaciones pasaron; no utiliza datos reales.

En la app, un error al descargar usuarios después de vincular ahora usa el mensaje de error rojo, no el mensaje verde de éxito. Para 42883/crypt explica que falta actualizar el servidor y que el equipo continúa vinculado. «Nunca» ya no se describe como permisos vencidos: se informa que todavía falta descargar usuarios. Pruebas de pantalla: 8 aprobadas.

La otra captura muestra además rutas de cocina sin impresoras guardadas para `cervezas`, `kitchen_hot` y `cocina`. Es un pendiente separado: revisar asignaciones en Ajustes > Impresión y actualizar las descargas. El arreglo de `fn_sync_roster` no cambia esas rutas ni asigna impresoras por suposición.
