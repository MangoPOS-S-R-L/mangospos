import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangopos/core/business/retail_profile_defaults.dart';
import 'package:mangopos/data/repositories/pos_settings_repository.dart';
import 'package:mangopos/env/supabase_flutter.dart';
import 'package:mangopos/presentation/auth/register/register_step1_viewmodel.dart';
import 'package:mangopos/services/session/session_controller.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'register_step2_state.dart';

class RegisterSubmitResult {
  final bool requiresEmailConfirmation;
  final String message;

  const RegisterSubmitResult({
    required this.requiresEmailConfirmation,
    required this.message,
  });
}

class RegisterStep2ViewModel extends Notifier<RegisterStep2State> {
  @override
  RegisterStep2State build() => const RegisterStep2State();

  void setBusinessName(String v) => _safeSet(state.copyWith(businessName: v));
  void setBranch(String v) => _safeSet(state.copyWith(branchName: v));
  void setBusinessType(String v) => _safeSet(state.copyWith(businessType: v));
  void setCountry(String v) => _safeSet(state.copyWith(country: v));
  void setAddress(String v) => _safeSet(state.copyWith(address: v));
  void setPhone(String v) => _safeSet(state.copyWith(phone: v));
  void setSubdomain(String v) => _safeSet(state.copyWith(subdomain: v));
  void setConsentGranted(bool v) => _safeSet(state.copyWith(consentGranted: v));

  void _safeSet(RegisterStep2State next) {
    if (state == next) return;
    final binding = WidgetsBinding.instance;
    if (binding.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      binding.addPostFrameCallback((_) => state = next);
    } else {
      state = next;
    }
  }

  /// Ejecuta el bootstrap completo (signUp → profile → business → membership).
  ///
  /// Si el correo ya tiene una cuenta auth (usuario huérfano sin business, o
  /// dueño existente queriendo crear un negocio adicional), pedimos un código
  /// OTP por correo en vez de validar la contraseña. Esto resuelve el caso
  /// del usuario que no recuerda su contraseña vieja pero sí tiene acceso a
  /// su email, sin abrir un hueco de seguridad (cualquiera podría secuestrar
  /// cuentas si saltáramos toda verificación).
  ///
  /// El caller pasa `requestOtp(email)` — una función async que abre un
  /// modal en la UI pidiendo el código, y devuelve el código tipeado (o
  /// `null` si el usuario cancela). El viewmodel no construye UI; solo
  /// orquesta el flujo y espera.
  Future<RegisterSubmitResult> submitAll({
    Future<String?> Function(String email)? requestOtp,
  }) async {
    final supabase = SupabaseConfig.client;

    try {
      final step1 = ref.read(registerStep1VmProvider);
      final step2 = state;

      if ((step1.email ?? '').trim().isEmpty ||
          (step1.password ?? '').isEmpty) {
        throw Exception('Faltan correo o contraseña. Regresa al paso 1.');
      }
      if (step2.businessName.trim().isEmpty) {
        throw Exception('Falta el nombre del negocio. Regresa al paso 2.');
      }
      if (step1.selectedPlanId == null) {
        throw Exception('No has seleccionado un plan. Regresa al paso 1.');
      }
      if (!step2.consentGranted) {
        throw Exception(
          'Para crear tu cuenta debes aceptar el consentimiento de cobro recurrente.',
        );
      }


      // 1. Auth: signUp con flujo de recovery para usuarios huérfanos.
      //
      // Bug histórico: si el primer intento creaba auth.users pero
      // fallaba en pasos posteriores (insert de business, etc.), el
      // usuario quedaba huérfano. Reintentar el form lanzaba "ya
      // existe una cuenta" sin opción de continuar el bootstrap.
      //
      // Fix: cuando signUp detecta "user_already_exists", probamos
      // signInWithPassword con el mismo password ingresado. Si funciona
      // y el user NO tiene business asociado, completamos el bootstrap
      // (recovery del huérfano). Si funciona y SÍ tiene business, la
      // cuenta ya está completa → cerrar sesión recién abierta y
      // mandar al login.
      String userId;
      Session? session;

      AuthResponse? signUpResp;
      try {
        signUpResp = await supabase.auth.signUp(
          email: step1.email!,
          password: step1.password!,
          emailRedirectTo: 'https://app.mangopos.do/auth/callback',
        );
      } on AuthException catch (e) {
        if (!_isAlreadyRegisteredError(e)) {
          throw Exception(_friendlyAuthError(e));
        }
        // user_already_exists → intentar recovery
        signUpResp = null;
      }

      if (signUpResp != null) {
        // Path normal: signUp exitoso
        session = signUpResp.session ?? supabase.auth.currentSession;
        final user =
            signUpResp.user ?? session?.user ?? supabase.auth.currentUser;
        if (user == null) {
          throw Exception(
            'No se pudo crear la cuenta. Verifica tu correo y contraseña e intenta de nuevo.',
          );
        }
        userId = user.id;
      } else {
        // Path recovery: usuario ya existe. En vez de pedir el password
        // (que el usuario probablemente no recuerda), enviamos un OTP al
        // email para confirmar que es realmente el dueño del correo.
        //
        // Sin esto, un usuario que olvidó su password pero quiere crear
        // un negocio nuevo quedaba bloqueado con "contraseña no coincide".
        // Y si simplemente saltáramos la verificación, cualquiera podría
        // crear un business bajo el email de otra persona conociendo
        // solo el correo — secuestro de cuenta trivial.
        if (requestOtp == null) {
          throw Exception(
            'Ese correo ya tiene una cuenta. Vuelve a intentarlo o inicia '
            'sesión desde la pantalla principal.',
          );
        }

        // 1) Disparar envío del OTP. `shouldCreateUser: false` evita que
        //    Supabase cree un user nuevo si por alguna razón el email
        //    desapareció — queremos solo recovery, no signup encubierto.
        try {
          await supabase.auth.signInWithOtp(
            email: step1.email!,
            shouldCreateUser: false,
          );
        } on AuthException catch (e) {
          throw Exception(
            'No pudimos enviar el código de verificación: ${_friendlyAuthError(e)}',
          );
        }

        // 2) Esperar a que la UI muestre el modal y devuelva el código.
        final code = (await requestOtp(step1.email!))?.trim();
        if (code == null || code.isEmpty) {
          throw Exception('Verificación de correo cancelada.');
        }

        // 3) Verificar el OTP → autentica como el usuario existente.
        final AuthResponse otpResp;
        try {
          otpResp = await supabase.auth.verifyOTP(
            type: OtpType.email,
            token: code,
            email: step1.email!,
          );
        } on AuthException catch (e) {
          throw Exception(
            'Código inválido o expirado: ${_friendlyAuthError(e)}',
          );
        }

        session = otpResp.session ?? supabase.auth.currentSession;
        final user = otpResp.user ?? session?.user;
        if (user == null) {
          throw Exception(
            'No se pudo recuperar la cuenta tras verificar el código. '
            'Intenta iniciar sesión desde la pantalla principal.',
          );
        }
        userId = user.id;

        // Validar si la cuenta ya está completa (tiene business).
        // Si sí → no estamos recuperando un huérfano, el usuario
        // simplemente está intentando registrarse con un email que ya
        // tiene cuenta activa.
        try {
          final existingBiz = await supabase
              .from('businesses')
              .select('id')
              .eq('owner_id', userId)
              .limit(1)
              .maybeSingle();
          if (existingBiz != null) {
            // Cerrar la sesión que acabamos de abrir — no es nuestro flow.
            await supabase.auth.signOut();
            throw Exception(
              'Esta cuenta ya está registrada y activa. '
              'Inicia sesión desde la pantalla principal en lugar de crear una nueva.',
            );
          }
        } on PostgrestException catch (e) {
          throw Exception(
            'No se pudo verificar el estado de la cuenta: ${_friendlyDbError(e)}',
          );
        }
        // Si no había business, caemos al bootstrap normal abajo
        // (profile upsert + business insert + membership insert).
      }

      // 2. Create profile
      try {
        await supabase.from('profiles').upsert({
          'id': userId,
          'email': step1.email,
          'full_name': step1.fullName,
          'created_at': DateTime.now().toIso8601String(),
          'updated_at': DateTime.now().toIso8601String(),
        });
      } on PostgrestException catch (e) {
        throw Exception('Error creando tu perfil: ${_friendlyDbError(e)}');
      }

      // 3. Create business
      //
      // El identificador real de la cuenta es el email del owner. El
      // subdominio es solo infra: si el slug elegido ya existe en la
      // tabla `businesses` (unique index `uq_businesses_domain_lower`),
      // reintentamos con sufijo `-2`, `-3`, ... en lugar de bloquear el
      // registro.
      var slug = step2.subdomain.trim().toLowerCase();
      if (slug.isEmpty) {
        slug = step2.businessName
            .toLowerCase()
            .replaceAll(RegExp(r'[^a-z0-9]'), '-')
            .replaceAll(RegExp(r'-+'), '-')
            .trim();
        if (slug.endsWith('-')) slug = slug.substring(0, slug.length - 1);
        if (slug.isEmpty) slug = 'negocio';
      }

      final business = await _insertBusinessWithUniqueDomain(
        supabase: supabase,
        baseSlug: slug,
        userId: userId,
        step2: step2,
      );

      // R0 retail: si el tipo de negocio es retail, sembramos el preset de
      // feature flags (mostrador, sin mesas/cocina, con escaneo e inventario
      // básico) en business_settings. Best-effort: un fallo aquí NO debe
      // abortar el registro — la configuración no es crítica para crear la
      // cuenta y el dueño puede ajustarla luego en Ajustes. Tipos no-retail
      // devuelven null y conservan los defaults legacy (todo prendido).
      final retailPreset =
          RetailProfileDefaults.forBusinessType(step2.businessType);
      if (retailPreset != null) {
        try {
          await PosSettingsRepository(supabase).setBusinessFeatures(
            businessId: business['id'] as String,
            features: retailPreset,
          );
        } catch (_) {
          // Configuración no crítica: el registro continúa.
        }
      }

      // 4. Fetch plan info para calcular trial_days reales (PRD-Azul §5.1).
      //    Si por alguna razón el plan fue desactivado entre Step 1 y Step 3,
      //    fallamos con mensaje claro en vez de crear membership huérfana.
      final selectedPlanId = step1.selectedPlanId!;
      final Map<String, dynamic>? planRow;
      try {
        planRow = await supabase
            .from('plans')
            .select('id, trial_days, code')
            .eq('id', selectedPlanId)
            .maybeSingle();
      } on PostgrestException catch (e) {
        throw Exception(
            'No se pudo cargar el plan seleccionado: ${_friendlyDbError(e)}');
      }
      if (planRow == null) {
        throw Exception(
          'El plan seleccionado ya no está disponible. Vuelve al paso 1 y elige otro.',
        );
      }
      final trialDays = (planRow['trial_days'] as num?)?.toInt() ?? 14;

      // 5. Create membership (PRD-Azul-Subscriptions §5.5).
      //    Esta es la membership ANCHOR del business — la que carga el estado
      //    de billing para el cron Azul. Setea TODAS las columnas billing.
      final businessId = business['id'] as String;
      final normalizedPlan = _resolveMembershipPlan(step1.selectedPlan);
      final now = DateTime.now();
      final trialEndsAt = now.add(Duration(days: trialDays));
      final nextBillingDate = trialEndsAt.add(const Duration(days: 1));
      final periodStartDate = _toDateOnly(now);
      final periodEndDate = _toDateOnly(trialEndsAt);
      final nextBillingDateOnly = _toDateOnly(nextBillingDate);

      try {
        await supabase.from('memberships').insert({
          // Identidad
          'user_id': userId,
          'business_id': businessId,

          // Membership legacy (intactos para compat)
          'plan_type': normalizedPlan,
          'status': 'active',
          'start_date': now.toIso8601String(),
          'end_date': trialEndsAt.toIso8601String(),
          'created_at': now.toIso8601String(),
          'role': 'owner', // Antes quedaba en default 'staff' — bug histórico.

          // Billing (PRD-Azul-Subscriptions §5.5)
          'plan_id': selectedPlanId,
          'is_billing_anchor': true,
          'billing_status': 'trial',
          'trial_ends_at': trialEndsAt.toIso8601String(),
          'current_period_start': periodStartDate,
          'current_period_end': periodEndDate,
          'next_billing_date': nextBillingDateOnly,
          'consent_granted_at': now.toIso8601String(),
        });
      } on PostgrestException catch (e) {
        throw Exception(
            'Error activando la membresía: ${_friendlyDbError(e)}');
      }

      // 5. Restore session and redirect
      if (session != null) {
        await ref.read(sessionProvider.notifier).restoreFromSupabaseSession();
        return const RegisterSubmitResult(
          requiresEmailConfirmation: false,
          message:
              'Cuenta creada exitosamente. En unos segundos entrarás al panel principal.',
        );
      }

      return const RegisterSubmitResult(
        requiresEmailConfirmation: true,
        message:
            'Cuenta creada exitosamente. Revisa tu correo para confirmar tu cuenta y luego inicia sesión.',
      );
    } on Exception {
      rethrow;
    } catch (e) {
      throw Exception(
        'Ocurrió un error inesperado. Verifica tu conexión a internet e intenta de nuevo.',
      );
    }
  }

  /// Inserta el `businesses` row asegurando un `domain` único: si el slug
  /// base choca con `uq_businesses_domain_lower` (23505), reintenta con
  /// sufijos `-2`, `-3`, ... hasta `attempts` veces. Cualquier otro error
  /// se propaga como `Exception` con mensaje amigable.
  Future<Map<String, dynamic>> _insertBusinessWithUniqueDomain({
    required SupabaseClient supabase,
    required String baseSlug,
    required String userId,
    required RegisterStep2State step2,
    int attempts = 8,
  }) async {
    final now = DateTime.now().toIso8601String();
    final branchName = step2.branchName.trim().isEmpty
        ? 'Sucursal Principal'
        : step2.branchName.trim();
    final phone = step2.phone.trim().isEmpty ? null : step2.phone.trim();

    for (var i = 0; i < attempts; i++) {
      final slug = i == 0 ? baseSlug : '$baseSlug-${i + 1}';
      final domain = '$slug.mangopos.do';
      try {
        return await supabase
            .from('businesses')
            .insert({
              'owner_id': userId,
              'business_name': step2.businessName,
              'branch_name': branchName,
              'business_type': step2.businessType,
              'country': step2.country,
              'address': step2.address,
              'phone': phone,
              'domain': domain,
              // Cuentas NUEVAS nacen pendientes — el equipo interno las
              // aprueba desde Mango Administrador (cambio política
              // 2026-05-27). PendingApprovalGuard bloquea la app hasta
              // que el status pase a 'active'. Las cuentas LEGACY ya
              // creadas antes de esta migration siguen como 'active' —
              // no se las toca; el admin puede pasarlas a inactive si
              // hace falta. Ver migration 20260527_0005_businesses_status_pending.sql.
              'status': 'pending',
              'created_at': now,
              'updated_at': now,
            })
            .select('id')
            .single();
      } on PostgrestException catch (e) {
        final isDomainCollision = e.code == '23505' &&
            e.message.toLowerCase().contains('domain');
        if (isDomainCollision && i < attempts - 1) {
          continue;
        }
        throw Exception('Error creando el negocio: ${_friendlyDbError(e)}');
      }
    }
    throw Exception(
      'No se pudo generar un subdominio disponible después de $attempts intentos. Intenta de nuevo en unos segundos.',
    );
  }

  /// `true` si el AuthException representa "user_already_exists" en
  /// cualquiera de las variantes que devuelve Supabase Auth (mensajes han
  /// cambiado entre versiones — cubrimos las 3 conocidas).
  bool _isAlreadyRegisteredError(AuthException e) {
    final msg = e.message.toLowerCase();
    return msg.contains('already registered') ||
        msg.contains('already been registered') ||
        msg.contains('user_already_exists');
  }

  String _friendlyAuthError(AuthException e) {
    final msg = e.message.toLowerCase();
    if (_isAlreadyRegisteredError(e)) {
      return 'Ya existe una cuenta con este correo electrónico. Intenta iniciar sesión o usa otro correo.';
    }
    if (msg.contains('invalid') && msg.contains('email')) {
      return 'El formato del correo electrónico no es válido.';
    }
    if (msg.contains('weak') || msg.contains('password')) {
      return 'La contraseña es muy débil. Usa al menos 8 caracteres con una mayúscula y un número.';
    }
    if (msg.contains('security purposes') ||
        (msg.contains('after') && msg.contains('seconds'))) {
      return 'Demasiados intentos. Espera unos segundos antes de intentar de nuevo.';
    }
    if (msg.contains('network') ||
        msg.contains('socket') ||
        msg.contains('timeout')) {
      return 'Error de conexión. Verifica tu internet e intenta de nuevo.';
    }
    return 'Error de autenticación: ${e.message}';
  }

  String _friendlyDbError(PostgrestException e) {
    final msg = e.message.toLowerCase();
    final code = e.code;
    if (code == '23505') {
      if (msg.contains('email')) {
        return 'Ya existe una cuenta con este correo.';
      }
      if (msg.contains('business_name') || msg.contains('domain')) {
        return 'Ya existe un negocio con ese nombre.';
      }
      return 'Ya existe un registro con estos datos.';
    }
    if (code == '23503') {
      return 'Referencia inválida. Intenta de nuevo.';
    }
    if (code == '42501') {
      return 'No tienes permisos para esta operación.';
    }
    if (msg.contains('timeout') || msg.contains('57014')) {
      return 'La operación tardó demasiado. Intenta de nuevo.';
    }
    return e.message;
  }

  String buildDomainPreview() {
    return 'app.mangopos.do';
  }

  /// Convierte un DateTime a string `YYYY-MM-DD` para columnas `date` de
  /// Postgres (current_period_start/end, next_billing_date). Postgres acepta
  /// el timestamp completo en `date` pero descarta la hora — esto es más
  /// explícito y evita timezone weirdness.
  String _toDateOnly(DateTime dt) {
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  String _resolveMembershipPlan(String? rawPlan) {
    const allowedPlans = {'starter', 'pro', 'enterprise', 'trial'};
    final normalized = rawPlan?.trim().toLowerCase();
    if (normalized != null && allowedPlans.contains(normalized)) {
      return normalized;
    }
    return 'starter';
  }
}

final registerStep2VmProvider =
    NotifierProvider<RegisterStep2ViewModel, RegisterStep2State>(
      RegisterStep2ViewModel.new,
    );
