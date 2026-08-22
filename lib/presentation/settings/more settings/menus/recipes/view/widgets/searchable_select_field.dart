// Selector con buscador. Reemplaza a los `DropdownButtonFormField` de
// "Producto" e "Insumo" del formulario de recetas: con catalogos grandes
// (cientos de productos / insumos) elegir de una lista cerrada era inviable.
//
// Mismo patron que `inventory/view/widgets/item_search_field.dart`, pero
// generico y pensado para un valor siempre seleccionado (no es un filtro):
// - al enfocar se vacia el texto para desplegar la lista completa,
// - escribir filtra por nombre y por las palabras clave del item (SKU...),
// - salir sin elegir restaura el valor que ya estaba.

import 'package:flutter/material.dart';

class SearchableSelectField<T extends Object> extends StatefulWidget {
  final List<T> items;
  final T? selected;
  final String Function(T item) labelOf;

  /// Linea secundaria en la lista (SKU, unidad, estado...). `null` la omite.
  final String? Function(T item)? subtitleOf;

  /// Texto extra por el que tambien se puede buscar (SKU, codigo de barras...).
  final List<String> Function(T item)? keywordsOf;

  final ValueChanged<T> onSelected;
  final String labelText;
  final String hintText;

  /// `false` muestra el valor fijo, sin buscador (ej. el producto de una
  /// receta ya creada, que no se puede cambiar).
  final bool enabled;

  const SearchableSelectField({
    super.key,
    required this.items,
    required this.selected,
    required this.labelOf,
    required this.onSelected,
    required this.labelText,
    this.subtitleOf,
    this.keywordsOf,
    this.hintText = 'Escribe para buscar...',
    this.enabled = true,
  });

  @override
  State<SearchableSelectField<T>> createState() =>
      _SearchableSelectFieldState<T>();
}

class _SearchableSelectFieldState<T extends Object>
    extends State<SearchableSelectField<T>> {
  // Controlador y foco los crea el Autocomplete; los capturamos en
  // `fieldViewBuilder` para poder sincronizar el texto con la seleccion.
  TextEditingController? _controller;
  FocusNode? _focusNode;

  String get _selectedLabel {
    final selected = widget.selected;
    return selected == null ? '' : widget.labelOf(selected);
  }

  @override
  void didUpdateWidget(covariant SearchableSelectField<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    // La seleccion puede cambiar desde fuera (se recarga el catalogo, se
    // elimina una fila de ingrediente...). El texto vive dentro del
    // Autocomplete, asi que hay que ponerlo al dia.
    if (oldWidget.selected != widget.selected) {
      final controller = _controller;
      final hasFocus = _focusNode?.hasFocus ?? false;
      if (controller != null && !hasFocus && controller.text != _selectedLabel) {
        controller.text = _selectedLabel;
      }
    }
  }

  @override
  void dispose() {
    _focusNode?.removeListener(_onFocusChanged);
    super.dispose();
  }

  void _onFocusChanged() {
    final controller = _controller;
    final focusNode = _focusNode;
    if (controller == null || focusNode == null) return;
    if (focusNode.hasFocus) {
      _openOptions(controller);
    } else if (controller.text != _selectedLabel) {
      // Salio sin elegir nada: volvemos al valor valido.
      controller.text = _selectedLabel;
    }
  }

  /// Vacia el campo cuando aun muestra el valor elegido: el Autocomplete
  /// recalcula las opciones al cambiar el texto y despliega la lista completa.
  /// Si el usuario ya escribio una busqueda, no se la borramos.
  void _openOptions(TextEditingController controller) {
    if (controller.text.isNotEmpty && controller.text == _selectedLabel) {
      controller.clear();
    }
  }

  bool _matches(T item, String query) {
    if (widget.labelOf(item).toLowerCase().contains(query)) return true;
    final keywords = widget.keywordsOf?.call(item);
    if (keywords == null) return false;
    for (final keyword in keywords) {
      if (keyword.toLowerCase().contains(query)) return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) {
      return TextFormField(
        key: ValueKey<String>('locked:${widget.labelText}:$_selectedLabel'),
        initialValue: _selectedLabel,
        enabled: false,
        decoration: InputDecoration(labelText: widget.labelText),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // El overlay de opciones no hereda el ancho del campo: lo tomamos del
        // espacio disponible para que la lista quede alineada debajo.
        final optionsWidth =
            constraints.maxWidth.isFinite && constraints.maxWidth > 0
            ? constraints.maxWidth
            : 320.0;
        return Autocomplete<T>(
          initialValue: TextEditingValue(text: _selectedLabel),
          displayStringForOption: widget.labelOf,
          optionsBuilder: (TextEditingValue value) {
            final query = value.text.trim().toLowerCase();
            // Sin busqueda mostramos todo: el campo se comporta como el
            // desplegable de antes.
            if (query.isEmpty) return widget.items;
            return widget.items.where((item) => _matches(item, query));
          },
          onSelected: widget.onSelected,
          fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
            _controller = controller;
            if (!identical(_focusNode, focusNode)) {
              _focusNode?.removeListener(_onFocusChanged);
              _focusNode = focusNode..addListener(_onFocusChanged);
            }
            return TextField(
              controller: controller,
              focusNode: focusNode,
              decoration: InputDecoration(
                labelText: widget.labelText,
                hintText: widget.hintText,
                prefixIcon: const Icon(Icons.search, size: 18),
                isDense: true,
              ),
              // Tocar un campo que ya tiene el foco tambien debe abrir la lista.
              onTap: () => _openOptions(controller),
              onSubmitted: (_) => onFieldSubmitted(),
            );
          },
          optionsViewBuilder: (context, onSelected, options) {
            final list = options.toList(growable: false);
            return Align(
              alignment: Alignment.topLeft,
              child: Material(
                elevation: 4,
                borderRadius: BorderRadius.circular(10),
                child: SizedBox(
                  width: optionsWidth,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 280),
                    child: ListView.builder(
                      padding: EdgeInsets.zero,
                      shrinkWrap: true,
                      itemCount: list.length,
                      itemBuilder: (context, index) {
                        final item = list[index];
                        final subtitle = widget.subtitleOf?.call(item);
                        return ListTile(
                          dense: true,
                          title: Text(
                            widget.labelOf(item),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: subtitle == null || subtitle.trim().isEmpty
                              ? null
                              : Text(
                                  subtitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                          onTap: () => onSelected(item),
                        );
                      },
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}
