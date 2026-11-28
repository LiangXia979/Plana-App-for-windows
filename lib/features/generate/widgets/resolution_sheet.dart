import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/platform/desktop.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/ui/desktop_popover.dart';
import '../generate_state.dart';
import '../models.dart';
import '../res_presets.dart';
import '../res_rules.dart';
import 'common.dart';
import '../../../l10n/l10n.dart';

const _customTab = '自定义';
const _mineTab = '我的';

/// 内置档位与默认预设名按界面语言显示;自定义名原样。
String _sizeLabel(AppLocalizations l, String name) => switch (name) {
  '小图' => l.sizeNormal,
  _mineTab => l.sizeMine,
  _customTab => l.sizeCustom,
  '大图' => l.sizeLarge,
  '壁纸' => l.sizeWallpaper,
  '竖图' => l.sizePortrait,
  '横图' => l.sizeLandscape,
  '方形' => l.sizeSquare,
  '竖屏' => l.sizePortraitScreen,
  '横屏' => l.sizeLandscapeScreen,
  '手机' => l.sizePhone,
  _ => name,
};

SizePreset _asSize(ResPreset p) =>
    SizePreset(p.name, formatAspectRatio(p.width, p.height), p.width, p.height);

// 画布满格对应的真实像素(两轴一致);矩形左上角锚定,右下角拖拽定 W/H。
final double _axisMax = kMaxDim.toDouble();

// 可视化配色(在浅色画布上可读,语义同 web:绿=免费线,红=上限线)。
const _vizFree = FixedSemantic.ok;
const _vizOver = FixedSemantic.danger;

/// 分辨率 Sheet:预设三档(小图免费/大图/壁纸)+ 自定义档(拖拽画布)
/// 预设单击应用，自定义尺寸在本地编辑至应用时生效。
Future<void> showResolutionSheet(BuildContext context) {
  if (ProviderScope.containerOf(
    context,
    listen: false,
  ).read(desktopModeProvider)) {
    return showDesktopPopover<void>(
      context,
      width: 340,
      maxHeight: 640,
      builder: (_) => const _ResolutionSheet(desktop: true),
    );
  }
  return showModalBottomSheet(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (context) => const _ResolutionSheet(),
  );
}

class _ResolutionSheet extends ConsumerStatefulWidget {
  const _ResolutionSheet({this.desktop = false});
  final bool desktop;

  @override
  ConsumerState<_ResolutionSheet> createState() => _ResolutionSheetState();
}

class _ResolutionSheetState extends ConsumerState<_ResolutionSheet> {
  late String tab;

  late int customW;
  late int customH;
  late final TextEditingController _width;
  late final TextEditingController _height;
  String? _widthError, _heightError;

  @override
  void initState() {
    super.initState();
    final p = ref.read(generateProvider).params;
    customW = snapDim(p.width);
    customH = snapDim(p.height);
    _width = TextEditingController(text: '$customW');
    _height = TextEditingController(text: '$customH');
    tab = _tabFor(p.width, p.height);
  }

  bool get _isCustom => tab == _customTab;

  String _tabFor(int w, int h) {
    for (final entry in sizeTabs.entries) {
      if (entry.value.any((p) => p.width == w && p.height == h)) {
        return entry.key;
      }
    }
    return ref.read(resPresetsProvider.notifier).find(w, h) == null
        ? _customTab
        : _mineTab;
  }

  Future<void> _save() async {
    if (!_commitDimensions() ||
        classifyPixels(customW, customH) == PixelTier.over) {
      return;
    }
    final w = customW, h = customH;
    try {
      await ref.read(resPresetsProvider.notifier).add(w, h);
    } catch (_) {
      if (mounted) {
        hintSnack(context, l10nNow.desktopCouldNotSaveTheSizePresetCheckYour);
      }
    }
    if (!mounted) return;
    final p = ref.read(resPresetsProvider.notifier).find(w, h);
    if (p == null) return;
    setState(() => tab = _mineTab);
  }

  Future<void> _remove(SizePreset p) async {
    final saving = ref
        .read(resPresetsProvider.notifier)
        .remove(p.width, p.height);
    if (!mounted) return;
    final mine = ref.read(resPresetsProvider);
    if (mine.isEmpty) {
      setState(() {
        customW = p.width;
        customH = p.height;
        _width.text = '$customW';
        _height.text = '$customH';
        _widthError = _heightError = null;
        tab = _customTab;
      });
    }
    try {
      await saving;
    } catch (_) {
      if (mounted) {
        hintSnack(context, l10nNow.desktopCouldNotSaveTheDeletionCheckYourDisk);
      }
    }
  }

  @override
  void dispose() {
    _width.dispose();
    _height.dispose();
    super.dispose();
  }

  void _setCustom(int w, int h) => setState(() {
    customW = w.clamp(kMinDim, kMaxDim);
    customH = h.clamp(kMinDim, kMaxDim);
    _width.text = '$customW';
    _height.text = '$customH';
    _widthError = _heightError = null;
  });

  // Parse a decimal as a number before truncating it; filtering out the dot
  // would silently turn a pasted "832.5" into "8325".
  int? _dimension(String text) {
    final value = double.tryParse(text.trim());
    if (value == null || !value.isFinite) return null;
    final integer = value.toInt();
    if (integer < kMinDim || integer > kMaxDim) return null;
    return snapDim(integer).clamp(kMinDim, kMaxDim);
  }

  bool _commitDimensions({bool normalize = true}) {
    final w = _dimension(_width.text), h = _dimension(_height.text);
    setState(() {
      _widthError = w == null ? '$kMinDim ～ $kMaxDim' : null;
      _heightError = h == null ? '$kMinDim ～ $kMaxDim' : null;
      if (w != null) {
        customW = w;
        if (normalize) _width.text = '$w';
      }
      if (h != null) {
        customH = h;
        if (normalize) _height.text = '$h';
      }
    });
    return w != null && h != null;
  }

  void _stepDimension(bool width, int direction) {
    final controller = width ? _width : _height;
    final current = _dimension(controller.text) ?? (width ? customW : customH);
    final value = (current + direction * kResSnapStep).clamp(kMinDim, kMaxDim);
    setState(() {
      if (width) {
        customW = value;
        _widthError = null;
      } else {
        customH = value;
        _heightError = null;
      }
      controller.value = TextEditingValue(
        text: '$value',
        selection: TextSelection.collapsed(offset: '$value'.length),
      );
    });
  }

  Widget _dimensionInput({required bool width}) {
    final field = TextField(
      key: ValueKey(width ? 'resolution-width' : 'resolution-height'),
      controller: width ? _width : _height,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      textInputAction: TextInputAction.done,
      style: mono(context, size: 16).copyWith(fontWeight: FontWeight.w700),
      decoration: InputDecoration(
        labelText: width ? context.l10n.width : context.l10n.height,
        suffixText: 'px',
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 9, vertical: 10),
        errorText: width ? _widthError : _heightError,
        border: const OutlineInputBorder(),
      ),
      onChanged: (_) => _commitDimensions(normalize: false),
      onSubmitted: (_) => _commitDimensions(),
      onTapOutside: (_) {
        _commitDimensions();
        FocusManager.instance.primaryFocus?.unfocus();
      },
    );
    if (!widget.desktop) return field;
    return Listener(
      onPointerSignal: (event) {
        if (event is! PointerScrollEvent || event.scrollDelta.dy == 0) return;
        GestureBinding.instance.pointerSignalResolver.register(event, (_) {
          _stepDimension(width, event.scrollDelta.dy < 0 ? 1 : -1);
        });
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
              _stepDimension(width, 1),
          const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
              _stepDimension(width, -1),
        },
        child: field,
      ),
    );
  }

  void _applySize(int width, int height) {
    if (classifyPixels(width, height) == PixelTier.over) return;
    ref.read(generateProvider.notifier).setSize(width, height);
    Navigator.pop(context);
  }

  bool get _dimensionsValid => _widthError == null && _heightError == null;
  bool get _canApplyCustom =>
      _dimensionsValid && classifyPixels(customW, customH) != PixelTier.over;

  Widget _customGrid() {
    final l = context.l10n;
    final tier = classifyPixels(customW, customH);
    final shrinkStyle = FilledButton.styleFrom(
      minimumSize: const Size(0, 32),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      textStyle: context.texts.labelLarge?.copyWith(
        fontWeight: FontWeight.w600,
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: LayoutBuilder(
            builder: (context, box) => _CanvasEditor(
              width: customW,
              height: customH,
              side: box.maxWidth.clamp(0.0, 164.0),
              onChanged: _setCustom,
            ),
          ),
        ),
        const SizedBox(height: 6),
        if (tier != PixelTier.free)
          Wrap(
            spacing: 6,
            children: [
              if (tier == PixelTier.over)
                FilledButton.tonalIcon(
                  onPressed: _dimensionsValid
                      ? () {
                          final size = clampToMaxPixels(customW, customH);
                          _setCustom(size.w, size.h);
                        }
                      : null,
                  style: shrinkStyle,
                  icon: const Icon(Icons.compress, size: 15),
                  label: Text(l.shrinkToLimit),
                ),
              FilledButton.tonalIcon(
                onPressed: _dimensionsValid
                    ? () {
                        final size = scaleToFree(customW, customH);
                        _setCustom(size.w, size.h);
                      }
                    : null,
                style: shrinkStyle,
                icon: const Icon(Icons.compress, size: 15),
                label: Text(l.shrinkToFree),
              ),
            ],
          ),
        OutlinedButton.icon(
          key: const ValueKey('resolution-save-preset'),
          onPressed: _canApplyCustom ? _save : null,
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(0, 32),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          icon: const Icon(Icons.bookmark_add_outlined, size: 16),
          label: Text(l.desktopSaveSizePreset),
        ),
      ],
    );
  }

  Widget _dimensionRow() => Row(
    children: [
      Expanded(child: _dimensionInput(width: true)),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5),
        child: _SwapBtn(
          onTap: () {
            if (_commitDimensions()) _setCustom(customH, customW);
          },
        ),
      ),
      Expanded(child: _dimensionInput(width: false)),
      const SizedBox(width: 10),
      Tooltip(
        message: '${context.l10n.applyLabel} $customW×$customH',
        child: FilledButton(
          key: const ValueKey('resolution-confirm'),
          onPressed: _canApplyCustom
              ? () {
                  if (_commitDimensions()) _applySize(customW, customH);
                }
              : null,
          style: FilledButton.styleFrom(
            fixedSize: const Size.square(36),
            minimumSize: Size.zero,
            padding: EdgeInsets.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(9),
            ),
          ),
          child: const Icon(Icons.check, size: 20),
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final mine = ref.watch(resPresetsProvider);
    final (w, h) = ref.watch(
      generateProvider.select((s) => (s.params.width, s.params.height)),
    );
    final l = context.l10n;
    final scheme = context.scheme;
    final tabs = [...sizeTabs.keys, if (mine.isNotEmpty) _mineTab, _customTab];
    return SingleChildScrollView(
      key: const ValueKey('resolution-panel'),
      padding: EdgeInsets.all(widget.desktop ? 14 : 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  widget.desktop ? l.chooseRatio : l.resolution,
                  style: context.texts.titleMedium!.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              IconButton(
                tooltip: l.close,
                onPressed: () => Navigator.pop(context),
                constraints: const BoxConstraints.tightFor(
                  width: 32,
                  height: 32,
                ),
                padding: EdgeInsets.zero,
                icon: const Icon(Icons.close, size: 20),
              ),
            ],
          ),
          const Divider(height: 16),
          Row(
            children: [
              for (final t in tabs)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: TextButton(
                      onPressed: () => setState(() => tab = t),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        minimumSize: const Size(0, 32),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        backgroundColor: tab == t
                            ? scheme.primaryContainer
                            : null,
                        foregroundColor: tab == t
                            ? scheme.onPrimaryContainer
                            : scheme.onSurfaceVariant,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(_sizeLabel(l, t), maxLines: 1),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          if (_isCustom)
            _customGrid()
          else
            _PresetGrid(
              presets: tab == _mineTab
                  ? [for (final p in mine) _asSize(p)]
                  : sizeTabs[tab]!,
              isSelected: (p) => p.width == w && p.height == h,
              onTap: (p) => _applySize(p.width, p.height),
              onRemove: tab == _mineTab ? _remove : null,
            ),
          const Divider(height: 20),
          Tooltip(
            message: l.desktopFreeTier105MPOpusCoversA,
            child: _StatusStrip(
              width: _isCustom ? customW : w,
              height: _isCustom ? customH : h,
            ),
          ),
          if (_isCustom) ...[const SizedBox(height: 12), _dimensionRow()],
        ],
      ),
    );
  }
}

/// Built-in and saved resolutions share the same three-column card grid.
class _PresetGrid extends StatelessWidget {
  const _PresetGrid({
    required this.presets,
    required this.isSelected,
    required this.onTap,
    this.onRemove,
  });

  final List<SizePreset> presets;
  final bool Function(SizePreset) isSelected;
  final ValueChanged<SizePreset> onTap;
  final ValueChanged<SizePreset>? onRemove;

  static const _cols = 3;
  static const _gap = 10.0;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var r = 0; r < presets.length; r += _cols) ...[
          if (r > 0) const SizedBox(height: _gap),
          Row(
            children: [
              for (var c = 0; c < _cols; c++) ...[
                if (c > 0) const SizedBox(width: _gap),
                Expanded(
                  child: r + c < presets.length
                      ? _cell(presets[r + c])
                      : const SizedBox(),
                ),
              ],
            ],
          ),
        ],
      ],
    );
  }

  Widget _cell(SizePreset p) => _PresetCard(
    key: ValueKey('${p.width}x${p.height}'),
    preset: p,
    selected: isSelected(p),
    onTap: () => onTap(p),
    onRemove: onRemove == null ? null : () => onRemove!(p),
  );
}

class _StatusStrip extends StatelessWidget {
  const _StatusStrip({required this.width, required this.height});

  final int width;
  final int height;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final tier = classifyPixels(width, height);
    final (label, color) = switch (tier) {
      PixelTier.free => ('免费', scheme.tertiary),
      PixelTier.paid => ('付费', scheme.primary),
      PixelTier.over => ('超限', scheme.error),
    };
    return Row(
      children: [
        Text(
          '${megapixels(width, height).toStringAsFixed(2)} MP',
          style: mono(
            context,
            size: 12.5,
          ).copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(width: 8),
        Text('·', style: TextStyle(color: scheme.outline)),
        const SizedBox(width: 8),
        Text(
          formatAspectRatio(width, height),
          style: mono(
            context,
            size: 12.5,
          ).copyWith(color: scheme.onSurfaceVariant),
        ),
        const Spacer(),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          decoration: BoxDecoration(
            color: color.withValues(alpha: .14),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ),
      ],
    );
  }
}

/// 自定义档:拖拽画布(左上锚定,右下角把手定 W/H)+ 读数/交换 + 缩到免费/上限。
/// 触屏在画布任意处按下/拖动即把右下角吸到手指,较桌面「抓把手」更顺。
class _CanvasEditor extends StatelessWidget {
  const _CanvasEditor({
    required this.width,
    required this.height,
    required this.onChanged,
    required this.side,
  });

  final int width, height;
  final void Function(int w, int h) onChanged;
  final double side;

  void _fromLocal(Offset local, double side) {
    final fx = (local.dx / side).clamp(0.0, 1.0);
    final fy = (local.dy / side).clamp(0.0, 1.0);
    final w = snapDim((fx * _axisMax).round());
    final h = snapDim((fy * _axisMax).round());
    onChanged(w, h);
  }

  @override
  Widget build(BuildContext context) => SizedBox.square(
    key: const ValueKey('resolution-canvas'),
    dimension: side,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanDown: (d) => _fromLocal(d.localPosition, side),
      onPanUpdate: (d) => _fromLocal(d.localPosition, side),
      child: CustomPaint(
        painter: _ResCanvasPainter(
          width: width,
          height: height,
          scheme: context.scheme,
        ),
      ),
    ),
  );
}

class _ResCanvasPainter extends CustomPainter {
  _ResCanvasPainter({
    required this.width,
    required this.height,
    required this.scheme,
  });

  final int width;
  final int height;
  final ColorScheme scheme;

  Color _tierColor(PixelTier t) => switch (t) {
    PixelTier.free => _vizFree,
    PixelTier.paid => scheme.primary,
    PixelTier.over => _vizOver,
  };

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(10),
    );

    // 底 + 圆角裁剪
    canvas.drawRRect(rrect, Paint()..color = scheme.surfaceContainerHigh);
    canvas.save();
    canvas.clipRRect(rrect);

    // 网格(每 256 真实像素一线)
    final grid = Paint()
      ..color = scheme.onSurface.withValues(alpha: .06)
      ..strokeWidth = .5;
    for (double px = 256; px < _axisMax; px += 256) {
      final c = px / _axisMax * s;
      canvas.drawLine(Offset(c, 0), Offset(c, s), grid);
      canvas.drawLine(Offset(0, c), Offset(s, c), grid);
    }

    // 等像素双曲线:免费线(绿)/上限线(红)
    _hyperbola(canvas, s, kFreePixelThreshold, _vizFree, 3, 3);
    _hyperbola(canvas, s, kMaxTotalPixels, _vizOver, 4, 3);

    // 当前尺寸矩形(左上锚定)
    final rw = (width / _axisMax).clamp(0.0, 1.0) * s;
    final rh = (height / _axisMax).clamp(0.0, 1.0) * s;
    final tier = classifyPixels(width, height);
    final col = _tierColor(tier);
    final rect = Rect.fromLTWH(0, 0, rw, rh);
    canvas.drawRect(rect, Paint()..color = col.withValues(alpha: .18));
    canvas.drawRect(
      rect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..color = col,
    );

    // 右下角把手 + 抓握斜线
    final hc = Offset(rw, rh);
    final handle = RRect.fromRectAndRadius(
      Rect.fromCenter(center: hc, width: 22, height: 22),
      const Radius.circular(5),
    );
    canvas.drawRRect(handle, Paint()..color = col);
    final grip = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round
      ..color = Colors.white;
    for (final d in const [-4.0, 0.0, 4.0]) {
      canvas.drawLine(
        Offset(hc.dx + d, hc.dy + 4),
        Offset(hc.dx + 4, hc.dy + d),
        grip,
      );
    }

    canvas.restore();
    // 外描边
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = scheme.outlineVariant,
    );
  }

  /// w×h=pixels 的等像素线,离散成虚线路径(与 web buildHyperbolaPath 同构)。
  void _hyperbola(
    Canvas canvas,
    double s,
    int pixels,
    Color color,
    double on,
    double off,
  ) {
    final path = Path();
    var started = false;
    for (
      double xpx = kResSnapStep.toDouble();
      xpx <= _axisMax;
      xpx += kResSnapStep
    ) {
      final ypx = pixels / xpx;
      if (ypx > _axisMax) continue;
      final cx = xpx / _axisMax * s;
      final cy = ypx / _axisMax * s;
      if (!started) {
        path.moveTo(cx, cy);
        started = true;
      } else {
        path.lineTo(cx, cy);
      }
    }
    if (!started) return;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = color.withValues(alpha: .5);
    canvas.drawPath(_dash(path, on, off), paint);
  }

  Path _dash(Path src, double on, double off) {
    final out = Path();
    for (final m in src.computeMetrics()) {
      var dist = 0.0;
      while (dist < m.length) {
        out.addPath(m.extractPath(dist, dist + on), Offset.zero);
        dist += on + off;
      }
    }
    return out;
  }

  @override
  bool shouldRepaint(_ResCanvasPainter old) =>
      old.width != width || old.height != height || old.scheme != scheme;
}

/// 长宽之间的交换钮:小巧圆钮,替代 ×,省出横向空间。
class _SwapBtn extends StatelessWidget {
  const _SwapBtn({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return Tooltip(
      message: context.l10n.swapDimensions,
      child: Material(
        color: scheme.surfaceContainerHigh,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            width: 30,
            height: 30,
            child: Icon(
              Icons.swap_horiz,
              size: 16,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

class _PresetCard extends StatelessWidget {
  const _PresetCard({
    super.key,
    required this.preset,
    required this.selected,
    required this.onTap,
    this.onRemove,
  });

  final SizePreset preset;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final ratio = preset.width / preset.height;
    const box = 44.0;
    final w = ratio >= 1 ? box : box * ratio;
    final h = ratio >= 1 ? box / ratio : box;
    return AnimatedContainer(
      duration: Motion.fast,
      decoration: BoxDecoration(
        color: selected
            ? scheme.secondaryContainer
            : scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: selected ? scheme.primary : Colors.transparent,
          width: 2,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            InkWell(
              onTap:
                  classifyPixels(preset.width, preset.height) == PixelTier.over
                  ? null
                  : onTap,
              onLongPress: onRemove,
              onSecondaryTap: onRemove,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 12, 8, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      width: box,
                      height: box,
                      child: Center(
                        child: AnimatedContainer(
                          duration: Motion.fast,
                          width: w,
                          height: h,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(5),
                            border: Border.all(
                              color: selected ? scheme.primary : scheme.outline,
                              width: 2,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _sizeLabel(context.l10n, preset.name),
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.texts.bodySmall!.copyWith(
                        fontWeight: FontWeight.w600,
                        color: selected
                            ? scheme.onSecondaryContainer
                            : scheme.onSurface,
                      ),
                    ),
                    Text(
                      preset.ratio,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 10,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    Text(
                      '${preset.width}×${preset.height}',
                      textAlign: TextAlign.center,
                      style: mono(
                        context,
                        size: 9.5,
                        weight: FontWeight.w500,
                      ).copyWith(color: scheme.outline),
                    ),
                  ],
                ),
              ),
            ),
            if (onRemove != null)
              PositionedDirectional(
                top: 0,
                end: 0,
                child: IconButton(
                  tooltip: context.l10n.desktopDeleteSizePreset,
                  onPressed: onRemove,
                  constraints: const BoxConstraints.tightFor(
                    width: 26,
                    height: 26,
                  ),
                  padding: EdgeInsets.zero,
                  style: IconButton.styleFrom(
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  icon: const Icon(Icons.delete_outline, size: 15),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
