import CoreGraphics
import Testing

// 窓の位置と大きさの保存と復元。
// 画面の左下からの左上で持つこと、戻すときの大きさの下限と 16:9、保存してよいかの決まり、自動保存の記録の読み方

struct WindowPlacementTests {
    /// 外部画面の例（プライマリの左に並ぶ）
    private let external = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
    private let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)

    @Test func 画面の左下からの左上で持ち_同じ位置へ戻す() {
        let frame = CGRect(x: -1800, y: 200, width: 960, height: 640)
        let placement = WindowPlacement(frame: frame, screenFrame: external, displayUUID: "A")
        #expect(placement == WindowPlacement(displayUUID: "A", left: 120, top: 840, width: 960, height: 640))
        let size = placement.size(minimumSize: CGSize(width: 640, height: 420))
        #expect(CGRect(origin: placement.origin(on: external, size: size), size: size) == frame)
    }

    @Test func 保存先の画面が無ければ同じ左上をプライマリの基準で出す() {
        let placement = WindowPlacement(displayUUID: "A", left: 120, top: 840, width: 960, height: 640)
        #expect(placement.origin(on: primary, size: CGSize(width: 960, height: 640)) == CGPoint(x: 120, y: 200))
    }

    @Test func 小さすぎる大きさは下限まで広げる() {
        let placement = WindowPlacement(displayUUID: nil, left: 0, top: 500, width: 10, height: 900)
        #expect(placement.size(minimumSize: CGSize(width: 640, height: 420)) == CGSize(width: 640, height: 900))
    }

    @Test func 縦横比があれば幅から高さを決める() {
        let ratio = CGSize(width: 16, height: 9)
        let minimum = CGSize(width: 480, height: 270)
        // 高さがずれた記録でも 16:9 に戻す
        let placement = WindowPlacement(displayUUID: nil, left: 0, top: 800, width: 1280, height: 700)
        #expect(placement.size(minimumSize: minimum, aspectRatio: ratio) == CGSize(width: 1280, height: 720))
        // 幅が下限より小さければ下限の幅から
        let tiny = WindowPlacement(displayUUID: nil, left: 0, top: 800, width: 100, height: 50)
        #expect(tiny.size(minimumSize: minimum, aspectRatio: ratio) == CGSize(width: 480, height: 270))
    }

    @Test func 人が動かしたら今の画面を保存先にする() {
        let saved = WindowPlacement(displayUUID: "A", left: 0, top: 900, width: 960, height: 640)
        let updated = WindowPlacement.updated(saved: saved, frame: CGRect(x: 100, y: 100, width: 960, height: 640),
                                              screenFrame: primary, displayUUID: "B", userInitiated: true)
        #expect(updated?.displayUUID == "B")
        #expect(updated?.left == 100)
    }

    @Test func 人の操作でなければ保存先と違う画面では保存しない() {
        let saved = WindowPlacement(displayUUID: "A", left: 0, top: 900, width: 960, height: 640)
        let other = WindowPlacement.updated(saved: saved, frame: CGRect(x: 100, y: 100, width: 960, height: 640),
                                            screenFrame: primary, displayUUID: "B", userInitiated: false)
        #expect(other == nil)
        // 保存先と同じ画面なら位置を書き、保存先は変えない
        let same = WindowPlacement.updated(saved: saved, frame: CGRect(x: 100, y: 100, width: 960, height: 640),
                                           screenFrame: primary, displayUUID: "A", userInitiated: false)
        #expect(same?.displayUUID == "A")
        #expect(same?.left == 100)
    }

    @Test func 前と同じなら書かない() {
        let frame = CGRect(x: 100, y: 100, width: 960, height: 640)
        let saved = WindowPlacement(frame: frame, screenFrame: primary, displayUUID: "A")
        #expect(WindowPlacement.updated(saved: saved, frame: frame, screenFrame: primary, displayUUID: "A", userInitiated: true) == nil)
        // 保存が無ければ書く
        #expect(WindowPlacement.updated(saved: nil, frame: frame, screenFrame: primary, displayUUID: "A", userInitiated: false) == saved)
    }

    @Test func 自動保存の記録を読む() {
        #expect(WindowPlacement.frame(fromAutosave: "811 124 1107 685 0 0 2056 1290 ") == CGRect(x: 811, y: 124, width: 1107, height: 685))
        #expect(WindowPlacement.frame(fromAutosave: "-1800 200 960 540 -1920 0 1920 1080 ") == CGRect(x: -1800, y: 200, width: 960, height: 540))
        #expect(WindowPlacement.frame(fromAutosave: "1 2 0 3") == nil)
        #expect(WindowPlacement.frame(fromAutosave: "") == nil)
    }
}
