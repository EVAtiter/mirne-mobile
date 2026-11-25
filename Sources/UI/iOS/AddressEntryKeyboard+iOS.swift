import SwiftUI

extension View {
    /// アドレスの入力欄のキーボード（iOS 版）：数字と記号のキーボードで出す（IP アドレスは数字と「.」。
    /// デバイス記述の URL も入れられるよう、文字のキーボードへ切り替えられる形にする）。頭の大文字・自動修正はしない
    func addressEntryKeyboard() -> some View {
        keyboardType(.numbersAndPunctuation)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
    }
}
