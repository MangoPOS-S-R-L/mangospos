String? _normalizeToken(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;

  final collapsed = trimmed.replaceAll(RegExp(r'\s+'), ' ');
  if (collapsed.contains('@')) {
    final localPart = collapsed.split('@').first.trim();
    if (localPart.isEmpty) return null;
    final pieces = localPart
        .split(RegExp(r'[._-]+'))
        .where((part) => part.trim().isNotEmpty)
        .toList(growable: false);
    if (pieces.isEmpty) return localPart;
    return pieces.first.trim();
  }

  final parts = collapsed
      .split(RegExp(r'\s+'))
      .where((part) => part.trim().isNotEmpty)
      .toList(growable: false);
  if (parts.isEmpty) return null;
  return parts.first.trim();
}

String preferredDisplayName({
  String? firstName,
  String? fullName,
  String? email,
  String fallback = 'Usuario',
}) {
  return _normalizeToken(firstName) ??
      _normalizeToken(fullName) ??
      _normalizeToken(email) ??
      fallback;
}
