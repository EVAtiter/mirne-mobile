import CoreGraphics
import Testing

// 視聴ウィンドウを標準の大きさに戻すときの置き場。
// 左上を保つこと、十分見えていれば動かさないこと、はみ出したら窓のある画面へ要求量だけ引き戻すこと

struct ViewerWindowPositioningTests {
    /// 画面の見える範囲（メニューバーと Dock を除いた帯の例）
    private let screen = CGRect(x: 0, y: 80, width: 1440, height: 795)
    private let standard = CGSize(width: 960, height: 540)

    @Test func 左上を保って大きさを替える() {
        // 左上が (100, 800) の窓：左端はそのまま、下端は上端から高さを引いた位置
        let origin = ViewerWindowPositioning.origin(keepingTopLeft: CGPoint(x: 100, y: 800), size: standard)
        #expect(origin == CGPoint(x: 100, y: 260))
    }

    @Test func 十分見えていれば動かさない() {
        // 右へ少しはみ出しているが、見える部分は要求量より大きい
        let origin = CGPoint(x: 800, y: 200)
        let resolved = ViewerWindowPositioning.resolvedOrigin(origin, windowSize: standard, visibleFrames: [screen], anchor: screen)
        #expect(resolved == origin)
    }

    @Test func 見える量が足りなければ要求量だけ引き戻す() {
        // 右へほとんど出ている：右端から要求量（160）だけ見える位置へ
        let resolved = ViewerWindowPositioning.resolvedOrigin(CGPoint(x: 1400, y: 200), windowSize: standard,
                                                              visibleFrames: [screen], anchor: screen)
        #expect(resolved == CGPoint(x: 1440 - 160, y: 200))
        // 上へ出ている：上端から要求量（120）だけ見える位置へ
        let above = ViewerWindowPositioning.resolvedOrigin(CGPoint(x: 100, y: 860), windowSize: standard,
                                                           visibleFrames: [screen], anchor: screen)
        #expect(above == CGPoint(x: 100, y: 875 - 120))
        // 左下へ出ている：窓の大きさから要求量を引いた分までは外に出てよい
        let below = ViewerWindowPositioning.resolvedOrigin(CGPoint(x: -2000, y: -2000), windowSize: standard,
                                                           visibleFrames: [screen], anchor: screen)
        #expect(below == CGPoint(x: -(960 - 160), y: 80 - (540 - 120)))
    }

    @Test func ほかの画面に十分見えていれば動かさない() {
        let right = CGRect(x: 1440, y: 0, width: 1920, height: 1055)
        let origin = CGPoint(x: 1500, y: 300)
        let resolved = ViewerWindowPositioning.resolvedOrigin(origin, windowSize: standard, visibleFrames: [screen, right], anchor: screen)
        #expect(resolved == origin)
    }

    @Test func 小さい窓では要求量を窓の大きさで頭打ちにする() {
        let small = CGSize(width: 100, height: 80)
        #expect(ViewerWindowPositioning.minVisible(for: small) == CGSize(width: 75, height: 60))
        #expect(ViewerWindowPositioning.minVisible(for: standard) == ViewerWindowPositioning.minVisibleOnRestore)
    }

    @Test func 常に最前面は全画面の間は効かせない() {
        #expect(ViewerWindowLevel.floats(alwaysOnTop: true, fullScreen: false))
        #expect(!ViewerWindowLevel.floats(alwaysOnTop: true, fullScreen: true))
        #expect(!ViewerWindowLevel.floats(alwaysOnTop: false, fullScreen: false))
        #expect(!ViewerWindowLevel.floats(alwaysOnTop: false, fullScreen: true))
    }

    @Test func 画面が無ければ決めない() {
        let resolved = ViewerWindowPositioning.resolvedOrigin(CGPoint(x: 5000, y: 5000), windowSize: standard, visibleFrames: [], anchor: nil)
        #expect(resolved == nil)
    }
}
