# Dashboard Implementation & Design Specs (v2)

## ✅ Implementation Status
The Dashboard has been refactored to strictly follow the "Soft UI" design specifications and the new 3-tier responsive rules.

### 1. Viewport & Breakpoints Strategy
We use `LayoutBuilder` to determine the layout mode based on `maxWidth`:

| Mode | Range | Layout Strategy |
|------|-------|-----------------|
| **Mobile** | < 600px | **Column** (Stacked). `WelcomeCard` in vertical mode. `QuickActions` in 2 columns. |
| **Tablet Portrait** | 600px - 900px | **Column** (Stacked) with wider padding (32px). `WelcomeCard` in Horizontal mode. `QuickActions` in 4 columns. |
| **Desktop Landscape** | > 900px | **Row** (Split View). Left Column (66%) + Right Column (33%). `WelcomeCard` uses Horizontal mode. |

### 2. Component Design Details

#### A. Welcome Card
- **Style**: White card, minimal gradient (5% Orange) in top-left.
- **Responsiveness**:
  - **Mobile**: Stacked layout (Text top, Actions bottom).
  - **Tablet/Desktop**: Row layout (Text left, Actions right).
- **Decoration**: Rounded corners (12px), subtle shadow.

#### B. Quick Actions
- **Alignment**: **Left-aligned** text and icons.
- **Grid**:
  - **Mobile (<600)**: 2 Columns.
  - **Desktop (>=600)**: 4 Columns.
- **Style**: Pastel colored icon boxes (10% opacity) with centered icons.

#### C. Top Navigation (Header)
- **Breakpoint**: 1024px.
- **Behavior**:
  - **< 1024px**: Icons Only.
  - **>= 1024px**: Icons + Text Labels.

#### D. Active Tables Sidebar
- **Location**:
  - **Desktop**: Right Sidebar (Fixed width ratio).
  - **Mobile/Tablet**: Bottom of the page (Full width).
- **Style**: Warning yellow badge, grey list items.

### 3. Styling & Colors
- **Primary**: `AppColors.primary` (Orange #FB7116).
- **Background**: `AppColors.background` (Soft Cream #FAF9F7).
- **Font**: "Plus Jakarta Sans" (Defined in `AppTypography`).

## 🛠 Usage Notes
- The logic is centralized in `DashboardView.build` using a `LayoutBuilder`.
- Breakpoint constants:
  - `600`: Mobile/Tablet boundary.
  - `900`: Tablet/Desktop boundary.
  - `1024`: Nav Bar Text boundary.
