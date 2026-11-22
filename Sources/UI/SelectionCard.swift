import Observation
import SwiftUI

// 一覧で選んだ行の情報を、窓の中の一覧の右寄りに、選んだ行の高さで重ねるカード（録画と予約の画面で使う）。
//
// 前は一覧の右（iPad の縦向きは下）に区切った情報の欄を置いていたが、カードを重ねる形にして一覧を窓の幅いっぱいにした。
// 試作で決めたこと：
// - 文字と板（半透明の背景・枠・影）は 1 枚の絵にまとめてから置く。別々に動くと、文字が先に移って板が遅れてついてきた
// - 位置は上端で決める。中心で決めると、高さを測り直すたびに二段に動いた
// - 別の行を選んだら、動かさずにすぐその行の高さへ移す
// - 窓の上下からはみ出しそうなときは内側へ寄せる。選んだ行が見えなくなったら（スクロールで外れたら）カードも隠す

/// 一覧の見えている行の枠（窓の座標）。行が書き、カードだけが読む（一覧の本体は読まないので、スクロールで一覧を描き直さない）
@MainActor
@Observable
final class ListRowFrames<ID: Hashable> {
    var frames: [ID: CGRect] = [:]
    /// 出しているカードの枠（窓の座標。カードの外を押したかを見るため）
    var cardFrame: CGRect?
}

extension View {
    /// この行の枠を `store` に知らせる（見えなくなったら消す）
    func reportsRowFrame<ID: Hashable>(_ id: ID, into store: ListRowFrames<ID>) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { store.frames[id] = $0 }
            .onDisappear { store.frames[id] = nil }
    }

    /// カードの外を押したら `close` を呼ぶ。ただし一覧の行を押したときは閉じない（一覧の選択が変わり、カードがその行へ移る）。
    /// 押したことは窓の側で受ける（`OutsideTapMonitor`。一覧の上に SwiftUI のタップを重ねると行を選べなくなった）
    func closesSelectionCardOnOutsideTap<ID: Hashable>(rows: ListRowFrames<ID>, isOpen: Bool,
                                                      close: @escaping () -> Void) -> some View {
        background {
            if isOpen {
                OutsideTapMonitor { location in
                    if let card = rows.cardFrame, card.contains(location) { return }
                    if rows.frames.values.contains(where: { $0.contains(location) }) { return }
                    close()
                }
            }
        }
    }
}

/// カードの中身に使える高さ（一覧の高さから上下の間を引いたもの。カードを置く側が渡す）
private struct SelectionCardMaxHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = .infinity
}

extension EnvironmentValues {
    var selectionCardMaxHeight: CGFloat {
        get { self[SelectionCardMaxHeightKey.self] }
        set { self[SelectionCardMaxHeightKey.self] = newValue }
    }
}

/// カードの寸法（体感の値。画面で見て決める）
enum SelectionCardLayout {
    /// カードの幅（OS ごとに違う。`SelectionCardPlatform`）
    static var width: CGFloat { SelectionCardPlatform.width }
    /// 一覧の右端からカードまで
    static let trailingInset: CGFloat = 16
    /// 一覧の上下の端からカードまでの最小の間
    static let verticalInset: CGFloat = 8
    static let cornerRadius: CGFloat = 12
    static let shadowOpacity: Double = 0.18
    static let shadowRadius: CGFloat = 10
    static let shadowOffset: CGFloat = 3
    /// 中身の余白
    static let padding: CGFloat = 14
    /// 区画どうしの間
    static let spacing: CGFloat = 10
    /// 一覧が低くても、中身のスクロールに残す最小の高さ
    static let minimumScrollHeight: CGFloat = 80
}

/// 一覧に重ねるカード。`id` の行の高さに置く。行が見えていなければ出さない
struct SelectionCardOverlay<ID: Hashable, Card: View>: View {
    let id: ID?
    let rows: ListRowFrames<ID>
    @ViewBuilder let card: (ID) -> Card
    /// カードの高さ（中身から測る）
    @State private var cardHeight: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            if let id, let rowFrame = rows.frames[id] {
                let origin = geo.frame(in: .global).origin
                let maxTop = max(SelectionCardLayout.verticalInset, geo.size.height - cardHeight - SelectionCardLayout.verticalInset)
                let top = min(max(rowFrame.minY - origin.y, SelectionCardLayout.verticalInset), maxTop)
                // 高さは中身に合わせる（maxHeight の枠で包むと、中身によらずその高さまで広がり、
                // 大きな板の真ん中に情報が出た）。使える高さは環境で渡し、中身の側でスクロールの高さを抑える
                card(id)
                    .frame(width: min(SelectionCardLayout.width, geo.size.width - 2 * SelectionCardLayout.trailingInset))
                    .environment(\.selectionCardMaxHeight, geo.size.height - 2 * SelectionCardLayout.verticalInset)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: SelectionCardLayout.cornerRadius))
                    .overlay(RoundedRectangle(cornerRadius: SelectionCardLayout.cornerRadius).strokeBorder(.separator))
                    .compositingGroup()
                    .shadow(color: .black.opacity(SelectionCardLayout.shadowOpacity), radius: SelectionCardLayout.shadowRadius,
                            y: SelectionCardLayout.shadowOffset)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cardHeight = $0 }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.trailing, SelectionCardLayout.trailingInset)
                    .offset(y: top)
                    .transaction { $0.animation = nil }
                    // 置いたカードの枠（窓の座標）を知らせる。外を押したかを見るのに使う
                    .onChange(of: cardRect(origin: origin, size: geo.size, top: top), initial: true) { _, rect in rows.cardFrame = rect }
                    .onDisappear { rows.cardFrame = nil }
            }
        }
    }
}

extension SelectionCardOverlay {
    /// 置いたカードの枠（窓の座標）
    func cardRect(origin: CGPoint, size: CGSize, top: CGFloat) -> CGRect {
        let width = min(SelectionCardLayout.width, size.width - 2 * SelectionCardLayout.trailingInset)
        return CGRect(x: origin.x + size.width - SelectionCardLayout.trailingInset - width, y: origin.y + top,
                      width: width, height: cardHeight)
    }
}

/// カードの枠：上に題と閉じるボタン、中に情報（長ければスクロール）、下に操作のボタン。高さは中身に合わせる
struct SelectionCardContent<Body: View, Actions: View>: View {
    let title: String
    let close: () -> Void
    @ViewBuilder let content: Body
    @ViewBuilder let actions: Actions
    @Environment(\.selectionCardMaxHeight) private var maxHeight
    /// 中身（スクロールの中）の高さ
    @State private var contentHeight: CGFloat = 0
    /// 題の段の高さ
    @State private var headerHeight: CGFloat = 0
    /// 操作のボタンの段の高さ
    @State private var actionsHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: SelectionCardLayout.spacing) {
            // 閉じるボタンは題の 1 行目の高さにそろえ、右上の角に置く
            HStack(alignment: .top, spacing: 8) {
                Text(title).scaledFont(.headline, weight: .bold).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: close) {
                    Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("閉じる")
                .help("閉じる")
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
            ScrollView {
                VStack(alignment: .leading, spacing: SelectionCardLayout.spacing) { content }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .frame(height: min(contentHeight, scrollLimit))
            actions
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { actionsHeight = $0 }
        }
        .padding(SelectionCardLayout.padding)
    }

    /// スクロールに使える高さ（使える高さから題・ボタン・余白を引いたもの。少なくとも数行は見せる）
    private var scrollLimit: CGFloat {
        let chrome = headerHeight + actionsHeight + 2 * SelectionCardLayout.padding + 2 * SelectionCardLayout.spacing
        return max(SelectionCardLayout.minimumScrollHeight, maxHeight - chrome)
    }
}

/// カードの中の「項目名と値」の 1 行
struct SelectionCardField: View {
    let label: String
    let value: String

    init(_ label: String, value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .scaledFont(.callout)
    }
}
