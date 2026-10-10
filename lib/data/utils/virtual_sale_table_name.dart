/// Nombre para el papel de la mesa virtual de una venta rápida/manual.
///
/// Esas ventas viven en mesas virtuales (`dining_tables`) cuyo código es una
/// identidad interna: los carriles `quick`, `quick#2`, … / `manual`,
/// `manual#2`, … (20261009_0004) y las mesas por carrito retail o por venta
/// offline (`quick-<id>`, `manual-<id>`). Imprimir ese código en la comanda o
/// la factura decía "MESA: quick#2"; la etiqueta ("Venta rapida 2") es la que
/// sirve en papel.
///
/// Devuelve null si [code] no es de una mesa virtual: las mesas reales siguen
/// imprimiendo su código como siempre. Sin etiqueta usable (vacía, o que
/// también es un código interno) se arma desde el código.
String? virtualSaleTableName({String? code, String? label}) {
  final match = _virtualSaleCode.firstMatch(code?.trim() ?? '');
  if (match == null) return null;
  var text = label?.trim() ?? '';
  // Las mesas compartidas de antes se crearon con "Venta rapida auto" /
  // "Venta manual auto": el "auto" no le dice nada a cocina ni al cliente.
  text = text.replaceFirstMapped(_legacyAutoLabel, (m) => m.group(1)!);
  if (text.isNotEmpty && !_virtualSaleCode.hasMatch(text)) return text;
  final base = match.group(1) == 'quick' ? 'Venta rapida' : 'Venta manual';
  final lane = match.group(2);
  return lane == null || lane == '1' ? base : '$base $lane';
}

final RegExp _virtualSaleCode = RegExp(r'^(quick|manual)(?:#(\d+)|-.+)?$');
final RegExp _legacyAutoLabel = RegExp(
  r'^(venta (?:rapida|rápida|manual))\s+auto$',
  caseSensitive: false,
);
