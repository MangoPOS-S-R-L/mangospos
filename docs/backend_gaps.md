# Backend Gaps & Mismatches - Sales Module

During the implementation of the Sales Module UI (Table Order Screen), the following gaps between the UI Specification and the current Backend/Schema were identified:

## 1. Product Modifiers System
- **UI Spec**: Requires complex customization including "Mandatory Options" (Radio) and "Optional Extras" (Checkbox) with specific pricing.
- **Current State**: `MenuProduct` only has basic fields (name, price, image). No relation to a modifiers table found in `menu_browser_viewmodel.dart` or `sales_models.dart`.
- **Impact**: The `ProductCustomizationModal` is implemented with mock data. Real data integration is blocked.
- **Recommendation**: Create `menu_modifiers`, `menu_modifier_groups`, and `menu_product_modifiers` tables.

## 2. Structured Order Items (Modifiers)
- **UI Spec**: Cart should display selected modifiers (e.g. "Sin cebolla", "Queso Extra +$25").
- **Current State**: `OrderItem` only supports a single String `notes` field.
- **Impact**: Cannot store or display structured modifiers in the cart or sent to kitchen properly.
- **Recommendation**: Add `jsonb identifiers` or a separate `order_item_modifiers` table.

## 3. Tax Calculation
- **UI Spec**: Explicit "ITBIS (18%)" breakdown.
- **Current State**: Frontend calculates this as `total / 1.18`.
- **Recommendation**: Standardize tax configuration in `business_settings` or `tax_rates` table to avoid hardcoding "18%" in the mobile app.

## 4. Customer Assignment
- **UI Spec**: "Asignar Cliente" button in catalog header.
- **Current State**: `orders` table supports `customer_id`, but we lack a dedicated endpoint/viewmodel method to search and link a customer to an *open* order easily within the POS view.
- **Action**: Need `CustomerService` integration in Sales module.

## 5. Table Management
- **UI Spec**: "Mesa SP01" display.
- **Current State**: We have `tableId` and `tableCode`, but need to ensure `dining_tables` updates status (occupied/available) correctly when `openTable` is called.

## 6. Offline Support
- **UI Spec**: Implied by POS reliability.
- **Current State**: Direct Supabase calls. Need to consider offline strategy (Hive/SQLite) for critical sales path if internet drops.
