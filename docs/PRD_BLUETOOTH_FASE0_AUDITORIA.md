# Fase 0 — Auditoría de hardware Bluetooth (impresoras térmicas)

> Objetivo: determinar, por marca/modelo de impresora en producción, qué
> transporte Bluetooth expone (**Classic/SPP**, **BLE**, o **dual-mode**) y si
> es **MFi** (relevante solo para iOS). Eso decide el camino de impresión y
> cierra el alcance de iOS.

## Por qué importa

La app elige el transporte **automáticamente** en Android:

| Capacidad del equipo | Transporte que usa la app | Notas |
|---|---|---|
| Pareado + expone **SPP** (Classic) | **Classic/RFCOMM** | Más rápido para tickets largos; única vía si es Classic-only. |
| BLE-only (sin SPP) | **BLE/GATT** | Funciona, algo más lento en tickets largos. |
| Dual-mode (SPP + BLE) | **Classic** (preferido), BLE de respaldo | Lo mejor de ambos. |

En **iOS** no hay Classic para apps de terceros (salvo MFi): siempre BLE.

## Método 1 — Diagnóstico in-app (el más rápido) ✅

En la app: **Ajustes › Impresoras › icono 🔵 (Diagnóstico Bluetooth)**.

1. Empareja primero la impresora en **Ajustes › Bluetooth de Android**.
2. Abre el diagnóstico y concede el permiso de Bluetooth.
3. Cada impresora pareada muestra una etiqueta:
   - **Classic/SPP** → imprimirá por RFCOMM (rápido).
   - **BLE-only** → usará GATT.

Anota el veredicto por modelo. Si un modelo no aparece estando pareado, puede
ser BLE-only (no siempre requiere emparejarse): pruébalo por BLE.

> Solo Android. En iPad el diagnóstico informa que el transporte es BLE.

## Método 2 — Ficha técnica del fabricante

Busca en la hoja de datos / manual del modelo:
- "**SPP**", "Serial Port Profile", "Bluetooth Classic", "BR/EDR" → **Classic**.
- "**BLE**", "Bluetooth Low Energy", "4.0/5.0 LE", chips **ISSC/Microchip**,
  **HM-10**, **nRF** → **BLE**.
- "**Bluetooth 4.0 dual-mode**" o que liste ambos perfiles → **dual-mode**.
- "**Made for iPhone/iPad (MFi)**" → relevante para iOS (poco común en
  térmicas económicas).

## Método 3 — Verificación MFi para iOS

- Revisa si el fabricante declara certificación **MFi** (programa de Apple).
- Sin MFi y siendo Classic → iOS **no** puede usarla; en iPad va por **BLE**
  (si el equipo lo soporta) o **WiFi/LAN**.

## Qué registrar (por modelo)

| Campo | Ejemplo |
|---|---|
| Marca / modelo | 2Connect POS8001 V7 |
| Perfil BT | dual-mode (SPP + BLE) |
| `hasSpp` (diagnóstico in-app) | sí |
| MFi | no |
| Transporte resultante Android | Classic |
| Transporte resultante iOS | BLE |
| Notas de campo | corte OK; reconexión < 2s |

## Decisión de alcance (resultado de la auditoría)

- **Todas Classic o dual-mode** → el transporte Classic ya construido aporta
  velocidad y cobertura total; BLE queda de respaldo.
- **Todas BLE-only** → Classic no se usará (la app cae a BLE solo); igual queda
  disponible por si entran modelos Classic.
- **Alguna Classic-only** → Classic es **obligatorio** para no perder ese
  hardware (ya soportado).
- **iOS**: si no hay MFi (lo esperable), iPad imprime por **BLE** o **WiFi/LAN**.

Registra la conclusión y la tabla por modelo en este documento o en el tracker
del proyecto.
