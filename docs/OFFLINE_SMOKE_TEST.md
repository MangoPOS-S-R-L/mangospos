# Smoke test del modo offline — MangoPOS

> Validación manual en una terminal real (5–10 min). Confirma que la app sigue
> vendiendo/cobrando cuando se cae internet y que sincroniza al volver.
> Basado en el comportamiento real del código al 2026-06-01.

## Antes de empezar

- [ ] Usa una terminal **con internet** y con sesión iniciada (caja abierta).
- [ ] Ten a mano cómo cortar la red: apagar el WiFi del equipo o desconectar el
      cable de red es lo más limpio.
- [ ] Anota la hora — te sirve para buscar después en reportes/Supabase.
- [ ] **Importante:** mientras hay internet, **abre una vez** la pantalla de
      venta, el salón (mesas) e inventario. Eso garantiza que el catálogo,
      mesas e inventario quedaron cacheados (de todas formas el sistema los
      refresca solo al reconectar, pero así arrancas con todo fresco).

---

## Test 1 — Caída DURA (apagar WiFi). Vender y cobrar.

1. [ ] Con internet, **arma una venta** (agrega productos al carrito).
2. [ ] **Apaga el WiFi / desconecta la red.** (La detección es inmediata cuando
       el adaptador se cae.)
3. [ ] En unos segundos debe aparecer un aviso de **"Sin conexión"** / banner de
       modo offline en la UI.
4. [ ] **Cobra la venta** (efectivo).
   - ✅ **Esperado:** el cobro **se completa**, te deja imprimir y cerrar la
     venta. Queda marcada como **encolada offline**.
   - ⚠️ **El recibo offline NO trae NCF / comprobante fiscal** — eso es a
     propósito (la emisión fiscal offline está pendiente de la firma del
     contador). El NCF se asigna al sincronizar.
5. [ ] Haz **2–3 ventas más** offline para probar volumen.
6. [ ] (Opcional) Registra un **movimiento de caja** (entrada/salida) — también
       debe quedar encolado.

**Criterio de éxito:** vendiste y cobraste varias veces SIN internet, sin que la
app te bloqueara ni perdiera la venta.

---

## Test 2 — Caída SUAVE (internet cae pero el WiFi sigue "conectado")

Simula que el router pierde internet pero el equipo sigue pegado al WiFi (caso
más común en la vida real).

1. [ ] Con la app online, **corta el internet desde el router** (o desenchufa el
       módem) **sin** apagar el WiFi del equipo.
2. [ ] Intenta **cobrar** una venta de inmediato.
   - ✅ **Esperado:** el primer cobro puede tardar **hasta ~8 segundos** (la app
     intenta online, el intento expira por timeout y **cae solo a la cola
     offline**). Igual **se completa** y queda encolado.
3. [ ] Cobra una segunda venta.
   - ✅ **Esperado:** ya es **instantáneo** — para entonces la app se marcó
     offline y enruta directo a la cola.

**Criterio de éxito:** ninguna venta se pierde ni da error al usuario; solo la
primera tras la caída tarda un poco.

---

## Test 3 — Reconexión y sincronización (lo más importante)

1. [ ] **Prende el WiFi / restablece el internet.**
2. [ ] Espera. La app sincroniza sola al reconectar (y reintenta cada ~3 min).
   - ✅ **Esperado:** aparece un **aviso/snackbar de sincronización** indicando
     cuántas operaciones subieron.
3. [ ] Verifica que las ventas/cobros offline **ya aparecen** en:
   - [ ] El **historial de ventas** de la terminal.
   - [ ] El **reporte de ventas del día**.
   - [ ] (Si tienes acceso) la tabla `payments` / `orders` en **Supabase**, con
         la **hora real de la venta** (no la hora del sync).
4. [ ] Confirma que **no se duplicaron** (cada venta aparece una sola vez).

**Criterio de éxito:** todo lo que vendiste offline subió, una sola vez, con la
fecha correcta.

---

## Test 4 — Reportes del día sin internet

1. [ ] Con internet, abre **Reportes → Ventas del día** (para cachearlo).
2. [ ] Apaga el WiFi.
3. [ ] Vuelve a abrir el reporte.
   - ✅ **Esperado:** muestra los datos cacheados con un **banner de "datos
     offline / sin conexión"** (puede no incluir las ventas hechas justo offline
     hasta sincronizar).

---

## Test 5 — La config del negocio se respeta offline (F6-3)

1. [ ] Con internet, ten configurado algún toggle no-default (p. ej. "abrir
       gaveta en efectivo" o "modo de cierre detallado").
2. [ ] Apaga el WiFi y **reinicia la app** (para descartar cache en memoria).
3. [ ] Entra al flujo correspondiente.
   - ✅ **Esperado:** respeta tu configuración real (no vuelve al default).

---

## Qué NO esperar (gaps conocidos e intencionales)

- ❌ **NCF fiscal en recibos offline** → pendiente de la firma del contador (F4).
- ❌ **Sincronización del KDS por LAN entre cajas sin internet** → pendiente de
  prueba en red real (F3). Offline, la cocina funciona por **ticket impreso**.

---

## Si algo falla

- Si una venta offline **se pierde** o da **error al usuario** → es bug, repórtalo
  con la hora exacta y qué hiciste.
- Si tras reconectar **no sincroniza** en pocos minutos → revisa que la terminal
  tenga internet de verdad (no solo WiFi) y reintenta; el sync también corre al
  reabrir la pantalla de ventas.
- Si una venta aparece **duplicada** tras el sync → es bug, repórtalo.
