# Auth Smoke Tests

Checklist manual corta para validar autenticación contra el backend real antes de mover a producción.

## Precondiciones

- Backend Supabase real accesible.
- App conectada al proyecto correcto.
- Tener 2 cuentas de prueba:
  - una con confirmación de email completada
  - una pendiente de confirmación si el proyecto usa confirmación por correo
- Tener al menos un usuario con más de un negocio en `user_businesses`.
- Borrar sesión local antes de empezar la primera corrida.

## Casos críticos

### 1. Login normal

- Abrir la app sin sesión previa.
- Iniciar sesión con usuario válido y contraseña válida.
- Verificar que entra al flujo normal sin errores.
- Verificar que carga nombre de usuario y negocio.
- Verificar en logs que no aparezcan errores de refresh/auth.

Resultado esperado:
- `auth.currentSession` queda activa.
- `SessionController` restaura negocio/rol.

### 2. Login inválido

- Intentar login con contraseña incorrecta.
- Intentar login con correo inexistente.

Resultado esperado:
- No se crea sesión.
- Se muestra mensaje de error de auth.

### 3. Persistencia de sesión al reiniciar app

- Hacer login válido.
- Cerrar completamente la app.
- Abrir la app de nuevo.

Resultado esperado:
- La sesión se restaura sin pedir login.
- Se conserva negocio activo o se reelige correctamente si aplica.

### 4. Logout local

- Con sesión activa, ejecutar logout desde UI.
- Cerrar y volver a abrir la app.

Resultado esperado:
- No queda sesión restaurada.
- La app vuelve a pantalla de login.

### 5. Refresh automático

- Hacer login válido.
- Dejar la app abierta el tiempo suficiente para provocar renovación de token.
- Navegar entre pantallas que peguen al backend.

Resultado esperado:
- La sesión sigue viva.
- No hay redirect inesperado a login.
- No aparecen errores de `schema mismatch` ni `AuthRetryableFetchException` persistentes.

### 6. Refresh con token vencido o sesión inválida

- Hacer login válido.
- Invalidar la sesión desde Supabase o usar un refresh token expirado.
- Reabrir la app o forzar una operación autenticada.

Resultado esperado:
- La app limpia sesión local de forma controlada.
- Redirige a login sin quedar en loop.

### 7. Signup con confirmación de email activada

- Activar confirmación de email en el proyecto.
- Registrar una cuenta nueva desde la app.

Resultado esperado:
- El flujo no asume sesión activa si `resp.session` viene nula.
- Se crea `profiles.id = auth.users.id`.
- El usuario recibe mensaje correcto de confirmación.

Verificación sugerida en base de datos:
- `profiles.id == auth.users.id`
- no depender de `profiles.user_id` para encontrar el perfil

### 8. Signup con confirmación de email desactivada

- Desactivar confirmación de email en el proyecto.
- Registrar una cuenta nueva.

Resultado esperado:
- El usuario entra con sesión válida inmediatamente.
- `restoreFromSupabaseSession()` funciona sin errores.
- Se crean `profiles`, `businesses`, `memberships` y `user_businesses` según el flujo esperado.

### 9. Selector de negocio

- Usar un usuario con más de un negocio.
- Iniciar sesión.
- Cambiar de negocio desde la UI correspondiente.
- Reiniciar la app.

Resultado esperado:
- La sesión sigue siendo válida.
- El negocio activo cambia correctamente.
- No se pierde el rol ni aparecen consultas rotas por negocio.

### 10. Perfil consistente

- Ejecutar login con usuario existente.
- Ejecutar registro con usuario nuevo.
- Validar ambos en base de datos.

Resultado esperado:
- Todos los perfiles creados por la app usan la misma regla:
  - `profiles.id = auth.users.id`

## Señales de falla a vigilar

- Errores con texto `missing destination name oauth_client_id`
- Errores con texto `missing destination name scopes`
- Errores con texto `missing destination name refresh_token_hmac_key`
- Loops entre login y pantalla principal
- Sesión restaurada pero sin negocio/rol
- Usuario creado sin fila consistente en `profiles`

## Criterio de aprobación

Se considera aceptable para producción si:

- los 10 casos pasan
- no hay loops de sesión
- no hay inconsistencias en `profiles`
- no hay pérdida de negocio activo tras reinicio
- los errores de refresh se recuperan o fuerzan relogin de forma limpia
