// Pantalla "Mi cuenta" para propietarios.
//
// Muestra info de identidad + PIN de acceso (visible) + botón cambiarlo.
// Si el owner todavía no tenía employee record en la BD, [OwnerProfileRepository]
// lo materializa on-demand al cargar la pantalla por primera vez (con un PIN
// inicial random de 4 dígitos que el owner puede ver y cambiar).
//
// Visibilidad: la entrada solo aparece en el menu Settings si
// sessionProvider.isOwner == true; igual hacemos un check defensivo en el
// build por si alguien navega directo por URL.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../app/theme/mango_colors.dart';
import '../../../data/models/owner_profile.dart';
import '../../../data/repositories/owner_profile_repository.dart';
import '../../../services/session/session_controller.dart';

class MyAccountScreen extends ConsumerStatefulWidget {
  const MyAccountScreen({super.key});

  @override
  ConsumerState<MyAccountScreen> createState() => _MyAccountScreenState();
}

class _MyAccountScreenState extends ConsumerState<MyAccountScreen> {
  late Future<OwnerProfile> _future;
  bool _pinRevealed = false;

  @override
  void initState() {
    super.initState();
    _future = _loadProfile();
  }

  Future<OwnerProfile> _loadProfile() {
    final session = ref.read(sessionProvider);
    final userId = session.userId;
    final businessId = session.activeBusinessId;
    if (userId == null || businessId == null) {
      return Future.error(
        StateError('Necesitas estar dentro de un negocio para ver tu cuenta.'),
      );
    }
    return ref
        .read(ownerProfileRepositoryProvider)
        .getOrCreateOwnerProfile(userId: userId, businessId: businessId);
  }

  void _reload() {
    setState(() {
      _future = _loadProfile();
      _pinRevealed = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    if (!session.isOwner) {
      return _NotOwnerScaffold();
    }

    return Scaffold(
      backgroundColor: MangoColors.bgLight,
      appBar: AppBar(
        title: const Text('Mi cuenta'),
        backgroundColor: MangoColors.white,
        foregroundColor: MangoColors.darkGray,
        elevation: 0,
        scrolledUnderElevation: 1,
      ),
      body: FutureBuilder<OwnerProfile>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return _ErrorView(
              message: snap.error.toString(),
              onRetry: _reload,
            );
          }
          final profile = snap.data!;
          return RefreshIndicator(
            onRefresh: () async => _reload(),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 48),
              children: [
                _IdentityCard(
                  profile: profile,
                  onEditName: () => _openEditNameDialog(profile),
                ),
                const SizedBox(height: 16),
                _PinCard(
                  profile: profile,
                  revealed: _pinRevealed,
                  onToggleReveal: () =>
                      setState(() => _pinRevealed = !_pinRevealed),
                  onChangePin: () => _openChangePinDialog(profile),
                ),
                const SizedBox(height: 16),
                _BusinessCard(profile: profile),
                const SizedBox(height: 16),
                _MetadataCard(profile: profile),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _openChangePinDialog(OwnerProfile profile) async {
    final result = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ChangePinDialog(currentPin: profile.pin),
    );
    if (result == null || !mounted) return;
    try {
      await ref
          .read(ownerProfileRepositoryProvider)
          .updatePin(employeeId: profile.employeeId, newPin: result);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('PIN actualizado correctamente.')),
      );
      _reload();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No se pudo actualizar: $e')),
      );
    }
  }

  Future<void> _openEditNameDialog(OwnerProfile profile) async {
    final result = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _EditNameDialog(currentName: profile.fullName),
    );
    if (result == null || !mounted) return;
    try {
      await ref.read(ownerProfileRepositoryProvider).updateFullName(
            userId: profile.userId,
            employeeId: profile.employeeId,
            fullName: result,
          );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Nombre actualizado.')),
      );
      _reload();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No se pudo actualizar: $e')),
      );
    }
  }
}

// =============================================================================
// Cards
// =============================================================================

class _CardFrame extends StatelessWidget {
  final Widget child;
  const _CardFrame({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: MangoColors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: MangoColors.cardBorder),
      ),
      child: child,
    );
  }
}

class _IdentityCard extends StatelessWidget {
  final OwnerProfile profile;
  final VoidCallback onEditName;
  const _IdentityCard({required this.profile, required this.onEditName});

  @override
  Widget build(BuildContext context) {
    final initials = _initialsFrom(profile.fullName);
    return _CardFrame(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 64,
            height: 64,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: MangoColors.primaryOrange.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(32),
            ),
            child: Text(
              initials,
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                color: MangoColors.primaryOrange,
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        profile.fullName,
                        style: const TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.w800,
                          color: MangoColors.darkGray,
                        ),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: onEditName,
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      label: const Text('Editar'),
                      style: TextButton.styleFrom(
                        foregroundColor: MangoColors.primaryOrange,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  profile.email,
                  style: const TextStyle(
                    fontSize: 13,
                    color: MangoColors.muted,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF7F1),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Text(
                    'Propietario',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      color: MangoColors.primaryOrange,
                      letterSpacing: 0.3,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _initialsFrom(String full) {
    final parts =
        full.trim().split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first[0].toUpperCase();
    return (parts.first[0] + parts[1][0]).toUpperCase();
  }
}

class _PinCard extends StatelessWidget {
  final OwnerProfile profile;
  final bool revealed;
  final VoidCallback onToggleReveal;
  final VoidCallback onChangePin;

  const _PinCard({
    required this.profile,
    required this.revealed,
    required this.onToggleReveal,
    required this.onChangePin,
  });

  @override
  Widget build(BuildContext context) {
    final display = revealed ? profile.pin : '••••';
    return _CardFrame(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.lock_outline_rounded,
                  size: 20, color: MangoColors.darkGray),
              const SizedBox(width: 8),
              const Text(
                'PIN de acceso',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  color: MangoColors.darkGray,
                ),
              ),
              const Spacer(),
              IconButton(
                tooltip: revealed ? 'Ocultar' : 'Mostrar',
                onPressed: onToggleReveal,
                icon: Icon(
                  revealed
                      ? Icons.visibility_off_rounded
                      : Icons.visibility_rounded,
                  color: MangoColors.muted,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            'Lo usas para el login offline y para acciones que pidan confirmación rápida.',
            style: TextStyle(fontSize: 12, color: MangoColors.muted, height: 1.4),
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
            decoration: BoxDecoration(
              color: MangoColors.bgLight,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: MangoColors.cardBorder),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    display,
                    style: const TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w900,
                      color: MangoColors.darkGray,
                      letterSpacing: 8,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                if (revealed)
                  IconButton(
                    tooltip: 'Copiar',
                    onPressed: () async {
                      await Clipboard.setData(
                        ClipboardData(text: profile.pin),
                      );
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('PIN copiado.')),
                      );
                    },
                    icon: const Icon(Icons.copy_rounded,
                        color: MangoColors.muted),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: onChangePin,
              style: FilledButton.styleFrom(
                backgroundColor: MangoColors.primaryOrange,
                foregroundColor: MangoColors.white,
                minimumSize: const Size.fromHeight(46),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              icon: const Icon(Icons.password_rounded, size: 18),
              label: const Text(
                'Cambiar PIN',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BusinessCard extends StatelessWidget {
  final OwnerProfile profile;
  const _BusinessCard({required this.profile});

  @override
  Widget build(BuildContext context) {
    return _CardFrame(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _CardHeader(
              icon: Icons.storefront_outlined, label: 'Negocio activo'),
          const SizedBox(height: 10),
          _KeyValueRow(label: 'Nombre', value: profile.businessName),
          _KeyValueRow(label: 'Tu rol', value: 'Propietario'),
        ],
      ),
    );
  }
}

class _MetadataCard extends StatelessWidget {
  final OwnerProfile profile;
  const _MetadataCard({required this.profile});

  @override
  Widget build(BuildContext context) {
    final fmt = DateFormat("d 'de' MMMM 'de' yyyy", 'es');
    return _CardFrame(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _CardHeader(
              icon: Icons.event_note_outlined, label: 'Actividad'),
          const SizedBox(height: 10),
          _KeyValueRow(
            label: 'Registrado',
            value: profile.registeredAt != null
                ? fmt.format(profile.registeredAt!)
                : '—',
          ),
          _KeyValueRow(
            label: 'Último login',
            value: profile.lastSignInAt != null
                ? fmt.format(profile.lastSignInAt!)
                : '—',
          ),
        ],
      ),
    );
  }
}

class _CardHeader extends StatelessWidget {
  final IconData icon;
  final String label;
  const _CardHeader({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 20, color: MangoColors.darkGray),
        const SizedBox(width: 8),
        Text(
          label,
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w800,
            color: MangoColors.darkGray,
          ),
        ),
      ],
    );
  }
}

class _KeyValueRow extends StatelessWidget {
  final String label;
  final String value;
  const _KeyValueRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 12,
                color: MangoColors.muted,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                fontSize: 13.5,
                color: MangoColors.darkGray,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline,
                size: 48, color: MangoColors.muted),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: MangoColors.muted),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: onRetry,
              child: const Text('Reintentar'),
            ),
          ],
        ),
      ),
    );
  }
}

class _NotOwnerScaffold extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Mi cuenta')),
      body: const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Esta sección es solo para propietarios.',
            textAlign: TextAlign.center,
            style: TextStyle(color: MangoColors.muted),
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// Dialogs
// =============================================================================

class _ChangePinDialog extends StatefulWidget {
  final String currentPin;
  const _ChangePinDialog({required this.currentPin});

  @override
  State<_ChangePinDialog> createState() => _ChangePinDialogState();
}

class _ChangePinDialogState extends State<_ChangePinDialog> {
  final _formKey = GlobalKey<FormState>();
  final _pinCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _pinCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Cambiar PIN'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Ingresa 4 dígitos. Lo usarás para login offline y confirmaciones rápidas.',
              style: TextStyle(fontSize: 12, color: MangoColors.muted, height: 1.4),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _pinCtrl,
              autofocus: true,
              keyboardType: TextInputType.number,
              maxLength: 4,
              obscureText: _obscure,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(
                labelText: 'Nuevo PIN',
                border: const OutlineInputBorder(),
                counterText: '',
                suffixIcon: IconButton(
                  icon: Icon(_obscure
                      ? Icons.visibility_rounded
                      : Icons.visibility_off_rounded),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
              validator: (v) {
                final s = v?.trim() ?? '';
                if (s.length != 4) return 'Deben ser 4 dígitos';
                if (s == widget.currentPin) {
                  return 'No puede ser el mismo PIN actual';
                }
                return null;
              },
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: _confirmCtrl,
              keyboardType: TextInputType.number,
              maxLength: 4,
              obscureText: _obscure,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                labelText: 'Confirmar PIN',
                border: OutlineInputBorder(),
                counterText: '',
              ),
              validator: (v) {
                if ((v ?? '').trim() != _pinCtrl.text.trim()) {
                  return 'Los PINs no coinciden';
                }
                return null;
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () {
            if (_formKey.currentState?.validate() != true) return;
            Navigator.of(context).pop(_pinCtrl.text.trim());
          },
          style: FilledButton.styleFrom(
            backgroundColor: MangoColors.primaryOrange,
          ),
          child: const Text('Guardar'),
        ),
      ],
    );
  }
}

class _EditNameDialog extends StatefulWidget {
  final String currentName;
  const _EditNameDialog({required this.currentName});

  @override
  State<_EditNameDialog> createState() => _EditNameDialogState();
}

class _EditNameDialogState extends State<_EditNameDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.currentName);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Editar nombre'),
      content: Form(
        key: _formKey,
        child: TextFormField(
          controller: _ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            labelText: 'Nombre completo',
            border: OutlineInputBorder(),
          ),
          validator: (v) {
            final s = v?.trim() ?? '';
            if (s.length < 2) return 'Mínimo 2 caracteres';
            return null;
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () {
            if (_formKey.currentState?.validate() != true) return;
            Navigator.of(context).pop(_ctrl.text.trim());
          },
          style: FilledButton.styleFrom(
            backgroundColor: MangoColors.primaryOrange,
          ),
          child: const Text('Guardar'),
        ),
      ],
    );
  }
}
