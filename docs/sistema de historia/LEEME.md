# Módulo de Historial (jigger BARRAS)

Registra **todo lo que se crea, cambia o borra**: quién lo hizo, cuándo y qué cambió (antes → después).
Nadie lo puede editar ni borrar desde la app, ni siquiera el dueño.

## Cómo funciona
La **base de datos lo llena sola** con un *trigger*. La app no escribe en el historial, solo lo lee.
Por eso funciona aunque el cambio venga de otra pantalla, otra app o el panel de Supabase.

## Archivos

| Archivo | Qué hace |
|---|---|
| `sql/historial.sql` | Crea la tabla `historial`, la función `registrar_historial()` y los triggers. Se pega en Supabase › SQL Editor. |
| `lib/historial.ts` | Convierte cada registro en una frase legible ("John cambió el total de la factura F-00012") y traduce los nombres de los campos. |
| `components/Historial.tsx` | La lista del historial (con "Ver más") y el historial de un solo documento (`HistorialFactura`). |
| `app/historial.tsx` | La pantalla completa con buscador y filtros por tipo. |

## Lo que hay que adaptar en el otro sistema

**Base de datos (`sql/historial.sql`):**
1. Cambia `negocios` por la tabla de empresas de tu sistema. Si tu sistema no maneja varias empresas, quita la columna `negocio_id`.
2. La política usa `es_admin(negocio_id)`. Cámbiala por la forma en que tu sistema sabe quién es administrador.
3. El nombre de quien hizo el cambio sale de la tabla `miembros`. Cámbiala por tu tabla de usuarios.
4. La línea de `superadmins` se puede borrar si no la usas.
5. Al final, en `array['facturas','cotizaciones',...]`, pon **las tablas de tu sistema** que quieras vigilar.
6. Requiere **Supabase** (usa `auth.uid()`). En otro PostgreSQL, cambia `auth.uid()` por la forma en que guardas el usuario actual.

**App (React Native / Expo con Supabase):**
- `lib/historial.ts`: en `TABLAS`, `COSA` y `CAMPOS` pon los nombres de tus tablas y campos en español.
- Los componentes usan piezas propias de jigger (`components/ui`, `lib/sesion`, `lib/negocio`, `lib/tema`). En tu sistema, cámbialas por tus botones, colores y tu forma de saber el usuario y la empresa.
- Si tu otro sistema es web normal (HTML, PHP, etc.), la parte de SQL sirve igual. Solo hay que hacer la pantalla en ese lenguaje: es una consulta `select * from historial order by cuando desc`.

## Qué guarda en cada cambio
- **Crear / borrar:** la fila completa.
- **Editar:** solo los campos que cambiaron, como `{"total": [5000, 6500]}`.
- La configuración guarda cada dato por separado. El logo no se copia, solo se anota que cambió.
