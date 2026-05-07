// lib/data/models/business_profile.dart
//
// Snapshot agregado del perfil editable de una sucursal: combina campos
// de `businesses` (datos identitarios + branding: logo, slogan, footer)
// con flags y listas de `business_settings` (bloques customizables del
// ticket).
//
// Source of truth para los headers/footers de la representacion impresa
// (factura y pre-cuenta). Mantener este modelo alineado con migrations
// 20260507_0001/0002/0003 y con BusinessProfileRepository.

/// Un bloque customizable del header o footer del ticket.
///
/// `key` identifica el bloque (logo, business_name, slogan, etc) y debe
/// matchear las keys que el renderer en PrintTicketService conoce. `enabled`
/// controla si se imprime. El orden en la lista determina el orden visual.
class TicketBlock {
  final String key;
  final bool enabled;

  const TicketBlock({required this.key, required this.enabled});

  factory TicketBlock.fromMap(Map<String, dynamic> m) => TicketBlock(
        key: (m['key'] ?? '') as String,
        enabled: (m['enabled'] as bool?) ?? false,
      );

  Map<String, dynamic> toMap() => {'key': key, 'enabled': enabled};

  TicketBlock copyWith({String? key, bool? enabled}) =>
      TicketBlock(key: key ?? this.key, enabled: enabled ?? this.enabled);
}

/// Defaults canónicos cuando un negocio no tiene listas configuradas
/// todavia (e.g. business_settings sin row, o columnas null). Coinciden
/// con los defaults SQL del backfill en 20260507_0003.
class TicketBlocks {
  static const List<TicketBlock> defaultHeader = [
    TicketBlock(key: 'logo', enabled: false),
    TicketBlock(key: 'business_name', enabled: true),
    TicketBlock(key: 'slogan', enabled: true),
    TicketBlock(key: 'legal_name', enabled: true),
    TicketBlock(key: 'branch_name', enabled: true),
    TicketBlock(key: 'address', enabled: true),
    TicketBlock(key: 'phone', enabled: true),
    TicketBlock(key: 'email', enabled: false),
    TicketBlock(key: 'rnc', enabled: true),
  ];

  static const List<TicketBlock> defaultFooter = [
    TicketBlock(key: 'footer_message', enabled: true),
    TicketBlock(key: 'thank_you', enabled: true),
  ];
}

class BusinessProfile {
  // ─── businesses ───────────────────────────────────────────────────────
  final String id;
  final String? businessName;
  final String? branchName;
  final String? fiscalName;
  final String? fiscalRnc;
  final String? address;
  final String? phone;
  final String? email;

  // Branding (ver migration 20260507_0001).
  final String? logoUrl;
  final String? logoStoragePath;
  final String? slogan;
  final String? ticketFooterMessage;

  // ─── business_settings ────────────────────────────────────────────────
  // Toggles legacy del commit 0001. Los conservamos en el modelo para
  // retrocompatibilidad pero el rendering (PrintTicketService) ya no los
  // lee — usa headerBlocks/footerBlocks. Se pueden remover en un commit
  // futuro cuando confirmemos que ningun consumer los necesita.
  final bool printLogoOnInvoice;
  final bool showSloganOnInvoice;
  final bool showBranchNameOnInvoice;

  // Listas customizables (commit 0003). null si la columna aun no se
  // backfilleo — caller usa TicketBlocks.defaultHeader/Footer en ese caso.
  final List<TicketBlock>? headerBlocks;
  final List<TicketBlock>? footerBlocks;

  const BusinessProfile({
    required this.id,
    this.businessName,
    this.branchName,
    this.fiscalName,
    this.fiscalRnc,
    this.address,
    this.phone,
    this.email,
    this.logoUrl,
    this.logoStoragePath,
    this.slogan,
    this.ticketFooterMessage,
    this.printLogoOnInvoice = false,
    this.showSloganOnInvoice = true,
    this.showBranchNameOnInvoice = true,
    this.headerBlocks,
    this.footerBlocks,
  });

  /// Header efectivo: la lista configurada o los defaults canónicos.
  List<TicketBlock> get effectiveHeaderBlocks =>
      (headerBlocks == null || headerBlocks!.isEmpty)
          ? TicketBlocks.defaultHeader
          : headerBlocks!;

  /// Footer efectivo: la lista configurada o los defaults canónicos.
  List<TicketBlock> get effectiveFooterBlocks =>
      (footerBlocks == null || footerBlocks!.isEmpty)
          ? TicketBlocks.defaultFooter
          : footerBlocks!;

  /// Construye desde un map que combina columnas de businesses +
  /// business_settings (resultado del select join del repo).
  factory BusinessProfile.fromMap(Map<String, dynamic> m) {
    List<TicketBlock>? parseBlocks(dynamic raw) {
      if (raw == null) return null;
      if (raw is! List) return null;
      return raw
          .whereType<Map<String, dynamic>>()
          .map(TicketBlock.fromMap)
          .toList();
    }

    return BusinessProfile(
      id: (m['id'] ?? '') as String,
      businessName: m['business_name'] as String?,
      branchName: m['branch_name'] as String?,
      fiscalName: m['fiscal_name'] as String?,
      fiscalRnc: m['fiscal_rnc'] as String?,
      address: m['address'] as String?,
      phone: m['phone'] as String?,
      email: m['email'] as String?,
      logoUrl: m['logo_url'] as String?,
      logoStoragePath: m['logo_storage_path'] as String?,
      slogan: m['slogan'] as String?,
      ticketFooterMessage: m['ticket_footer_message'] as String?,
      printLogoOnInvoice: (m['print_logo_on_invoice'] as bool?) ?? false,
      showSloganOnInvoice: (m['show_slogan_on_invoice'] as bool?) ?? true,
      showBranchNameOnInvoice:
          (m['show_branch_name_on_invoice'] as bool?) ?? true,
      headerBlocks: parseBlocks(m['ticket_header_blocks']),
      footerBlocks: parseBlocks(m['ticket_footer_blocks']),
    );
  }

  BusinessProfile copyWith({
    String? businessName,
    String? branchName,
    String? fiscalName,
    String? fiscalRnc,
    String? address,
    String? phone,
    String? email,
    String? logoUrl,
    String? logoStoragePath,
    String? slogan,
    String? ticketFooterMessage,
    bool? printLogoOnInvoice,
    bool? showSloganOnInvoice,
    bool? showBranchNameOnInvoice,
    List<TicketBlock>? headerBlocks,
    List<TicketBlock>? footerBlocks,
  }) {
    return BusinessProfile(
      id: id,
      businessName: businessName ?? this.businessName,
      branchName: branchName ?? this.branchName,
      fiscalName: fiscalName ?? this.fiscalName,
      fiscalRnc: fiscalRnc ?? this.fiscalRnc,
      address: address ?? this.address,
      phone: phone ?? this.phone,
      email: email ?? this.email,
      logoUrl: logoUrl ?? this.logoUrl,
      logoStoragePath: logoStoragePath ?? this.logoStoragePath,
      slogan: slogan ?? this.slogan,
      ticketFooterMessage: ticketFooterMessage ?? this.ticketFooterMessage,
      printLogoOnInvoice: printLogoOnInvoice ?? this.printLogoOnInvoice,
      showSloganOnInvoice: showSloganOnInvoice ?? this.showSloganOnInvoice,
      showBranchNameOnInvoice:
          showBranchNameOnInvoice ?? this.showBranchNameOnInvoice,
      headerBlocks: headerBlocks ?? this.headerBlocks,
      footerBlocks: footerBlocks ?? this.footerBlocks,
    );
  }
}
