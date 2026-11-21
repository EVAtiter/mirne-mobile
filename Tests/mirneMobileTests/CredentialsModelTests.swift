import Foundation
import Testing

// 資格情報の取り込み・確かめ・削除。
// 素材は試験用の権威鍵で作った架空のペア（DTCPTestVectors）。

private typealias V = DTCPTestVectors

@MainActor
@Suite("資格情報の画面のモデル")
struct CredentialsModelTests {
    func model() -> CredentialsModel {
        CredentialsModel(store: DTCPMemoryCredentialStore(authorityKeys: testAuthority), environment: [:])
    }

    var certificate: Data { Data(hexBytes(V.katSinkCert)) }
    var privateKey: Data { Data(hexBytes(V.katSinkPriv)) }

    @Test("初めは取り込んでいない。2 つのバイナリのファイルを取り込むと、機器 ID と指紋の要約になる")
    func importBinaryFiles() async {
        let model = model()
        await model.load()
        #expect(model.summary == .loaded(nil))
        await model.importFiles([certificate, privateKey])
        #expect(model.error == nil)
        let summary = model.summary.value.flatMap { $0 }
        #expect(summary?.deviceIDHex.isEmpty == false)
        #expect(summary?.certificateSHA1Hex.isEmpty == false)
        #expect(!model.isWorking)
    }

    @Test("ファイルの順は問わず、16 進の文字のファイルでもよい")
    func importSwappedHexFiles() async {
        let model = model()
        await model.importFiles([Data(V.katSinkPriv.utf8), Data((V.katSinkCert + "\n").utf8)])
        #expect(model.error == nil)
        #expect(model.summary.value.flatMap { $0 } != nil)
    }

    @Test("合わない鍵・1 つだけのファイルは保存せず、誤りを出す。誤りの文に値を入れない")
    func rejectsInvalid() async {
        let model = model()
        await model.importFiles([certificate, Data(hexBytes(V.katSrcPriv))])   // 別の機器の秘密鍵
        #expect(model.error != nil)
        #expect(model.summary == .loaded(nil))
        let text = (model.error?.title ?? "") + (model.error?.message ?? "")
        #expect(!text.contains(V.katSrcPriv) && !text.contains(V.katSinkCert))
        await model.importFiles([certificate])
        #expect(model.error != nil)
        #expect(model.summary == .loaded(nil))
    }

    @Test("credentials.env から取り込み、削除できる")
    func dotEnvAndDelete() async {
        let model = model()
        await model.importDotEnv(Data("PYDTCPIP_CERTIFICATE=\(V.katSinkCert)\nPYDTCPIP_PRIVATE_KEY=\(V.katSinkPriv)\n".utf8))
        #expect(model.error == nil)
        #expect(model.summary.value.flatMap { $0 } != nil)
        await model.delete()
        #expect(model.summary == .loaded(nil))
    }

    @Test("取り込み直すと前の組を置き換える（失敗した取り込みは前の組を残す）")
    func reimport() async {
        let model = model()
        await model.importFiles([certificate, privateKey])
        let before = model.summary
        await model.importFiles([certificate, Data(hexBytes(V.katSrcPriv))])
        #expect(model.error != nil)
        #expect(model.summary == before)
    }
}
