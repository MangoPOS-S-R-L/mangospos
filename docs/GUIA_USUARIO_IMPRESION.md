# Guía de Usuario — Sistema de Impresión MangoPOS

> **Audiencia:** Dueños, gerentes, cajeros, meseros y staff de soporte de clientes.
> **Requiere:** MangoPOS v2 de impresión instalado.
> **Documentos relacionados:** [PRD_IMPRESION_TOAST_LEVEL.md](PRD_IMPRESION_TOAST_LEVEL.md) (qué se construye), [MANUAL_TECNICO_IMPRESION.md](MANUAL_TECNICO_IMPRESION.md) (para devs/soporte técnico).

---

## ¿Qué hay de nuevo?

MangoPOS ahora maneja **impresoras de cualquier tipo** (LAN, USB, Bluetooth) y te permite **elegir a dónde imprimir** cada ticket. Sin importar si tu restaurante tiene 1 caja con una impresora o 8 estaciones con tecnologías mezcladas, funciona igual.

### En 30 segundos

- 🖨️ **Antes:** una impresora por tipo (recibo, pre-cuenta, cocina). Si quería cambiar destino había que ir a configuración.
- 🖨️ **Ahora:** podés tener varias impresoras del mismo tipo. Al imprimir, el sistema te pregunta dónde si hay más de una opción.
- 📡 **Tecnologías soportadas:** LAN (red), USB (cable directo), Bluetooth, Serial, sistema operativo (CUPS).
- 🔁 **Fallback automático:** si la impresora principal cae, intenta con la de respaldo sin que te enteres.
- 📊 **Dashboard:** ves en tiempo real si una impresora está sin papel, offline, etc.

---

## Para empezar

### Antes de configurar

Necesitas saber:

- [ ] Cuántas impresoras tenés.
- [ ] De qué tipo es cada una (LAN, USB, BT).
- [ ] Para qué la vas a usar (recibo de caja, pre-cuenta para mesero, cocina, bar, etc.).
- [ ] Si es LAN: la IP de cada una (preferiblemente fija).
- [ ] Si es BT: que esté pareada al device donde la vas a usar.
- [ ] Si es USB: que esté conectada antes de configurar.

> 💡 Si no sabés la IP de una impresora LAN, imprime su "self-test" presionando el botón de feed mientras la prendes. Sale en el ticket.

---

## Sección 1 — Configuración

### 1.1 Agregar una impresora

`Ajustes → Impresión → Impresoras → ➕ Agregar`

1. **Nombre**: usa algo descriptivo. Ejemplos:
   - `Recibo Caja 1`
   - `Cocina Caliente`
   - `Bar`
   - `PrecMozo Salón`

2. **Propósito** (qué imprime):
   - **Recibo** — tickets fiscales finales en caja
   - **Pre-cuenta** — cuenta para el cliente antes de pagar
   - **Comanda (kitchen)** — órdenes que van a cocina/bar
   - **Etiqueta (label)** — etiquetas de delivery, lotes, etc.
   - **General** — todo uso

3. **Tipo de conexión (transport)**:

   | Tipo | Cuándo usarlo |
   |---|---|
   | **LAN** | Impresora con cable de red. Lo más recomendado. |
   | **USB** | Impresora conectada por cable USB a una PC. |
   | **Bluetooth** | Impresora pareada por BT a una tablet/PC. |
   | **Serial** | Impresoras viejas con cable serial (raro). |
   | **CUPS** | Impresora ya configurada en el sistema operativo. |

4. **Configuración de conexión** (cambia según el tipo):

   - **LAN**: IP (ej. `192.168.1.60`) + Puerto (default `9100`).
   - **USB**: el sistema detecta automáticamente. Si no, vendor/product ID.
   - **Bluetooth**: dirección MAC + PIN (típico `0000`).
   - **Serial**: puerto (`COM3`, `/dev/ttyUSB0`) + velocidad (baud).
   - **CUPS**: nombre de la cola.

5. **Configuración del papel**:
   - **Ancho**: 80mm (estándar) o 58mm (mini, móvil).
   - **Codepage**: `CP858` (acentos y ñ funcionan), `CP437` (impresoras viejas), `CP1252` (Windows Latin).
   - **Modelo** (opcional): para aplicar comandos específicos.

6. **Probar**: botón _"Imprimir test"_ saca un ticket de prueba. Si no sale o sale mal:
   - ¿IP correcta? → ping desde una PC de la red.
   - ¿Acentos basura? → cambiar codepage.
   - ¿No corta papel? → revisar comando de corte en el modelo.

### 1.2 Crear estaciones de preparación (prep stations)

Las estaciones son **destinos lógicos**, no físicos. Permiten que asignes productos a "Cocina Caliente" sin importar cuál impresora atiende esa estación.

`Ajustes → Impresión → Estaciones → ➕ Nueva estación`

Ejemplos típicos:
- 🔥 **Cocina Caliente** — hamburguesas, carnes, fritos
- ❄️ **Cocina Fría** — ensaladas, sandwiches fríos, ceviches
- 🍷 **Bar** — tragos, cervezas, vino, refrescos
- 🍰 **Postres** — postres, café, té
- 🥖 **Panadería** — pan, sandwiches calientes

Para cada estación:
- Nombre y color (para identificarla rápido en pantalla).
- Impresoras asignadas (1 o más, con prioridad).

### 1.3 Asignar impresoras a una estación

Dentro de cada estación, agregás 1 o más impresoras con **prioridad**:

| Estación | Impresora | Prioridad |
|---|---|---|
| Cocina Caliente | Impresora Cocina | 1 (principal) |
| Cocina Caliente | Impresora Backup | 2 (fallback) |

Si la principal falla, automáticamente intenta con la de prioridad 2. Sin intervención.

### 1.4 Asignar productos a estaciones

`Productos → editar producto → Estaciones de preparación`

Marcá las estaciones a donde debe ir cada producto. Un producto puede ir a varias:
- _"Combo Hamburguesa con Papas"_ → Cocina Caliente + Bar (si lleva refresco)

Cuando el mesero envía la comanda, MangoPOS divide automáticamente:
- A Cocina Caliente: hamburguesa + papas
- A Bar: refresco

### 1.5 Asignar impresora de recibo a cada caja

`Ajustes → Cajas → editar Caja N → Impresora de recibo`

Cada caja física puede tener su propia impresora de recibos. Cuando cierras una cuenta en _Caja 1_, el ticket sale en la impresora de _Caja 1_.

### 1.6 Vincular impresora BT/USB a un device

Las impresoras BT y USB solo pueden imprimir desde el device al que están conectadas/pareadas. Por eso hay que decirle a MangoPOS cuál device "es dueño" de cuál impresora.

`Ajustes → Impresión → Vinculaciones → ➕ Vincular`

1. Selecciona el device (PC/tablet).
2. Selecciona la impresora BT/USB.
3. Confirma.

A partir de ese momento, cualquier print job para esa impresora se rutea automáticamente al device correcto, sin importar desde dónde lo haya iniciado el usuario.

---

## Sección 2 — Uso diario

### 2.1 Imprimir pre-cuenta con selector

1. Abrí la mesa.
2. Presioná **Pre-Cuenta**.
3. Si hay **una sola** impresora configurada → imprime directo (igual que antes).
4. Si hay **varias** → aparece un menú:

```
┌──────────────────────────────────────┐
│ ¿Dónde imprimir la pre-cuenta?       │
├──────────────────────────────────────┤
│ 🖨️  PrecMozo Salón    LAN  online    │
│ 🖨️  Caja 2            LAN  online    │
│ 🖨️  Mozo BT            BT  online    │
│ 📱 Solo pantalla                     │
│ 💬 Enviar por WhatsApp               │
└──────────────────────────────────────┘
```

5. Tocá la opción que querés.

> 💡 La próxima vez, la última opción que elegiste sale **pre-seleccionada**.

### 2.2 Enviar comanda a cocina

1. Tomás la orden.
2. Presionás **Despacho** o **Enviar a cocina**.
3. MangoPOS divide automáticamente y manda a cada estación.
4. Si una impresora falla, intenta con la de fallback.
5. Si TODAS fallan, te avisa con una alerta.

### 2.3 Re-imprimir un ticket

Si una comanda no llegó a cocina (papel atorado, impresora apagada):

`Mesa abierta → Reimprimir comandas` → elegís cuál.

### 2.4 Pre-cuenta por pantalla (sin imprimir)

Si el cliente prefiere ver la cuenta en el celular del mesero (sin imprimir):

1. En el selector, elegí **"Solo pantalla"**.
2. Le mostrás el modal con los items y total.
3. Si decide pagar, va a la caja (la caja imprime el recibo final).

### 2.5 Enviar por WhatsApp (opcional)

1. Cliente da su número en la orden (al abrir la mesa).
2. Al imprimir pre-cuenta, elegís **"WhatsApp"**.
3. Se abre WhatsApp Web/App con el PDF adjunto al cliente.
4. Le das _Enviar_.

> ⚠️ Requiere que el cliente tenga el número registrado en la orden.

---

## Sección 3 — Dashboard de salud

`Ajustes → Impresión → Estado en vivo`

Verás todas tus impresoras con color:

| Color | Significado | Acción |
|---|---|---|
| 🟢 Verde | Online y funcionando | — |
| 🟡 Amarillo | Sin papel / advertencia | Cambiar papel |
| 🔴 Rojo | Offline / no responde | Revisar cable, energía, IP |
| ⚫ Gris | Sin datos recientes | Reiniciar agent o esperar |

Ejemplo:

```
┌──────────────────────────────────────────────────────────┐
│ Estado de impresoras                          [Actualizar]│
├──────────────────────────────────────────────────────────┤
│ 🟢 Cocina Caliente    LAN  192.168.1.60   últ. uso 2 min │
│ 🟢 Bar                LAN  192.168.1.62   últ. uso 5 min │
│ 🟡 Postres            BT   00:11:22:33   sin papel       │
│ 🔴 Cocina Fría        LAN  192.168.1.61   offline 12 min │
│ 🟢 Recibo Caja 1      USB  Epson TM-T20    últ. uso 1 min │
└──────────────────────────────────────────────────────────┘
```

Al tocar una impresora, ves su historial reciente, errores, y botón de _"Probar"_.

---

## Sección 4 — Resolución de problemas comunes

### "No sale el ticket"

1. Mirá el **dashboard de salud** — ¿está verde?
2. Si está rojo:
   - LAN: ping a la IP desde otra PC. Si no responde → revisar cable, energía, IP fija.
   - BT: ¿está pareada? Re-parear desde Bluetooth del SO.
   - USB: ¿está conectado el cable? ¿el agent está corriendo?
3. Si está amarillo: cambiar papel, cerrar tapa.
4. Probar con _"Imprimir test"_ desde la configuración de esa impresora.

### "Salen los acentos basura (Ã±, Ã©, etc.)"

Cambiar **codepage** de la impresora:
- `CP858` (default, soporta € y ñ) ← probar primero
- `CP1252` (Windows Latin) ← si CP858 falla
- `CP850` (multiidioma)

Probá uno, imprimí test, y elegí el que se vea bien.

### "El ticket sale cortado o con caracteres raros"

- ¿Ancho de papel correcto? (80mm vs 58mm)
- ¿La impresora soporta ESC/POS? Casi todas sí, pero algunas chinas baratas no.

### "Se imprime dos veces el mismo ticket"

- Revisar si dos cajas tienen la misma impresora asignada como recibo.
- Revisar si hay agentes duplicados en el mismo device (matar uno).

### "Una impresora aparece offline pero está funcionando"

- Reiniciar el agent en ese device (`Ajustes → Sistema → Reiniciar agent`).
- Esperar 30s para que mande nuevo heartbeat.

### "Quiero forzar que un mesero NO pueda cobrar"

`Ajustes → Roles → editar rol "Mesero" → desactivar permiso "Cobrar"`

A partir de ese momento, los meseros con ese rol no ven el botón _Pagar_, solo _Pre-cuenta_.

---

## Sección 5 — Mejores prácticas

### Para restaurantes pequeños (1 caja, 1-2 impresoras)

- LAN siempre que se pueda.
- 1 impresora de recibo en la caja.
- 1 impresora de cocina compartida (si es comida casera donde no hay separación de estaciones).
- 1 estación: "General".

### Para restaurantes medianos (2-3 cajas, 4-6 impresoras)

- LAN cableada para todo.
- 1 impresora de recibo por caja.
- 3-4 estaciones: Cocina Caliente, Cocina Fría, Bar, Postres.
- 1 estación de pre-cuenta en el área de meseros.

### Para restaurantes grandes (3+ cajas, 6+ impresoras, 10+ meseros)

- LAN cableada con VLAN separada para impresoras.
- 1 impresora de recibo por caja.
- 4-6 estaciones de preparación.
- 2-3 estaciones de pre-cuenta (una por zona del salón).
- Configurar impresora de backup en al menos cocina caliente y bar.
- Activar dashboard de salud en una pantalla siempre visible al gerente.

### Reglas generales

- ✅ **IP fija** para todas las impresoras LAN.
- ✅ **UPS** en el switch, router e impresoras críticas.
- ✅ **Cableado** sobre WiFi para impresoras (siempre).
- ✅ **Capacitar al staff** en re-imprimir y dashboard.
- ❌ **No mezclar** WiFi del cliente con red de impresoras.
- ❌ **No usar BT** para impresoras de cocina alto volumen.

---

## Apéndice — Plantilla de configuración inicial

Cuando configuras un cliente nuevo, seguí este orden:

1. **Listado de hardware**:
   ```
   Impresoras:
   - Caja 1:     Epson TM-T20III LAN  192.168.1.50
   - Caja 2:     Epson TM-T20III LAN  192.168.1.51
   - Cocina:     Xprinter XP-N160II   192.168.1.60
   - Bar:        Xprinter XP-N160II   192.168.1.62

   Cajas:
   - PC Caja 1
   - PC Caja 2

   Estaciones meseros:
   - 6 tablets Android
   ```

2. **Agregar las 4 impresoras** en MangoPOS (sección 1.1).
3. **Crear estaciones**: Cocina, Bar.
4. **Asignar impresoras a estaciones** (sección 1.3).
5. **Asignar productos a estaciones** (sección 1.4).
6. **Asignar impresora de recibo** a cada caja (sección 1.5).
7. **Probar**: hacer una orden de prueba con productos de cocina + bar → verificar que ambas impresoras imprimen.
8. **Probar pre-cuenta** con selector.
9. **Mostrar dashboard de salud** al cliente.
10. **Capacitar staff** (30 min):
    - Cómo enviar comanda.
    - Cómo imprimir pre-cuenta.
    - Qué hacer si falla una impresora (cambiar papel, alertar al gerente).
    - Cómo re-imprimir.

---

## Soporte

- 📧 soporte@mangospos.com
- 📱 WhatsApp: TBD
- 📖 Manual técnico: [MANUAL_TECNICO_IMPRESION.md](MANUAL_TECNICO_IMPRESION.md)
- 🐛 Reportar bug: TBD
