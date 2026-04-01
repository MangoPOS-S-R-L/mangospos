# CLAUDE.md

This file gives Claude Code the minimum context needed to work safely inside `mangospos`.

## Project Identity

`mangospos` is the main Flutter POS app for MangoPOS.
It is not just a dashboard.
It includes POS/cashier flows, auth, dashboard, sales, products, inventory, kitchen/KDS, printing, reports, settings, multi-platform support, and local agent/printer integration.

## First Rules

- Read the existing structure before editing.
- Prefer small, compatible changes.
- Do not invent new architecture if an existing pattern already exists nearby.
- Do not modify databases unless explicitly requested.
- Before major refactors, inspect the feature module end-to-end first.
- If a task is feature-specific, work inside that module instead of spreading logic across unrelated folders.

## Important Commands

```bash
# dependencies
flutter pub get

# analyze whole app
flutter analyze

# run tests
flutter test

# run web
flutter run -d chrome

# run macOS
flutter run -d macos

# run specific area if needed
flutter analyze lib/presentation/cashier test/cashier
```

## High-Level Structure

### App bootstrap
- `lib/main.dart`
  - app startup
  - Supabase init
  - printer agent startup
  - auth recovery handling
  - route bootstrap

### App shell / navigation / theme
- `lib/app/router/`
- `lib/app/theme/`
- `lib/app/widgets/`
- `lib/app/di/`

### Core shared infrastructure
- `lib/core/auth/`
- `lib/core/business/`
- `lib/core/cache/`
- `lib/core/config/`
- `lib/core/network/`
- `lib/core/offline/`
- `lib/core/printing/`
- `lib/core/security/`
- `lib/core/services/`
- `lib/core/storage/`
- `lib/core/tenant/`
- `lib/core/theme/`
- `lib/core/utils/`

### Data layer
- `lib/data/datasources/`
- `lib/data/models/`
- `lib/data/repositories/`
- `lib/data/utils/`

### Domain layer
- `lib/domain/models/`
- `lib/domain/repositories/`
- `lib/domain/usecases/`

### Presentation layer by feature
- `lib/presentation/auth/`
- `lib/presentation/branches/`
- `lib/presentation/cashier/`
- `lib/presentation/customers/`
- `lib/presentation/dashboard/`
- `lib/presentation/inventory/`
- `lib/presentation/kds/`
- `lib/presentation/kitchen/`
- `lib/presentation/payments/`
- `lib/presentation/printing/`
- `lib/presentation/products/`
- `lib/presentation/promos/`
- `lib/presentation/purchases/`
- `lib/presentation/reports/`
- `lib/presentation/sales/`
- `lib/presentation/settings/`
- `lib/presentation/shell/`
- `lib/presentation/split_bill/`
- `lib/presentation/tickets_billing/`

### Environment / support
- `lib/env/`
- `lib/services/`
- `agent/`
- `supabase/`
- `docs/`
- `scripts/`
- `test/`

## Existing Technical Signals

From `pubspec.yaml`, this app already relies on:
- `flutter_riverpod`
- `go_router`
- `supabase_flutter`
- `shared_preferences`
- `fl_chart`
- `video_player`
- `media_kit`
- printing / PDF / ESC-POS related packages
- BLE/network/printer/device packages

That means before adding new dependencies, check whether the app already has an existing way to solve the problem.

## Architecture Guidance

This repo is large and mixed. Do not assume every folder follows one perfectly enforced pattern.
Instead:
- inspect the nearest feature first
- follow local conventions where possible
- keep changes bounded to the feature you are touching

When implementing something new:
1. locate the feature module
2. trace router → screen/view → state/viewmodel/provider → repository → datasource/model
3. mirror the existing path instead of inventing a parallel stack

## Sensitive Areas

Be extra careful in these areas:
- `lib/main.dart`
- auth/session recovery
- printing services
- cashier flow
- payments
- tenant/business scoping
- router guards

Changes there can break large parts of the app.

## Working Style Expectations

When doing code work here:
- prefer exact fixes over broad cleanup
- preserve current behavior unless the task says otherwise
- avoid touching multiple unrelated modules in one pass
- if a file is already very large, avoid making it worse unless the task is specifically a refactor
- mention risks if changing auth, routing, cashier, printing, or tenant logic

## Good Task Breakdown for This Repo

If a task is large, split it by role like this:
- architecture/navigation
- UI/UX
- data/query logic
- auth/roles/guards
- QA/fixes

## Notes

- This repo already contains lots of docs and historical notes at root level. Use them when relevant, but treat the code as source of truth.
- `README_CIERRE_CAJA_FLUTTER.md` is specifically useful for cashier close flow work.
- There is local agent/printer integration under `agent/` and startup logic in `lib/main.dart`.

## Default Goal

Make precise, production-safe improvements to MangoPOS without breaking cashier, auth, printing, business scoping, or routing.
