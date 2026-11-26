import SwiftUI

/// 主ウインドウの各画面の上の帯。番組表の帯（`GuideToolbar`）と同じ位置・寸法で、左に画面の操作、右に一覧の状態と「ライブ」「設定」を置く。
///
/// 番組表に合わせて、予約・録画・情報にも同じ帯を置いた（2026-11-21）。右端には「ライブ」「設定」も置く（2026-11-23 から。
/// iPhone の縦向き・iPad の狭い分割は上の帯の右端）。「更新」は 2026-11-24 に外した（各画面が nasne の一覧の世代を見回って自分で読み直す）
struct ScreenActionBar<Leading: View>: View {
    /// 右に出す一覧の状態（録画の件数。窓が狭くて入らなければ出さない）
    var status: String? = nil
    /// 左の操作があるか（無い画面〔情報・メディアの種類を選ぶ画面〕で、ほかにも載せるものが無ければ帯を出さない）
    var hasLeading = true
    @ViewBuilder let leading: Leading

    /// 帯の中央に出す画面の名前（上の帯を隠しているとき。主画面が配る）
    @Environment(\.mainBarTitle) private var title
    /// 右端の「ライブ」「設定」（iPhone の縦向き・iPad の狭い分割では上の帯に出すので配られない）
    @Environment(\.mainBarAccessories) private var accessories
    /// 帯の中央に置く画面の切り替え（Mac。主画面が配る）
    @Environment(\.mainBarSwitcher) private var switcher

    /// 載せるものが何も無いか（左の操作・一覧の状態・画面の名前・「ライブ」「設定」・切り替えのどれも無い）。
    /// 「更新」を外した後、iPhone の縦向きの情報の画面などで、空の帯と横線だけが残った（2026-11-24）
    private var isEmpty: Bool { !hasLeading && status == nil && title == nil && accessories == nil && switcher == nil }

    var body: some View {
        if !isEmpty { bar }
    }

    private var bar: some View {
        VStack(spacing: 0) {
            Group {
                if let switcher {
                    MainBarSwitcherRow(selection: switcher) {
                        HStack(spacing: ScreenActionBarLayout.spacing) { leading }
                    } trailing: { showsStatus in
                        HStack(spacing: ScreenActionBarLayout.spacing) {
                            if showsStatus, let status { BarStatusText(text: status) }
                            MainBarAccessoryButtons()
                        }
                    }
                } else if let title {
                    // 画面の名前を中央に。入らなければ名前を出さない形にする
                    ViewThatFits(in: .horizontal) {
                        CenteredRow(spacing: ScreenActionBarLayout.spacing) {
                            // 左の操作が無い画面（情報）でも 3 つに数えるよう、器に入れる
                            HStack(spacing: ScreenActionBarLayout.spacing) { leading }
                            MainBarTitle(text: title)
                            HStack(spacing: ScreenActionBarLayout.spacing) {
                                if let status { BarStatusText(text: status) }
                                MainBarAccessoryButtons()
                            }
                        }
                        row
                    }
                } else {
                    row
                }
            }
            .screenActionBarPadding()
            Divider()
        }
    }

    /// 名前を出さない帯（左の操作・一覧の状態・右端の「ライブ」「設定」）
    private var row: some View {
        HStack(spacing: ScreenActionBarLayout.spacing) {
            ScreenActionBarRow(spacing: ScreenActionBarLayout.spacing) {
                leading
                BarStatusText(text: status ?? "")
            }
            MainBarAccessoryButtons()
        }
    }
}

/// 帯の状態の文字（録画の件数）。帯のボタンの文字と同じ大きさにする（2026-11-21）。
/// ボタンの文字は主ウインドウの文字の倍率がかからず、部品の大きさ（「標準」は regular・「大きい」は large）の macOS の文字の大きさで描かれる。
/// 前は倍率をかけた callout で、ボタンの文字より大きく見えた
struct BarStatusText: View {
    let text: String
    @Environment(\.controlSize) private var controlSize

    var body: some View {
        Text(text)
            // 文字の大きさは OS ごと（macOS は部品の大きさの文字、iPad は配られた文字のまま）
            .barStatusFont(controlSize)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

/// 帯の 1 段の並べ方（左の操作・一覧の状態。左の操作は無いこともある）。左の操作は左に寄せ、一覧の状態は右に寄せる。
/// 一覧の状態は、左の操作が本来の幅で入り、さらに一覧の状態も入るときだけ出す（入らなければ出さない。2026-11-21）。
/// `ViewThatFits` で包む形では、左の操作が縮める分を数えずに決めるので、最小の窓でも一覧の状態が残って帯がはみ出した
struct ScreenActionBarRow: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        let width = proposal.width ?? subviews.map { $0.sizeThatFits(.unspecified).width }.reduce(0, +)
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        // 最後が一覧の状態。左の操作が無い（EmptyView）ときは部品が 1 つになる（情報の画面）
        guard let status = subviews.last else { return }
        let leading = subviews.count >= 2 ? subviews[0] : nil
        let statusSize = status.sizeThatFits(.unspecified)
        // 左の操作の本来の幅は、十分に広い幅を渡して測る（.unspecified だと、中の ViewThatFits が詰めた形の幅を返し、
        // 件数を出すために「番組名でまとめる」が絵だけになった。件数はいちばん後回し。2026-11-21）
        let leadingIdeal = leading?.sizeThatFits(ProposedViewSize(width: .infinity, height: nil)).width ?? 0
        var right = bounds.maxX
        // 一覧の状態：左の操作が本来の幅で入るときだけ
        let showsStatus = statusSize.width > 0 && leadingIdeal + spacing + statusSize.width + spacing <= right - bounds.minX
        if showsStatus {
            let origin = CGPoint(x: right - statusSize.width, y: bounds.midY - statusSize.height / 2)
            status.place(at: origin, proposal: ProposedViewSize(statusSize))
            right = origin.x - spacing
        } else {
            status.place(at: CGPoint(x: bounds.maxX, y: bounds.midY), proposal: .zero)
        }
        // 左の操作は残りの幅で（入らなければ左の操作が縮める・省く）
        guard let leading else { return }
        let available = max(0, right - bounds.minX)
        let leadingSize = leading.sizeThatFits(ProposedViewSize(width: available, height: bounds.height))
        leading.place(at: CGPoint(x: bounds.minX, y: bounds.midY - leadingSize.height / 2),
                      proposal: ProposedViewSize(width: min(leadingSize.width, available), height: leadingSize.height))
    }
}

/// 各画面の帯の右端に出す主画面の操作（「ライブ」「設定」。2026-11-23 から Mac・iPad の広い幅・iPhone の横向きで出す。
/// iPhone の縦向き・iPad の狭い分割は、各画面の帯では幅が足りないので上の帯〔ナビゲーションの帯〕の右端に出し、これは配らない）
struct MainBarAccessories {
    /// ライブで見る（前に見た局）。視聴の画面を開けなければ nil
    let watchLive: (() -> Void)?
    let liveDisabled: Bool
    let openSettings: () -> Void
}

/// 切り替えを中央に置く帯の並べ方（Mac）。左に画面の操作、中央に切り替え、右に一覧の状態と「ライブ」「設定」。
/// 入らなければ一覧の状態を省き、それでも入らなければ切り替えを絵だけにする（2026-11-24 の試作）
struct MainBarSwitcherRow<Leading: View, Trailing: View>: View {
    let selection: Binding<MainSection>
    @ViewBuilder let leading: () -> Leading
    /// 右の部品（引数は一覧の状態を出すか）
    @ViewBuilder let trailing: (Bool) -> Trailing

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(showsStatus: true, showsTitles: true)
            row(showsStatus: false, showsTitles: true)
            row(showsStatus: false, showsTitles: false)
            // それでも入らなければ中央に揃えず詰めて並べる
            HStack(spacing: ScreenActionBarLayout.spacing) {
                leading()
                Spacer(minLength: 0)
                MainTabBar(selection: selection, inline: true, showsTitles: false)
                Spacer(minLength: 0)
                trailing(false)
            }
        }
    }

    private func row(showsStatus: Bool, showsTitles: Bool) -> some View {
        CenteredRow(spacing: ScreenActionBarLayout.spacing) {
            leading()
            MainTabBar(selection: selection, inline: true, showsTitles: showsTitles)
            trailing(showsStatus)
        }
    }
}

extension EnvironmentValues {
    /// nasne に届くか（主画面が配る。つながっていない間は nasne と通信する操作を押せなくし、オフラインなら「情報」に印を出す。
    /// 主画面の外〔視聴ウインドウなど〕は配らないのでつながっている扱い）
    @Entry var nasneLink = NasneLinkState.online
    /// いま見ている nasne の呼び名（主画面が配る。予約のシートの「予約先」の行に出す。主画面の外では無い）
    @Entry var currentNasneName: String? = nil
    /// 各画面の帯の中央に置く画面の切り替え（Mac の主画面が配る。主画面の外・iOS では無い）
    @Entry var mainBarSwitcher: Binding<MainSection>? = nil
    /// 各画面の帯の右端に出す「ライブ」「設定」（主画面が配る。主画面の外〔番組表のウインドウなど〕では無い）
    @Entry var mainBarAccessories: MainBarAccessories? = nil
    /// 各画面の帯の中央に出す画面の名前（上の帯を隠しているときだけ。録画は検索の欄で幅が足りないので出さない。主画面が配る）
    @Entry var mainBarTitle: String? = nil
    /// 上の帯（画面の名前）を隠しているか（iPad の広い幅と iPhone の横向き。各画面の帯が画面の上端に来るので、上の余白を詰めない。主画面が配る）
    @Entry var mainTitleBarHidden = false
    /// 上の帯に画面の操作も置いているか（iPhone の縦向き・iPad の狭い分割。予約の「マニュアル予約」は上の帯の左に出し、各画面の帯には置かない。主画面が配る）
    @Entry var mainTitleBarHasActions = false
}

/// 帯の中央の画面の名前（ナビゲーションの帯の名前と同じ形）
struct MainBarTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.headline)
            .lineLimit(1)
            .fixedSize()
    }
}

/// 帯の右端の「ライブ」「設定」（どの OS も絵だけ。名前は `help` で出す。Mac も 2026-11-24 から絵だけ。前は広い窓で絵と文字）
struct MainBarAccessoryButtons: View {
    @Environment(\.mainBarAccessories) private var accessories

    var body: some View {
        if let accessories {
            HStack(spacing: ScreenActionBarLayout.spacing) {
                if let watchLive = accessories.watchLive {
                    Button { watchLive() } label: { Label("ライブ", systemImage: LiveSymbol.watch) }
                        .disabled(accessories.liveDisabled)
                        .help("ライブで見る（前に見た局）")
                }
                Button(action: accessories.openSettings) { Label("設定", systemImage: MainToolbarSymbol.settings) }
                    .help("設定を開く")
            }
            .labelStyle(.iconOnly)
            // iOS は 1 つの丸い板にまとめる（ナビゲーションの帯のボタンのまとまりと同じ形。OS ごと）
            .barButtonGroupChrome()
        }
    }
}

/// 帯の検索の欄の形（録画の検索の欄。帯の高さを揃える見本にも使う）
struct BarSearchFieldChrome<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: BarSearchFieldLayout.iconSpacing) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            content
        }
        .padding(.horizontal, BarSearchFieldLayout.horizontalPadding)
        .padding(.vertical, BarSearchFieldLayout.verticalPadding)
        .background(.background, in: RoundedRectangle(cornerRadius: BarSearchFieldLayout.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: BarSearchFieldLayout.cornerRadius).strokeBorder(.separator))
    }
}

/// 帯の検索の欄（iOS で画面の帯の中に置く。録画・番組表で同じもの。Mac は窓のタイトルの帯の `searchable`〔`mainToolbarSearch`〕）。
/// 文字があるときは右に消すボタン。一覧を送り始めたら閉じるのは、それぞれの一覧に `scrollDismissesKeyboard` を付ける
struct BarSearchField: View {
    let prompt: String
    @Binding var text: String
    var focused: FocusState<Bool>.Binding

    var body: some View {
        BarSearchFieldChrome {
            TextField(prompt, text: $text)
                .focused(focused)
                .textFieldStyle(.plain)
                // キーボードの改行は「検索」と出し、押したらキーボードを閉じる（iPhone のキーボードには閉じるボタンが無い。2026-11-24）
                .submitLabel(.search)
                .onSubmit { focused.wrappedValue = false }
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("検索の文字を消す")
            }
        }
    }
}

/// 帯の検索の欄の寸法
enum BarSearchFieldLayout {
    static let iconSpacing: CGFloat = 4
    static let horizontalPadding: CGFloat = 6
    static let verticalPadding: CGFloat = 3
    static let cornerRadius: CGFloat = 6
}

/// 帯の段の高さの見本（見えない。幅 0）：帯に入る背の高い部品（録画の検索の欄・番組表の前後の日のボタン・メニューの選択・ボタンの形の切り替え）を重ねる。
/// どの画面の帯にも入れるので、段の高さは中身によらずこの高さ以上になり、右端の操作が同じ位置に来る。
/// 文字の大きさの設定が変わっても部品と一緒に伸びる（決め打ちの高さでは、iPad の実機で揃わなかった。2026-11-23）
private struct BarRowHeightProbe: View {
    @Environment(\.usesCompactLayout) private var compact

    var body: some View {
        ZStack {
            BarSearchFieldChrome { TextField("番組名・局名", text: .constant("")).textFieldStyle(.plain) }
            ControlGroup {
                Button("前の日", systemImage: "chevron.left") {}
                Button("次の日", systemImage: "chevron.right") {}
            }
            .labelStyle(.iconOnly)
            .fixedSize()
            // メニューの選択（録画の絞り込み・並べ替え、番組表の日付）と、ボタンの形の切り替え（「番組名でまとめる」。ふつうのボタンより背が高い）。
            // 狭い幅では見本にメニューの選択を入れない（入れると、番組表の日付のメニューの ⌃⌄ の印が消えた。狭い幅は段の高さの下限で揃う）
            if !compact {
                Picker("見本", selection: .constant(0)) { Text("すべて").tag(0) }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
            }
            Toggle(isOn: .constant(false)) { Label("番組名でまとめる", systemImage: "rectangle.stack") }
                .toggleStyle(.button)
                .fixedSize()
        }
        .frame(width: 0)
        .clipped()
        .hidden()
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

/// 各画面の上の帯の寸法（番組表の帯と同じ値。番組表の帯もこれを使う）
enum ScreenActionBarLayout {
    /// 帯の中の部品の間
    static let spacing: CGFloat = 12
    static let horizontalPadding: CGFloat = 12
    static let verticalPadding: CGFloat = 8
    /// 狭い幅の帯の上の余白（帯の上にはナビゲーションの帯の余白があり、上下で同じ 8 にすると上が空いて見えた。2026-11-23）
    static let compactTopPadding: CGFloat = 0
    /// 狭い幅の帯の段の高さ（中身でなくこの高さに揃え、どの画面でも右端の操作が同じ位置に来るようにする。2026-11-23。
    /// いちばん高い録画の検索の欄（約 37pt）が入る高さ。32 では録画と番組表の帯だけ高くなり、揃わなかった）
    static let compactRowHeight: CGFloat = 38
}

extension View {
    /// 上の帯の段の余白（録画・予約・情報の帯と番組表の帯で同じものを使う）。狭い幅では段の高さを揃え、上の余白を詰める
    func screenActionBarPadding() -> some View {
        modifier(ScreenActionBarPadding())
    }
}

private struct ScreenActionBarPadding: ViewModifier {
    @Environment(\.usesCompactLayout) private var compact
    /// 上の帯を隠しているか（帯が画面の上端に来るので、上の余白を詰めない）
    @Environment(\.mainTitleBarHidden) private var titleBarHidden

    func body(content: Content) -> some View {
        HStack(spacing: 0) {
            // 段の高さを揃える見本（OS ごと。iOS は入れる）
            if ScreenActionBarPlatform.alignsRowHeight { BarRowHeightProbe() }
            content
        }
            .frame(minHeight: compact ? ScreenActionBarLayout.compactRowHeight : nil)
            .padding(.horizontal, ScreenActionBarLayout.horizontalPadding)
            // iPadOS の窓の左上の角（窓を操作するボタンの場所）を避ける（OS ごと）
            .avoidsWindowControls()
            .padding(.top, compact && !titleBarHidden ? ScreenActionBarLayout.compactTopPadding : ScreenActionBarLayout.verticalPadding)
            .padding(.bottom, ScreenActionBarLayout.verticalPadding)
    }
}
