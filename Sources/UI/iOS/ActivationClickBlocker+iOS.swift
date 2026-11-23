import SwiftUI

/// 窓が前面でないときのクリックを、窓を前面にするだけにする（iPhone・iPad 版）。
/// タッチには「前面でない窓の最初のクリック」が無いので、何もしない
struct ActivationClickBlocker: View {
    var body: some View { EmptyView() }
}
