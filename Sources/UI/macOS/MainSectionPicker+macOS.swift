import AppKit
import SwiftUI

/// 中央の切り替え。項目にシンボルと文字を並べる（窓が狭いときはシンボルだけ）。
///
/// SwiftUI の segmented の Picker は、Label を渡しても絵を出さず（文字だけになった）、文字に埋め込んだ絵も出さなかった（2026-11-21）。
/// AppKit の NSSegmentedControl は項目に絵と文字の両方を設定すると並べて出すので、それを載せる。iPad 版では iPad の部品で作る
struct MainSectionPicker: NSViewRepresentable {
    @Binding var selection: MainSection
    /// 文字も出すか（窓が狭ければシンボルだけ）
    let showsTitles: Bool

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.segmentCount = MainSection.allCases.count
        control.trackingMode = .selectOne
        // 項目の幅は中身に合わせる（均等に広げない）
        control.segmentDistribution = .fit
        control.target = context.coordinator
        control.action = #selector(Coordinator.changed(_:))
        control.setAccessibilityLabel("画面")
        for (index, section) in MainSection.allCases.enumerated() {
            let image = NSImage(systemSymbolName: section.symbol, accessibilityDescription: section.title)
            control.setImage(image, forSegment: index)
            control.setImageScaling(.scaleProportionallyDown, forSegment: index)
            control.setToolTip(section.title, forSegment: index)
        }
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        var labelsChanged = false
        for (index, section) in MainSection.allCases.enumerated() {
            let label = showsTitles ? section.title : ""
            guard control.label(forSegment: index) != label else { continue }
            control.setLabel(label, forSegment: index)
            // 幅は中身に合わせる（0）
            control.setWidth(0, forSegment: index)
            labelsChanged = true
        }
        // 文字を省いた・戻したら大きさを測り直させる（測り直さないと、文字を省いても項目の幅が前のまま残った。2026-11-21）
        if labelsChanged { control.invalidateIntrinsicContentSize() }
        if let index = MainSection.allCases.firstIndex(of: selection), control.selectedSegment != index {
            control.selectedSegment = index
        }
    }

    /// 大きさは部品の中身から決める（文字を省いた・戻したときに SwiftUI が聞き直す。intrinsicContentSize だけでは、
    /// 文字を省いても幅が前のまま残り、戻すと文字が切れた。2026-11-21）
    func sizeThatFits(_ proposal: ProposedViewSize, nsView control: NSSegmentedControl, context: Context) -> CGSize? {
        control.intrinsicContentSize
    }

    @MainActor
    final class Coordinator: NSObject {
        var selection: Binding<MainSection>

        init(selection: Binding<MainSection>) {
            self.selection = selection
        }

        @objc func changed(_ sender: NSSegmentedControl) {
            let all = MainSection.allCases
            guard all.indices.contains(sender.selectedSegment) else { return }
            selection.wrappedValue = all[sender.selectedSegment]
        }
    }
}
