import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';
import 'badges.dart';
import 'buttons.dart';
import 'feedback.dart';
import 'fields.dart';
import 'lists.dart';
import 'progress.dart';
import 'surfaces.dart';

/// Fixed sheet sizes. Small and medium take the height of their content
/// (up to the window); large and extra large have a fixed height.
enum SheetSize {
  small(420),
  medium(560),
  large(780, 560),
  xlarge(900, 640);

  const SheetSize(this.width, [this.height]);

  final double width;
  final double? height;
}

/// Content margin of sheets and alerts.
const double _kMargin = 20;

/// Sheet, alert and panel surface: `windowBackground`, radius 10, sheet
/// shadow and a 0.5 hairline.
class SheetSurface extends StatelessWidget {
  const SheetSurface({super.key, required this.child, this.width, this.height});

  final Widget child;
  final double? width;
  final double? height;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: c.windowBackground,
        borderRadius: BorderRadius.circular(Radii.sheet),
        border: Border.all(color: c.separator, width: 0.5),
        boxShadow: Elevation.sheet(Theme.of(context).brightness),
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        type: MaterialType.transparency,
        child: DefaultTextStyle(style: uiText(TypeSize.body, color: c.text), child: child),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Route
// ---------------------------------------------------------------------------

/// Window-modal route for sheets, alerts and panels: centered in the window
/// over a dimmed backdrop, it fades and scales in. Clicks outside are ignored
/// (or close a [dismissible] panel). Esc pops (respecting [PopScope]); Invio runs [submit], the
/// default button registered by [SheetScaffold] or [AlertPanel], unless the
/// focus is in a multi-line field (⌘Invio always runs it).
class _SheetRoute<T> extends PopupRoute<T> {
  _SheetRoute({
    required this.builder,
    required this.width,
    required this.height,
    required this.capturedThemes,
    required this.barrierColor,
    this.dismissible = false,
    this.size,
  });

  final WidgetBuilder builder;
  final double width;
  final double? height;
  final CapturedThemes capturedThemes;
  final bool dismissible;
  final SheetSize? size;

  /// The default action, set while the content builds.
  VoidCallback? submit;

  static _SheetRoute<dynamic>? of(BuildContext context) {
    final r = ModalRoute.of(context);
    return r is _SheetRoute ? r : null;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent || !isCurrent) return KeyEventResult.ignored;
    final key = e.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      navigator?.maybePop();
      return KeyEventResult.handled;
    }
    if (key != LogicalKeyboardKey.enter && key != LogicalKeyboardKey.numpadEnter) return KeyEventResult.ignored;
    final run = submit;
    if (run == null) return KeyEventResult.ignored;
    final hw = HardwareKeyboard.instance;
    final command = hw.isMetaPressed || hw.isControlPressed;
    if (!command) {
      if (hw.isShiftPressed || hw.isAltPressed) return KeyEventResult.ignored;
      final editable = FocusManager.instance.primaryFocus?.context?.findAncestorStateOfType<EditableTextState>();
      if (editable != null &&
          (editable.widget.maxLines != 1 || editable.textEditingValue.composing.isValid)) {
        return KeyEventResult.ignored;
      }
    }
    run();
    return KeyEventResult.handled;
  }

  @override
  final Color barrierColor;

  @override
  bool get barrierDismissible => dismissible;

  @override
  String? get barrierLabel => dismissible ? 'Chiudi' : null;

  @override
  Duration get transitionDuration => Motion.regular;

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) =>
      capturedThemes.wrap(
        LayoutBuilder(
          builder: (context, box) {
            // Key events from anywhere in the route bubble up to its scope.
            FocusScope.of(context).onKeyEvent = _onKey;
            final w = math.min(width, box.maxWidth - Gap.lg * 2);
            final maxH = box.maxHeight - Gap.lg * 2;
            return Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: maxH),
                child: SheetSurface(
                  width: w,
                  height: height == null ? null : math.min(height!, maxH),
                  child: Builder(builder: builder),
                ),
              ),
            );
          },
        ),
      );

  /// Fades in while growing from 96%; Reduce Motion keeps only the fade.
  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
    final faded = FadeTransition(opacity: curved, child: child);
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) return faded;
    return ScaleTransition(scale: Tween(begin: 0.96, end: 1.0).animate(curved), child: faded);
  }
}

Future<T?> _present<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  required double width,
  double? height,
  bool dismissible = false,
  SheetSize? size,
}) {
  final navigator = Navigator.of(context, rootNavigator: true);
  return navigator.push(
    _SheetRoute<T>(
      builder: builder,
      width: width,
      height: height,
      dismissible: dismissible,
      barrierColor: Elevation.scrim(Theme.of(context).brightness),
      size: size,
      capturedThemes: InheritedTheme.capture(from: context, to: navigator.context),
    ),
  );
}

// ---------------------------------------------------------------------------
// Sheet
// ---------------------------------------------------------------------------

/// Opens a sheet: centered in the window over a dimmed backdrop, it fades
/// and scales in over 200ms. Esc closes it. Build the content with a
/// [SheetScaffold].
Future<T?> showSheet<T>(BuildContext context, {required WidgetBuilder builder, SheetSize size = SheetSize.medium}) =>
    _present<T>(context, builder: builder, width: size.width, height: size.height, size: size);

/// Layout of a sheet: title, body, footer.
///
/// - Title: 13 semibold centered; 17 left-aligned in large sheets (with an
///   optional [subtitle]).
/// - Body: inside 20pt margins. In small and medium sheets it scrolls when
///   taller than the window (so it must not be a [ListView]); in large ones
///   it fills the space between title and footer. Its [FormGroup]s share
///   one label column ([FormScope]).
/// - Footer, no fill: [leading] on the left (secondary actions, inline
///   status such as "Prova connessione"), [actions] on the right in the order
///   Annulla, default. No close X: Esc, Annulla or Fine.
///
/// [onSubmit] is the default action, run by Invio.
class SheetScaffold extends StatelessWidget {
  const SheetScaffold({
    super.key,
    required this.title,
    required this.body,
    this.subtitle,
    this.leading = const [],
    this.actions = const [],
    this.onSubmit,
    this.largeTitle,
    this.padding = const EdgeInsets.symmetric(horizontal: _kMargin),
  });

  final String title;
  final String? subtitle;
  final Widget body;
  final List<Widget> leading;
  final List<Widget> actions;
  final VoidCallback? onSubmit;

  /// Defaults to true in [SheetSize.large] and [SheetSize.xlarge] sheets.
  final bool? largeTitle;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final route = _SheetRoute.of(context);
    route?.submit = onSubmit;
    final large = largeTitle ?? (route?.size?.height != null);

    final header = large
        ? Padding(
            padding: const EdgeInsets.fromLTRB(_kMargin, 18, _kMargin, Gap.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: uiText(TypeSize.sheetTitle, weight: FontWeight.w700, color: c.text),
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: uiText(TypeSize.small, color: c.textSecondary),
                  ),
              ],
            ),
          )
        : Padding(
            padding: const EdgeInsets.fromLTRB(_kMargin, Gap.lg, _kMargin, Gap.md),
            child: Column(
              children: [
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: uiText(TypeSize.body, weight: FontWeight.w600, color: c.text),
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    textAlign: TextAlign.center,
                    style: uiText(TypeSize.caption, color: c.textSecondary),
                  ),
              ],
            ),
          );

    final footer = leading.isEmpty && actions.isEmpty
        ? const SizedBox(height: _kMargin)
        : Padding(
            padding: const EdgeInsets.fromLTRB(_kMargin, Gap.lg, _kMargin, 18),
            child: Row(
              children: [
                // Flexible leading widgets (status lines) take all the free space.
                Expanded(
                  child: Row(
                    children: [for (final (i, w) in leading.indexed) ...[if (i > 0) const SizedBox(width: Gap.sm), w]],
                  ),
                ),
                if (leading.isNotEmpty && actions.isNotEmpty) const SizedBox(width: Gap.sm),
                for (final (i, a) in actions.indexed) ...[if (i > 0) const SizedBox(width: Gap.sm), a],
              ],
            ),
          );

    return LayoutBuilder(
      builder: (context, box) {
        final fixed = box.hasBoundedHeight && box.minHeight == box.maxHeight;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            header,
            if (fixed)
              Expanded(child: Padding(padding: padding, child: FormScope(child: body)))
            else
              Flexible(child: SingleChildScrollView(padding: padding, child: FormScope(child: body))),
            footer,
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Alert
// ---------------------------------------------------------------------------

enum AlertStyle {
  informational,
  warning,

  /// Destructive confirmations and errors (caution badge on the icon).
  critical,
}

enum AlertRole {
  normal,

  /// The button Invio presses (accent).
  defaultAction,

  /// What Esc means. Esc itself returns null.
  cancel,

  /// Danger fill; it is the Invio button when there is no [defaultAction].
  destructive,
}

class AlertButton<T> {
  const AlertButton(this.label, this.value, {this.role = AlertRole.normal});

  final String label;
  final T value;
  final AlertRole role;
}

/// Alert body in the Sonoma layout: app icon 64 (with a caution badge for
/// [AlertStyle.warning] and [AlertStyle.critical]), bold 13 title and 11
/// message centered, optional [details] disclosure and [accessory] (a
/// field), buttons at full width.
///
/// List [buttons] most important first. Two short buttons sit side by side
/// with the first on the right; otherwise they stack with the first on top.
class AlertPanel<T> extends StatelessWidget {
  const AlertPanel({
    super.key,
    required this.title,
    required this.buttons,
    required this.onSelected,
    this.message,
    this.style = AlertStyle.informational,
    this.details,
    this.accessory,
  });

  final String title;
  final String? message;
  final AlertStyle style;
  final List<AlertButton<T>> buttons;
  final ValueChanged<T> onSelected;
  final String? details;
  final Widget? accessory;

  AlertButton<T>? get _default =>
      buttons.where((b) => b.role == AlertRole.defaultAction).firstOrNull ??
      buttons.where((b) => b.role == AlertRole.destructive).firstOrNull;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final def = _default;
    _SheetRoute.of(context)?.submit = def == null ? null : () => onSelected(def.value);

    Widget button(AlertButton<T> b) => PushButton(
      label: b.label,
      expand: true,
      kind: switch (b.role) {
        AlertRole.defaultAction => PushButtonKind.defaultAction,
        AlertRole.destructive => PushButtonKind.destructive,
        _ => PushButtonKind.normal,
      },
      filled: b.role == AlertRole.destructive,
      onPressed: () => onSelected(b.value),
    );

    final horizontal = buttons.length == 2 && buttons.every((b) => b.label.length <= 12);
    final buttonArea = horizontal
        ? Row(
            children: [
              Expanded(child: button(buttons[1])),
              const SizedBox(width: Gap.sm),
              Expanded(child: button(buttons[0])),
            ],
          )
        : Column(
            children: [
              for (final (i, b) in buttons.indexed) ...[if (i > 0) const SizedBox(height: Gap.sm), button(b)],
            ],
          );

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(Gap.lg, _kMargin, Gap.lg, Gap.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _AlertIcon(style),
          const SizedBox(height: Gap.md),
          Text(
            title,
            textAlign: TextAlign.center,
            style: uiText(TypeSize.body, weight: FontWeight.w700, color: c.text),
          ),
          if (message != null && message!.isNotEmpty) ...[
            const SizedBox(height: 6),
            SelectableText(
              message!,
              textAlign: TextAlign.center,
              style: uiText(TypeSize.caption, color: c.text, height: 1.35),
            ),
          ],
          if (details != null) ...[const SizedBox(height: Gap.sm), ErrorDetails(details!)],
          if (accessory != null) ...[const SizedBox(height: Gap.md), accessory!],
          const SizedBox(height: Gap.lg),
          buttonArea,
        ],
      ),
    );
  }
}

class _AlertIcon extends StatelessWidget {
  const _AlertIcon(this.style);

  final AlertStyle style;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    if (style == AlertStyle.informational) return const AppMark();
    return SizedBox(
      width: 64,
      height: 64,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          const AppMark(),
          Positioned(
            right: -6,
            bottom: -4,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // White outline so the triangle reads over the icon.
                Icon(AppIcons.warningFill, size: 34, color: c.windowBackground),
                Icon(AppIcons.warningFill, size: 28, color: style == AlertStyle.critical ? c.warning : c.textSecondary),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Opens an alert centered in the window, like a sheet. Returns the
/// value of the pressed button, or null on Esc.
Future<T?> showAlert<T>(
  BuildContext context, {
  required String title,
  required List<AlertButton<T>> buttons,
  String? message,
  AlertStyle style = AlertStyle.informational,
  String? details,
  Widget? accessory,
}) => _present<T>(
  context,
  width: details == null ? 260 : 360,
  builder: (context) => AlertPanel<T>(
    title: title,
    message: message,
    style: style,
    buttons: buttons,
    details: details,
    accessory: accessory,
    onSelected: (v) => Navigator.of(context).pop(v),
  ),
);

/// Yes/no alert. [destructive] makes [ok] a danger button.
Future<bool> confirmDialog(
  BuildContext context,
  String title,
  String message, {
  String ok = 'OK',
  String cancel = 'Annulla',
  bool destructive = false,
}) async {
  final r = await showAlert<bool>(
    context,
    title: title,
    message: message,
    style: destructive ? AlertStyle.critical : AlertStyle.informational,
    buttons: [
      AlertButton(ok, true, role: destructive ? AlertRole.destructive : AlertRole.defaultAction),
      AlertButton(cancel, false, role: AlertRole.cancel),
    ],
  );
  return r ?? false;
}

/// Alert with a text field. Returns the text, or null when cancelled.
Future<String?> promptText(
  BuildContext context,
  String title, {
  String label = '',
  String initial = '',
  bool obscure = false,
  int maxLines = 1,
}) async {
  var text = initial;
  final ok = await showAlert<bool>(
    context,
    title: title,
    accessory: _PromptField(
      initial: initial,
      hint: label.isEmpty ? null : label,
      obscure: obscure,
      maxLines: maxLines,
      onChanged: (v) => text = v,
    ),
    buttons: const [
      AlertButton('OK', true, role: AlertRole.defaultAction),
      AlertButton('Annulla', false, role: AlertRole.cancel),
    ],
  );
  return ok == true ? text : null;
}

/// The field of [promptText]. It owns its controller, so the controller lives
/// exactly as long as the field, exit animation included.
class _PromptField extends StatefulWidget {
  const _PromptField({
    required this.initial,
    required this.hint,
    required this.obscure,
    required this.maxLines,
    required this.onChanged,
  });

  final String initial;
  final String? hint;
  final bool obscure;
  final int maxLines;
  final ValueChanged<String> onChanged;

  @override
  State<_PromptField> createState() => _PromptFieldState();
}

class _PromptFieldState extends State<_PromptField> {
  late final _ctrl = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.obscure
      ? SecureField(controller: _ctrl, hint: widget.hint, autofocus: true, onChanged: widget.onChanged)
      : MacTextField(
          controller: _ctrl,
          hint: widget.hint,
          autofocus: true,
          maxLines: widget.maxLines,
          minLines: widget.maxLines > 1 ? math.min(widget.maxLines, 3) : null,
          onChanged: widget.onChanged,
        );
}

/// Error alert: the first line of the message, the full text (copyable)
/// under "Mostra dettagli".
Future<void> showErrorDialog(BuildContext context, Object error, {String title = 'Errore'}) {
  final full = describeError(error).trim();
  final first = full.split('\n').first;
  final message = first.length > 200 ? '${first.substring(0, 197)}…' : first;
  return showAlert<void>(
    context,
    title: title,
    message: message,
    style: AlertStyle.critical,
    details: message == full ? null : full,
    buttons: const [AlertButton('OK', null, role: AlertRole.defaultAction)],
  );
}

/// Runs [action] showing errors in an alert. Returns true on success.
Future<bool> guarded(BuildContext context, Future<void> Function() action, {String title = 'Errore'}) async {
  try {
    await action();
    return true;
  } catch (e) {
    if (context.mounted) showErrorDialog(context, e, title: title);
    return false;
  }
}

// ---------------------------------------------------------------------------
// List picker
// ---------------------------------------------------------------------------

/// Medium sheet to pick one item: search field, list, Annulla / [choose].
/// Arrows move the selection from the search field, Invio or a double click
/// chooses.
///
/// Pass either [items] or [load]: with [load] the list shows a [Spinner]
/// until the items arrive, and the error (titled [loadError]) if they do not.
/// [empty] is the text of an empty list (as opposed to a search with no
/// match). [iconColor] tints the [icon]s (driver brand, accent for tables);
/// secondary when it returns null.
Future<T?> showListPicker<T>(
  BuildContext context, {
  required String title,
  List<T>? items,
  Future<List<T>> Function()? load,
  required String Function(T) label,
  String Function(T)? detail,
  IconData Function(T)? icon,
  Color? Function(T)? iconColor,
  String choose = 'Scegli',
  String searchHint = 'Cerca',
  String empty = 'Nessun elemento',
  String loadError = 'Impossibile caricare l\'elenco',
}) {
  assert((items == null) != (load == null), 'Pass exactly one of items and load');
  return showSheet<T>(
    context,
    builder: (_) => _ListPicker<T>(
      title: title,
      items: items,
      load: load,
      label: label,
      detail: detail,
      icon: icon,
      iconColor: iconColor,
      choose: choose,
      searchHint: searchHint,
      empty: empty,
      loadError: loadError,
    ),
  );
}

class _ListPicker<T> extends StatefulWidget {
  const _ListPicker({
    required this.title,
    required this.items,
    required this.load,
    required this.label,
    required this.detail,
    required this.icon,
    required this.iconColor,
    required this.choose,
    required this.searchHint,
    required this.empty,
    required this.loadError,
  });

  final String title;
  final List<T>? items;
  final Future<List<T>> Function()? load;
  final String Function(T) label;
  final String Function(T)? detail;
  final IconData Function(T)? icon;
  final Color? Function(T)? iconColor;
  final String choose;
  final String searchHint;
  final String empty;
  final String loadError;

  @override
  State<_ListPicker<T>> createState() => _ListPickerState<T>();
}

class _ListPickerState<T> extends State<_ListPicker<T>> {
  static const _rowHeight = 24.0;
  static const _listHeight = 288.0;

  final _query = TextEditingController();
  final _scroll = ScrollController();

  /// All the items; null while [_ListPicker.load] runs.
  late List<T>? _items = widget.items;
  Object? _error;
  late List<T> _shown = _items ?? const [];
  int _selected = 0;

  /// The row of the last click, while a second one would make it a double
  /// click.
  int? _lastTap;
  Timer? _tapTimer;

  @override
  void initState() {
    super.initState();
    final load = widget.load;
    if (load != null) {
      load().then(
        (items) {
          if (!mounted) return;
          setState(() => _items = items);
          _filter(_query.text);
        },
        onError: (Object e) {
          if (mounted) setState(() => _error = e);
        },
      );
    }
  }

  @override
  void dispose() {
    _tapTimer?.cancel();
    _query.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _filter(String q) {
    final items = _items;
    if (items == null) return;
    final needle = q.trim().toLowerCase();
    setState(() {
      _shown = needle.isEmpty ? items : items.where((i) => widget.label(i).toLowerCase().contains(needle)).toList();
      _selected = 0;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _move(int delta) {
    if (_shown.isEmpty) return;
    setState(() => _selected = (_selected + delta).clamp(0, _shown.length - 1));
    if (!_scroll.hasClients) return;
    final top = _selected * _rowHeight;
    final view = _scroll.position.viewportDimension;
    if (top < _scroll.offset) {
      _scroll.jumpTo(top);
    } else if (top + _rowHeight > _scroll.offset + view) {
      _scroll.jumpTo(top + _rowHeight - view + Gap.xs * 2);
    }
  }

  void _pick() {
    if (_selected < _shown.length) Navigator.of(context).pop(_shown[_selected]);
  }

  /// Mouse down on row [i]: selects it; a second click on it within
  /// [kDoubleTapTimeout] chooses it.
  void _tapRow(int i) {
    final second = _lastTap == i && (_tapTimer?.isActive ?? false);
    _tapTimer?.cancel();
    setState(() => _selected = i);
    if (second) {
      _lastTap = null;
      _pick();
    } else {
      _lastTap = i;
      _tapTimer = Timer(kDoubleTapTimeout, () => _lastTap = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    final canPick = _selected < _shown.length;
    final Widget list;
    if (_error != null) {
      list = EmptyState.error(_error!, title: widget.loadError);
    } else if (_items == null) {
      list = const Center(child: Spinner());
    } else if (_shown.isEmpty) {
      list = Center(
        child: Text(
          _items!.isEmpty ? widget.empty : 'Nessun risultato',
          style: uiText(TypeSize.body, color: c.textTertiary),
        ),
      );
    } else {
      list = ListView.builder(
        controller: _scroll,
        padding: const EdgeInsets.all(Gap.xs),
        itemExtent: _rowHeight,
        itemCount: _shown.length,
        itemBuilder: (context, i) => _row(c, i),
      );
    }
    return SheetScaffold(
      title: widget.title,
      onSubmit: canPick ? _pick : null,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Focus(
            canRequestFocus: false,
            skipTraversal: true,
            onKeyEvent: (_, e) {
              if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
              if (e.logicalKey == LogicalKeyboardKey.arrowDown) {
                _move(1);
                return KeyEventResult.handled;
              }
              if (e.logicalKey == LogicalKeyboardKey.arrowUp) {
                _move(-1);
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: SearchField(controller: _query, hint: widget.searchHint, autofocus: true, onChanged: _filter),
          ),
          const SizedBox(height: Gap.sm),
          Container(
            height: _listHeight,
            decoration: BoxDecoration(
              color: c.content,
              borderRadius: BorderRadius.circular(Radii.panel),
              border: Border.all(color: c.separator, width: 0.5),
            ),
            clipBehavior: Clip.antiAlias,
            child: list,
          ),
        ],
      ),
      actions: [
        PushButton(label: 'Annulla', onPressed: () => Navigator.of(context).pop()),
        PushButton.primary(label: widget.choose, onPressed: canPick ? _pick : null),
      ],
    );
  }

  Widget _row(DbColors c, int i) {
    final item = _shown[i];
    final selected = i == _selected;
    final fg = selected ? c.onSelectionEmphasized : c.text;
    final detail = widget.detail?.call(item);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _tapRow(i),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
        decoration: BoxDecoration(
          color: selected ? c.selectionEmphasized : null,
          borderRadius: BorderRadius.circular(Radii.control),
        ),
        child: Row(
          children: [
            if (widget.icon != null) ...[
              Icon(
                widget.icon!(item),
                size: 16,
                color: selected ? fg : (widget.iconColor?.call(item) ?? c.textSecondary),
              ),
              const SizedBox(width: 6),
            ],
            Expanded(
              child: Text(
                widget.label(item),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: uiText(TypeSize.body, color: fg),
              ),
            ),
            if (detail != null)
              Text(
                detail,
                style: uiText(TypeSize.caption, color: selected ? fg : c.textTertiary, features: kTabular),
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// About
// ---------------------------------------------------------------------------

/// About panel (orderFrontStandardAboutPanel): icon 64, name 15 bold,
/// version 11 secondary, [description], copyright 10, optional [action].
class AboutPanel extends StatelessWidget {
  const AboutPanel({
    super.key,
    required this.name,
    required this.version,
    this.description,
    this.copyright,
    this.action,
  });

  final String name;
  final String version;
  final String? description;
  final String? copyright;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.xl, Gap.xl, _kMargin),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const AppMark(),
          const SizedBox(height: Gap.md),
          Text(name, style: uiText(TypeSize.title, weight: FontWeight.w700, color: c.text)),
          const SizedBox(height: 2),
          Text('Versione $version', style: uiText(TypeSize.caption, color: c.textSecondary, features: kTabular)),
          if (description != null) ...[
            const SizedBox(height: Gap.md),
            Text(
              description!,
              textAlign: TextAlign.center,
              style: uiText(TypeSize.caption, color: c.textSecondary, height: 1.35),
            ),
          ],
          if (copyright != null) ...[
            const SizedBox(height: Gap.md),
            Text(copyright!, textAlign: TextAlign.center, style: uiText(TypeSize.mini, color: c.textTertiary)),
          ],
          if (action != null) ...[const SizedBox(height: Gap.lg), action!],
        ],
      ),
    );
  }
}

/// Opens the [AboutPanel] centered in the window; Esc or a click outside
/// closes it.
Future<void> showAboutPanel(
  BuildContext context, {
  required String name,
  required String version,
  String? description,
  String? copyright,
  Widget? action,
}) => _present<void>(
  context,
  width: 280,
  dismissible: true,
  builder: (_) => AboutPanel(
    name: name,
    version: version,
    description: description,
    copyright: copyright,
    action: action,
  ),
);

// ---------------------------------------------------------------------------
// Keyboard shortcuts
// ---------------------------------------------------------------------------

/// One line of a [ShortcutsSheet]: what it does and its keys (alternatives
/// are shown separated by "/").
class ShortcutHelp {
  const ShortcutHelp(this.description, this.keys);

  final String description;
  final List<SingleActivator> keys;
}

/// The keyboard shortcuts reference (Aiuto ▸ Scorciatoie da tastiera): a
/// medium sheet with a [SectionLabel] per group and one row per command,
/// the keys as [KeyCap]s on the right. Fine closes it.
class ShortcutsSheet extends StatelessWidget {
  const ShortcutsSheet({super.key, required this.groups, this.onDone});

  /// Group title and its shortcuts.
  final List<(String, List<ShortcutHelp>)> groups;
  final VoidCallback? onDone;

  @override
  Widget build(BuildContext context) {
    final c = DbColors.of(context);
    void done() => onDone != null ? onDone!() : Navigator.of(context).maybePop();
    return SheetScaffold(
      title: 'Scorciatoie da tastiera',
      onSubmit: done,
      actions: [PushButton.primary(label: 'Fine', onPressed: done)],
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, (title, rows)) in groups.indexed) ...[
            SectionLabel(title, padding: EdgeInsets.only(top: i == 0 ? 0 : Gap.md, bottom: Gap.xs)),
            for (final r in rows)
              SizedBox(
                height: 26,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        r.description,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: uiText(TypeSize.body, color: c.text),
                      ),
                    ),
                    const SizedBox(width: Gap.md),
                    KeyCaps(r.keys),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// Opens the [ShortcutsSheet].
Future<void> showShortcutsSheet(BuildContext context, List<(String, List<ShortcutHelp>)> groups) =>
    showSheet<void>(context, builder: (_) => ShortcutsSheet(groups: groups));
