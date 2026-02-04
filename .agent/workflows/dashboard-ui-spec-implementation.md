---
description: Implementar Dashboard según UI Specification
---

# Dashboard UI Spec Implementation Plan

Basado en: `UI/DASHBOARD.TXT` v2.0

## Fase 1: Theme Tokens ✅ (Ya existentes en app_colors.dart)
- [ ] Ver

ificar colores exactos:
  - background: #FAF9F7
  - primary: #FB7116 
  - foreground: #231F1D
  - muted: #7D726D
  - border: #E0DBD9
- [ ] Actualizar primaryGradientEnd a #FBAA16

## Fase 2: Actualizar dashboard_view.dart

### 2.1 Welcome Card
- [ ] Agregar gradiente sutil en esquina superior derecha (5% opacity)
- [ ] TODO alineado a izquierda (text-left)
- [ ] Chips con bg-secondary border-border
- [ ] Botón "Aperturar" con gradiente mango + shadow
- [ ] Fecha en uppercase tracking-wide
- [ ] Badge "Caja Cerrada" con punto pulsante

### 2.2 Quick Actions
- [ ] 4 Small Action Cards (2 cols mobile, 4 cols desktop)
  - Ventas (primary)
  - Productos (info)
  - Clientes (success)
  - Report

es (warning)
- [ ] Min height: 110px
- [ ] Icon container: 48x48px con color/10 opacity
- [ ] Hover: scale icon 1.1x, lift card -4px
- [ ] 2 Large Action Buttons
  - Nueva Venta: gradient mango + arrow icon
  - Delivery: white card con badge "4 en ruta"

### 2.3 Sales Chart
- [ ] Header con título + filter tabs
- [ ] 3 Metric boxes con:
  - Uppercase labels tracking-wide
  - Font-black números tabular-nums
  - Trending icons
- [ ] Chart FL_CHART:
  - Smooth monotone curve
  - Orange gradient fill
  - Horizontal grid only (dashed)
  - No dots (solo activeDot en hover)

### 2.4 Active Tables Widget
- [ ] Sticky en desktop (top-20)
- [ ] Table items con bg-secondary/50
- [ ] Icon container: 44x44px gradient mango
- [ ] Max height: 600px con scroll

## Fase 3: Responsive Breakpoints
- Mobile (<768px): 1 col, 2 quick actions
- Tablet (768-1024px): 1 col, 4 quick actions  
- Desktop XL (≥1280px): 2:1 grid (main:sidebar)

## Cambios Críticos
1. **ALINEACIÓN IZQUIERDA EN TODO** - No centrar nada
2. **Alto contraste** - Usar foreground (#231F1D) no gris
3. **Gradiente mango** - Siempre de #FB7116 a #FBAA16
4. **Sombras soft** - Específicas del spec
5. **Plus Jakarta Sans** - Ya está configurado
