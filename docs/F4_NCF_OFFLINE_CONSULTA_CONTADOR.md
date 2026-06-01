# Consulta fiscal — Emisión de NCF sin conexión a internet (MangoPOS)

> Documento para el **contador / asesor fiscal** del negocio.
> Objetivo: validar el enfoque antes de activarlo. Fecha: 2026-06-01.

---

## 1. Qué queremos lograr

Que las cajas puedan **seguir facturando con NCF válido cuando se cae el
internet**, manteniendo la numeración **correcta** (sin números duplicados ni
repetidos entre cajas) y regularizando todo con DGII al reconectar.

## 2. Cómo lo haríamos (en simple)

- Las cajas del local están en la **misma red local (LAN)**. Aunque se caiga el
  internet, las cajas se siguen "viendo" entre sí.
- Aprovechamos eso: **un equipo del local actúa como coordinador**. Mientras no
  hay internet, **ese coordinador es el único que asigna el próximo NCF** —
  exactamente el mismo rol que hoy cumple el servidor en la nube.
- **Resultado: la numeración sigue siendo secuencial y SIN HUECOS**, aunque
  facturen varias cajas a la vez sin internet. Al volver el internet, el
  coordinador sincroniza todo con el sistema/DGII.

```
Con internet           →  el servidor en la nube asigna el NCF (como hoy)
Sin internet (con LAN) →  el coordinador local asigna el NCF, secuencial
Al reconectar          →  se sincroniza todo; sin duplicados, sin huecos
```

## 3. Lo que necesitamos que nos confirmes

1. **Estructura de autorización NCF.** Para operar varias cajas, ¿DGII autoriza
   al negocio con:
   - **(a)** una **secuencia/serie por caja** (cada terminal con su rango), o
   - **(b)** **una sola secuencia** que el sistema administra y reparte entre
     cajas?

   *Recomendamos (b) por simplicidad de gestión; necesitamos tu confirmación de
   cómo está autorizado HOY el negocio.*

2. **e-CF (factura electrónica).** ¿El negocio puede emitir en **contingencia**
   — es decir, emitir el e-NCF sin conexión y **transmitirlo a DGII dentro de la
   ventana permitida** al reconectar? ¿Nuestro proveedor (Alanube) lo soporta en
   el plan contratado?
   - Si **NO**: el e-CF se emitirá únicamente al reconectar; sin internet solo
     se emitirían NCF de **papel** (B0x). (Esta es la opción más conservadora.)

3. **Caso extremo — caja aislada.** Si una caja queda sin internet **y** sin ver
   al coordinador local (falla de red interna), proponemos entregar un **recibo
   provisional SIN NCF** y asignar el NCF al reconectar — así nunca hay riesgo de
   duplicar un número. ¿Lo apruebas, o prefieres que esa caja **no pueda emitir
   comprobante fiscal** hasta reconectar?

## 4. Garantías que damos

- **Sin duplicados:** imposible que dos cajas emitan el mismo NCF (un único
  coordinador asigna, y el servidor valida unicidad como segunda barrera).
- **Sin huecos** en operación normal (con el coordinador en la LAN). Solo podría
  quedar un comprobante **diferido** en el caso extremo de la caja aislada.
- **Auditoría:** cada comprobante emitido sin conexión queda **marcado**, y te
  entregamos un reporte para tu revisión y para soportar cualquier reporte a
  DGII (607/608, anulaciones, etc.).
- **Activación controlada:** la función queda **apagada** hasta tu visto bueno;
  se prueba primero en **una sola caja** comparando contra DGII antes de
  habilitarla en todo el local.

## 5. Qué pasa hoy (sin esta función)

Hoy, sin internet, el cobro se registra pero **el comprobante queda sin NCF
hasta reconectar** (se asigna retroactivamente). Esta función elimina esa espera
para el cliente, manteniendo el cumplimiento.

---

*Con tu respuesta a la sección 3, activamos el desarrollo final (asignación
coordinada + reportes de auditoría) sobre la infraestructura ya construida.*
