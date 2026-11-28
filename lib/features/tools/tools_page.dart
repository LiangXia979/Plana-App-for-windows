import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/store/ui_prefs.dart';
import '../../core/platform/desktop.dart';
import 'metadata_tool_page.dart';
import 'metadata_compare_page.dart';
import 'metadata_tool_link.dart';
import 'weight_convert_page.dart';
import '../../l10n/l10n.dart';

/// 工具箱的权重转换、图片元数据与图片比对页签。
/// 切换页签时保留已输入的内容与已选图片。
class ToolsPage extends ConsumerStatefulWidget {
  const ToolsPage({super.key});

  @override
  ConsumerState<ToolsPage> createState() => _ToolsPageState();
}

class _ToolsPageState extends ConsumerState<ToolsPage> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Widget _desktopBody(int tab, Widget tabs) {
    const insets = EdgeInsets.fromLTRB(16, 12, 16, 16);
    final editors = [
      WeightConvertView(desktopTabs: tabs),
      MetadataToolView(desktopTabs: tabs),
    ];
    return IndexedStack(
      sizing: StackFit.expand,
      index: tab == 2 ? 1 : 0,
      children: [
        Scrollbar(
          controller: _scroll,
          child: SingleChildScrollView(
            key: const PageStorageKey('desktop-tools-scroll'),
            controller: _scroll,
            padding: insets,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (i, editor) in editors.indexed)
                  Offstage(
                    offstage: tab != i,
                    child: TickerMode(
                      enabled: tab == i,
                      child: ExcludeFocus(excluding: tab != i, child: editor),
                    ),
                  ),
              ],
            ),
          ),
        ),
        LayoutBuilder(
          builder: (context, viewport) => SingleChildScrollView(
            primary: false,
            padding: insets,
            child: MetadataCompareView(
              desktopViewportHeight: viewport.maxHeight - insets.vertical,
              desktopTabs: tabs,
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final desktop = ref.watch(desktopModeProvider);
    final tab = ref.watch(
      uiPrefsProvider.select((p) => p.toolsTab.clamp(0, 2)),
    );
    ref.listen(singleMetadataRequestProvider, (_, _) {
      final toolsRoute = ModalRoute.of(context);
      Navigator.of(
        context,
      ).popUntil((route) => route == toolsRoute || route.isFirst);
      if (_scroll.hasClients) _scroll.jumpTo(0);
    });
    final selector = SegmentedButton<int>(
      segments: [
        ButtonSegment(
          value: 0,
          label: Text(l10nNow.weightConverter, maxLines: 1),
          icon: Icon(Icons.swap_horiz, size: 17),
        ),
        ButtonSegment(
          value: 1,
          label: Text(l10nNow.imageMetadata, maxLines: 1),
          icon: Icon(Icons.document_scanner_outlined, size: 17),
        ),
        ButtonSegment(
          value: 2,
          label: Text(l10nNow.compareImages, maxLines: 1),
          icon: const Icon(Icons.compare_outlined, size: 17),
        ),
      ],
      selected: {tab},
      onSelectionChanged: (s) {
        FocusManager.instance.primaryFocus?.unfocus();
        ref
            .read(uiPrefsProvider.notifier)
            .patch((p) => p.copyWith(toolsTab: s.first));
      },
      showSelectedIcon: false,
    );
    final tabs = SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: selector,
    );
    return Scaffold(
      appBar: desktop ? null : AppBar(title: Text(l10nNow.toolbox)),
      body: desktop
          ? _desktopBody(
              tab,
              Navigator.canPop(context)
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const BackButton(),
                        Flexible(child: tabs),
                      ],
                    )
                  : tabs,
            )
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 4, 14, 10),
                  child: tabs,
                ),
                Expanded(
                  child: IndexedStack(
                    index: tab,
                    children: const [
                      WeightConvertView(),
                      MetadataToolView(),
                      MetadataCompareView(),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}
