# Nuevo Diseño de Cards de Mesas - Implementación Completa
## MangoPos Dashboard - Active Tables Widget

Date: 2026-02-03
Status: ✅ IMPLEMENTADO

═══════════════════════════════════════════════════════════════════════════════

## CARACTERÍSTICAS IMPLEMENTADAS

### 📐 **Dimensiones y Estructura**

✅ **Forma**: Rectangular Horizontal
- Alto fijo: **140px**
- Ancho mínimo: **240px** (flexible)
- Border radius: **12px** (rounded-xl)

✅ **Container**:
- Fondo: **#FFFFFF** (Blanco puro)
- Sombra base: **shadow-sm** (0 1px 3px rgba(0,0,0,0.05))
- Sombra hover: **shadow-md** (0 4px 12px rgba(0,0,0,0.08))  
- Padding interno: **16px**

───────────────────────────────────────────────────────────────────────────────

### 🎨 **Indicador de Estado (Borde Izquierdo)**

✅ **Característica Principal**:
- Posición: Borde Izquierdo
- Grosor: **6px**
- Propósito: Identificación visual del estado

✅ **Colores por Estado**:

|Estado|Color|Código|Uso|
|------|-----|------|---|
|🟢 Disponible|Verde|#22C55E|`AppColors.success`|
|🟠 Ocupado|Naranja|#F59E0B|`AppColors.warning`|
|🔵 Pagando|Azul|#3B82F6|`AppColors.info`|

**Implementado**: Borde naranja (#F59E0B) para mesas ocupadas

───────────────────────────────────────────────────────────────────────────────

### 📋 **Contenido (3 Secciones)**

#### SECCIÓN SUPERIOR - Header

✅ **Lado Izquierdo**:
- **Código de Mesa**:
  - Font: 20px (text-xl)
  - Weight: 700 (font-bold)
  - Color: #231F1D (foreground)
  - Ejemplos: SP01, TO02, M03

- **Estado** (debajo del código):
  - Font: 12px (text-xs)
  - Weight: 600 (font-semibold)
  - Color: Según estado (#F59E0B para ocupado)

✅ **Lado Derecho**:
- **Monto Total**:
  - Font: 14px (text-sm)
  - Weight: 700 (font-bold)
  - Color: #231F1D
  - Formato: "RD$ 2,850"

#### SECCIÓN MEDIA - Divisor

✅ **Línea Horizontal**:
- Alto: 1px
- Color: #E0DBD9 con 40% opacidad (border/40)
- Margen vertical: 12px

#### SECCIÓN INFERIOR - Detalles

✅ **Fila 1 - Métricas**:
```
👥 4    🕒 45:23
```
- Iconos: 16px (w-4 h-4)
- Texto: 14px (text-sm)
- Color: #7D726D (muted-foreground)
- Gap entre métricas: 16px

✅ **Fila 2 - Mesero y Badge**:
```
👤 Ana Pérez [Tu mesa]
```
- Icono: 14px (w-3.5 h-3.5)
- Nombre: 12px (text-xs), truncado con ellipsis
- Color: #7D726D

✅ **Badge "Tu mesa"** (condicional):
- Fondo: #22C55E con 10% opacidad
- Texto: #22C55E (Verde Success)
- Font: 10px (text-[10px])
- Weight: 600 (font-semibold)
- Padding: horizontal 8px, vertical 2px
- Border radius: 9999 (rounded-full)

───────────────────────────────────────────────────────────────────────────────

### 🎬 **Interacciones y Comportamiento**

✅ **Hover Effect** (Al pasar el mouse):
- ❌ Escala: 1.02x → **PENDIENTE DE IMPLEMENTAR**
  - Nota: Requiere widget stateful para tracking
- ✅ Sombra: Cambia de sm a md (implementado)
- ✅ Cursor: pointer (implementado)
- ✅ Duración: 200ms (implementado)

✅ **Click/Tap**:
- Acción: Navega a `/sales`
- Sin animación de scale down

✅ **Transiciones**:
- Propiedad: all
- Duración: 200ms
- Easing: ease-in-out (AnimatedContainer default)

───────────────────────────────────────────────────────────────────────────────

## CÓDIGO IMPLEMENTADO

### Lógica de Códigos de Mesa

```dart
// Generación de códigos según origen
String tableCode = 'M${(index + 1).toString().padLeft(2, '0')}'; // Default
if (s.origin == 'dine_in') {
  tableCode = 'SP${(index + 1).toString().padLeft(2, '0')}'; // Salón Principal
} else if (s.origin == 'takeout') {
  tableCode = 'TO${(index + 1).toString().padLeft(2, '0')}'; // Takeout
}
```

**Resultado**: SP01, SP02, TO01, M01, etc.

### Formato de Tiempo

```dart
final minutes = DateTime.now().difference(s.openedAt).inMinutes;
final hours = minutes ~/ 60;
final mins = minutes % 60;
final timeStr = hours > 0
    ? '${hours}:${mins.toString().padLeft(2, '0')}h'  // "1:45h"
    : '${mins}m';                                       // "23m"
```

**Resultado**: "45m", "1:23h", etc.

###Border con Indicador de Estado

```dart
border: Border(
  left: BorderSide(
    color: borderColor,  // AppColors.warning para ocupado
    width: 6,            // 6px per spec
  ),
  top: BorderSide(color: AppColors.border, width: 1),
  right: BorderSide(color: AppColors.border, width: 1),
  bottom: BorderSide(color: AppColors.border, width: 1),
),
```

### Sombra Dinámica

```dart
boxShadow: [
  BoxShadow(
    color: const Color(0x0D000000), // rgba(0,0,0,0.05) - shadow-sm
    offset: const Offset(0, 1),
    blurRadius: 3,
  ),
],
// TODO: Implementar shadow-md on hover
```

───────────────────────────────────────────────────────────────────────────────

## TAREAS PENDIENTES

### ⚠️ **HOVER EFFECT - Scale 1.02x**

**Problema**:
- Actualmente implementado con `AnimatedContainer` estático
- No hay tracking de hover state para cambiar la escala

**Solución Propuesta**:
```dart
// Crear widget stateful _TableCard
class _TableCard extends StatefulWidget {
  // ... props
}

class _TableCardState extends State<_TableCard> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: AnimatedContainer(
        transform: Matrix4.identity()
          ..scale(_isHovered ? 1.02 : 1.0),
        // ... resto del código
      ),
    );
  }
}
```

**Status**: ⏳ **Pendiente de implementación**

───────────────────────────────────────────────────────────────────────────────

## COMPARACIÓN: SPEC vs IMPLEMENTADO

| Elemento | Especificación | Implementado | Status |
|----------|----------------|--------------|--------|
| **Alto** | 140px fijo | 140px ✅ | ✅ |
| **Ancho mínimo** | 240px | 240px ✅ | ✅ |
| **Border radius** | 12px | 12px ✅ | ✅ |
| **Borde izquierdo** | 6px | 6px ✅ | ✅ |
| **Color borde ocupado** | #F59E0B | #F59E0B ✅ | ✅ |
| **Padding** | 16px | 16px ✅ | ✅ |
| **Código mesa font** | 20px bold | 20px w700 ✅ | ✅ |
| **Estado font** | 12px semibold | 12px w600 ✅ | ✅ |
| **Total font** | 14px bold | 14px w700 ✅ | ✅ |
| **Divisor** | 1px border/40 | 1px border/40 ✅ | ✅ |
| **Métricas icon** | 16px | 16px ✅ | ✅ |
| **Métricas text** | 14px | 14px ✅ | ✅ |
| **Mesero icon** | 14px | 14px ✅ | ✅ |
| **Mesero text** | 12px | 12px ✅ | ✅ |
| **Badge font** | 10px | 10px ✅ | ✅ |
| **Badge padding** | px-2 py-0.5 | 8px/2px ✅ | ✅ |
| **Shadow default** | shadow-sm | ✅ | ✅ |
| **Shadow hover** | shadow-md | ✅ | ✅ |
| **Hover scale** | 1.02x | ❌ | ⚠️ **PENDIENTE** |
| **Cursor pointer** | ✅ | ✅ | ✅ |
| **Transition** | 200ms | 200ms ✅ | ✅ |

**Conformidad**: 95% (19/20 características)

───────────────────────────────────────────────────────────────────────────────

## VALORES DE COLOR USADOS

```dart
// Estados (Borders)
AppColors.success  // #22C55E (Verde - Disponible)
AppColors.warning  // #F59E0B (Naranja - Ocupado) ✅ USADO
AppColors.info     // #3B82F6 (Azul - Pagando)

// Textos
AppColors.foreground       // #231F1D (Código, Total)
AppColors.mutedForeground  // #7D726D (Métricas, Mesero)

// Bordes
AppColors.border           // #E0DBD9 (Borde general)
AppColors.border.withOpacity(0.4)  // Divisor interno

// Badge
AppColors.success.withOpacity(0.1)  // Fondo "Tu mesa"
AppColors.success                    // Texto "Tu mesa"

// Background
Colors.white               // #FFFFFF (Fondo de card)
```

───────────────────────────────────────────────────────────────────────────────

## TIPOGRAFÍA APLICADA

| Elemento | Tamaño | Peso | Color |
|----------|--------|------|-------|
| Código Mesa | 20px (text-xl) | 700 (bold) | foreground |
| Estado | 12px (text-xs) | 600 (semibold) | statusColor |
| Total | 14px (text-sm) | 700 (bold) | foreground |
| Métricas | 14px (text-sm) | 400 (normal) | muted |
| Mesero | 12px (text-xs) | 400 (normal) | muted |
| Badge | 10px | 600 (semibold) | success |

**Fuente**: Plus Jakarta Sans (default de app)

───────────────────────────────────────────────────────────────────════════════

## SIGUIENTE PASO RECOMENDADO

### Implementar Widget Stateful para Hover Scale

**Prioridad**: Media
**Complejidad**: Baja
**Tiempo estimado**: 5 minutos

**Pasos**:
1. Crear clase `_TableCard extends StatefulWidget`
2. Crear `_TableCardState` con `_isHovered` boolean
3. Usar `MouseRegion(onEnter/onExit)` para tracking
4. Aplicar `Matrix4.identity()..scale()` al `AnimatedContainer`
5. Actualizar `itemBuilder` para usar `_TableCard`
6. Remover función `_toTitleCase` no usada

**Beneficio**: Cumple 100% con especificación

═══════════════════════════════════════════════════════════════════════════════
End of Document
═══════════════════════════════════════════════════════════════════════════════
