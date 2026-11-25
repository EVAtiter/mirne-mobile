import Foundation
import ImageIO

// mirne mobile の計測用のコマンド（mirne の mirne-probe に倣う）。配布物には含めない。
//
//   mirne-mobile-probe discover [--scan]
//   mirne-mobile-probe info      --host <nasne>
//   mirne-mobile-probe titles    --host <nasne>
//   mirne-mobile-probe schedules --host <nasne>
//   mirne-mobile-probe epg       --host <nasne> [--store <SQLite のパス>]
//   mirne-mobile-probe credentials import --cert <ファイル> --key <ファイル>   （ペアを Keychain に取り込む）
//   mirne-mobile-probe credentials import --env <pydtcpip の credentials.env>   （同じペアを 1 つのファイルから）
//   mirne-mobile-probe credentials show | delete
//   mirne-mobile-probe stream    --host <nasne> [--pick shortest|longest|<番号>] [--quality dr|x3|mobile]
//                                [--seconds 20] [--max-mib 256] [--verbose] [--seek <秒> | --range <バイト>]
//                                [--play [--pause-at <秒> --pause-for <秒>]]
//   mirne-mobile-probe head      --host <nasne> [--pick shortest|longest|<番号>] [--quality dr|x3|mobile]
//                                [--seek <秒>] [--range <バイト>]   （資格情報は要らない）
//   mirne-mobile-probe live      --host <nasne>                    （Browse だけ。ライブの res には何も送らない）
//   mirne-mobile-probe play      --file <TS> [--seconds 15] [--pause-at <秒> --pause-for <秒>]   （nasne に何も送らない）
//   mirne-mobile-probe extras    --host <nasne> [--pick shortest|longest|<番号>]   （pydtcpip の口を GET で試す。値は出さない）
//   mirne-mobile-probe scpd      --host <nasne> [--action <名前の一部>]   （SOAP のサービスの説明を GET で読む）
//   mirne-mobile-probe delete-title --host <nasne> --at "yyyy-MM-dd HH:mm" [--send]   （★書き込み。試しの録画を 1 件消す。合意を取ってから）
//   mirne-mobile-probe protect-title --host <nasne> --at "yyyy-MM-dd HH:mm" [--send --protect|--unprotect]   （★書き込み。試しの録画の保護を 1 回切り替える。合意を取ってから）
//   mirne-mobile-probe resume-position --host <nasne> --at "yyyy-MM-dd HH:mm" [--send --seconds <秒>]   （★書き込み。試しの録画の再開位置を 1 回書く。合意を取ってから）
//   mirne-mobile-probe p6        --host <nasne> [--chapter-limit 60] [--metadata-samples 5]   （1.1.0 の機能の下調べ。読み取りだけ）
//   mirne-mobile-probe fake-nasne [--udn uuid:…] [--name <本体名>] [--model nasne|buffalo-nasne] [--mac <MAC>]   （偽の nasne を待ち受ける。nasne に何も送らない）
//   mirne-mobile-probe view      [--file <TS> [--snapshot <PNG> --snapshot-at <秒>]] [--quality …] [--pick …] [--seek <秒>]
//                                [--seconds 30] [--deinterlace adaptive|bob|weave] [--mute]   （窓を開いて描く）
//
// --host の代わりに環境変数 MIRNE_NASNE_HOST でもよい。
// nasne には読み取りしか送らない（PINVerify と EPGGet は POST だが、どちらも状態を変えない）。例外は delete-title・protect-title・resume-position・repeat-schedule の --send だけ。
// 出力に機器の固有値（MAC アドレス・IP アドレス・HDD のシリアル・B-CAS のカード ID・UDN）、地域、
// 局名、番組名、PIN、トークンを出さない。件数と形だけを出す。

/// サブコマンドの一覧（名前と説明）
let subcommands: [(name: String, summary: String)] = [
    ("discover", "SSDP で nasne を探す（--scan を付けたときだけ自分の /24 も走査する）"),
    ("info", "登録の確認（PINVerify）と本体の情報"),
    ("titles", "録画の一覧（xsrs と DIDL の結合）"),
    ("schedules", "予約の一覧"),
    ("epg", "番組表を取って EPGStore に入れる"),
    ("credentials", "資格情報ペアを Keychain に取り込む・要約を見る・消す（import / show / delete）"),
    ("stream", "録画を HEAD → AKE → GET → PCP の復号で受け、TS の中身を数える（ディスクに書かない）"),
    ("head", "録画の配信 URL に HEAD だけを送り、シークの申告と見出しの形を見る（シークの下調べ。資格情報は要らない）"),
    ("live", "ライブの局の一覧を Browse で読む（チューナーは動かさない）"),
    ("media", "共有フォルダーの動画・音楽・写真の一覧を Browse で読む（種類ごとの木をたどって数える。題は出さない）"),
    ("play", "手元の TS を録画の再生の系に流し、画面に出さずに数える（音は消す）"),
    ("view", "録画（nasne か手元の TS）を窓に描いて確かめる（デインターレース・A/V のずれ）"),
    ("scpd", "SOAP のサービスの説明（SCPD）を読み、アクションと引数の名前・型を出す（GET だけ）"),
    ("delete-title", "★書き込み：試しの録画を 1 件消し、応答と件数の変化を見る（--send が無ければ送らない。合意を取ってから）"),
    ("protect-title", "★書き込み：試しの録画の保護を 1 回切り替え、応答と一覧の変化を見る（--send が無ければ送らない。合意を取ってから）"),
    ("repeat-schedule", "★書き込み：試しの予約に繰り返しの値を入れる（変更か作り直し）。応答と一覧の変化を見る（--send が無ければ送らない。合意を取ってから）"),
    ("resume-position", "★書き込み：試しの録画の再開位置を 1 回書き、応答と一覧の変化を見る（--send が無ければ送らない。合意を取ってから）"),
    ("fake-nasne", "偽の nasne を待ち受け、単体試験の素材を返す（複数台の nasne の確かめ用。2 台目として登録する。nasne に何も送らない）"),
    ("p6", "1.1.0 の機能の下調べ：局のロゴ（地上・BS・CS）・Browse の順・BrowseMetadata・保存した res と今の res・チャプターを読み取りだけで測る"),
    ("extras", "pydtcpip が使う読み取りの口（\(ExtrasEndpoints.remoteAPIPort) の titleListGet・チャプター、"
        + "\(ExtrasEndpoints.webAPIPort) のサムネイル）が通るかを見る（GET だけ）"),
]

func printUsage() {
    var lines = ["使い方: mirne-mobile-probe <サブコマンド> [--host <nasne>]", ""]
    lines += subcommands.map { "  \($0.name)\t\($0.summary)" }
    FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))
}

func say(_ line: String) {
    print(line)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

/// 引数の値（`--name 値`）
func option(_ name: String) -> String? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func flag(_ name: String) -> Bool { CommandLine.arguments.contains(name) }

func requiredHost() -> String {
    guard let host = option("--host") ?? ProcessInfo.processInfo.environment["MIRNE_NASNE_HOST"], !host.isEmpty else {
        fail("--host か MIRNE_NASNE_HOST で nasne のアドレスを指定する")
    }
    return host
}

func elapsed(_ start: Date) -> String { String(format: "%.0f ms", Date().timeIntervalSince(start) * 1000) }

let client = URLSessionHTTPClient()

/// デバイス記述を取り（取れなければ既定の control URL）、登録して確かめる
func connect(_ host: String) async throws -> (NasneDevice, RegisteredNasne) {
    let device: NasneDevice
    do {
        device = try await DeviceDescriber(client: client).describe(host: host)
        say("デバイス記述: modelName=\(device.modelName)・サービス \(device.services.count) 件")
    } catch {
        say("デバイス記述は取れなかった（\(error)）。既定の control URL を使う")
        device = NasneDevice.direct(host: host)
    }
    let start = Date()
    let registration = try await WebAPIRegistrationService(client: client).register(device)
    say("PINVerify: 通った（\(elapsed(start))）")
    return (device, registration)
}

func runDiscover() async throws {
    if flag("--notify") { return try await runNotifyDiscover() }
    var start = Date()
    let found = try await SSDPDiscoveryService(client: client).discover()
    say("SSDP: nasne \(found.count) 台（\(elapsed(start))）")
    for device in found {
        say("  modelName=\(device.modelName)・friendlyName=\(device.friendlyName)・サービス \(device.services.count) 件・UDN \(device.udn.isEmpty ? "なし" : "あり")")
    }
    guard flag("--scan") else {
        say("（/24 の走査は --scan を付けたときだけ行う）")
        return
    }
    let bases = LocalNetwork.privateSubnetBases()
    say("走査: 私設の /24 が \(bases.count) 個")
    start = Date()
    let scanned = try await SubnetScanDiscoveryService(
        client: URLSessionHTTPClient(timeout: SubnetScanDiscoveryService.probeTimeout),
        describeClient: client).discover()
    say("走査: nasne \(scanned.count) 台（\(elapsed(start))）")
}

/// `discover --notify`：M-SEARCH を送らずに `NOTIFY ssdp:alive` だけを待ち（Buffalo 製が M-SEARCH に応えなくなったときの道）、
/// 届いたデバイス記述の URL で記述を取り、登録の確かめ（PINVerify）まで流す（手入力で記述の URL を入れたときと同じ道）。
/// URL・アドレス・UDN は出さない。登録は保存しない
func runNotifyDiscover() async throws {
    var start = Date()
    say("NOTIFY を待つ（最長 \(Int(SSDPTransport.announcementListenDuration)) 秒・M-SEARCH は送らない）")
    var known: Set<String> = []
    var device: NasneDevice?
    var location: String?
    while device == nil, Date().timeIntervalSince(start) < SSDPTransport.announcementListenDuration {
        let remaining = SSDPTransport.announcementListenDuration - Date().timeIntervalSince(start)
        let ignoring = known
        let heard = await Task.detached { @Sendable in
            SSDPTransport.listenForAnnouncements(duration: remaining, ignoring: ignoring)
        }.value
        guard let first = heard.first else { break }
        known.insert(first)
        // 手入力で記述の URL を入れたときと同じ関数で取る
        if let described = try? await DeviceDescriber(client: client).describe(host: first), described.isNasne {
            device = described
            location = first
        }
    }
    guard let device, let location else {
        say("NOTIFY: nasne の知らせは届かなかった（\(elapsed(start))・ほかの機器の知らせ \(known.count) 件）")
        return
    }
    say("NOTIFY: nasne の知らせが届いた（\(elapsed(start))・ほかの機器の知らせ \(known.count - 1) 件）")
    say("  記述の URL の形: http・パス \(URL(string: location)?.path.split(separator: "/").first.map { "/\($0)/…" } ?? "なし")（全体は出さない）")
    say("  記述: modelName=\(device.modelName)・サービス \(device.services.count) 件")
    start = Date()
    let registration = try await WebAPIRegistrationService(client: client).register(device)
    say("記述の URL からの登録の確かめ: PINVerify が通った（\(elapsed(start))・MAC アドレス \(registration.macAddress.isEmpty ? "なし" : "あり")・保存はしない）")
}

func runInfo() async throws {
    let (_, registration) = try await connect(requiredHost())
    let transport = WebAPITransport(host: registration.host, client: client)
    let service = WebAPIDeviceInfoService(transport: transport)
    let info = try await service.deviceInfo()
    say("本体: 版 \(info.displaySoftwareVersion)・時刻 \(info.currentDate == nil ? "なし" : "あり")・地域のコード \(info.pref == nil ? "なし" : "あり")・初期設定 \(info.finishedSetup ? "済み" : "未")・更新 \(info.updateExists ? "あり" : "なし")")
    for hdd in try await service.hddList() {
        if hdd.isConnected, let detail = try? await service.hddInfo(id: hdd.id) {
            let gigabyte = 1_000_000_000.0
            say(String(format: "HDD %d: %@・%@・全体 %.1f GB・空き %.1f GB", hdd.id, hdd.isInternal ? "内蔵" : "外付け",
                       detail.format, Double(detail.totalBytes) / gigabyte, Double(detail.freeBytes) / gigabyte))
        } else {
            say("HDD \(hdd.id): \(hdd.isInternal ? "内蔵" : "外付け")・マウント \(hdd.isMounted ? "済み" : "なし")・登録 \(hdd.isRegistered ? "済み" : "なし")")
        }
    }
    let channels = try await service.channels()
    let subchannels = Channel.subchannelServiceIDs(channels)
    let television = channels.filter { $0.serviceType == Channel.televisionServiceType }
    say("チャンネル（地上）: \(channels.count) 件・TV \(television.count) 件・本 \(television.count - subchannels.count) 件・サブ \(subchannels.count) 件")
    let live = try await service.liveStatus()
    say("集約ステータス: \(live.sections.count) 項目・選局 \(live.tuningStatus.map(String.init) ?? "不明")・EIT_PF の中身 \(live.sections["EIT_PF"].map { $0.raw.values.count > 1 ? "あり" : "なし（generation だけ）" } ?? "項目なし")")
    // 一覧ごとの世代（変わったことを見分ける数。値は機器の固有の値ではないので出す）
    say("世代: " + ["tvTimerList", "recContentsList", "recNgList"]
        .map { "\($0) \(live.sections[$0]?.generation.map(String.init) ?? "無い")" }.joined(separator: "・"))
    say("録画の失敗: \(try await service.recNgList().count) 件")
    let counts = try await service.titleCounts()
    say("録画の件数: \(counts.count) 件（上限 \(counts.max) 件）")
}

func runTitles() async throws {
    let (device, registration) = try await connect(requiredHost())
    let catalog = RecordingCatalogService(soap: SOAPTransport(client: client), device: device)
    let start = Date()
    let titles = try await catalog.titles()
    let counts = try await WebAPIDeviceInfoService(transport: WebAPITransport(host: registration.host, client: client)).titleCounts()
    say("録画: xsrs \(titles.count) 件（件数 API は \(counts.count) 件・\(titles.count == counts.count ? "一致" : "不一致")）（\(elapsed(start))）")
    let joined = titles.filter { !$0.resources.isEmpty }
    say("DIDL と結合できた: \(joined.count) 件・残りコピー回数あり \(titles.filter { $0.copyCountRemaining != nil }.count) 件")
    // 録画の容器の Browse の件数（xsrs に載らない録画が DLNA には出るかを見る。共有フォルダーの動画も入る。2026-11-24）
    let browsed = try await catalog.browseEntries(catalog.profile.dlna.allRecordingsContainer)
    say("Browse（録画の容器）: \(browsed.count) 件・xsrs の録画より \(browsed.count - titles.count) 件多い")
    var qualities: [String: Int] = [:]
    for title in titles {
        for resource in title.resources { qualities[resource.quality ?? "なし", default: 0] += 1 }
    }
    say("res の quality: \(qualities.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: "・"))")
    say("DTCP1HOST・DTCP1PORT のある res: \(titles.flatMap(\.resources).filter { $0.dtcpHost != nil && $0.dtcpPort != nil }.count) 件")
    say("ムーブ専用（URL に cp）の res: \(titles.flatMap(\.resources).filter(\.isMoveOnly).count) 件")
    // 録画ごとの res の組み合わせ（画質の選択に出すものと、ムーブ専用の混ざり方）
    var combinations: [String: Int] = [:]
    for title in titles where !title.resources.isEmpty {
        let key = title.resources.map { ($0.quality ?? "なし") + ($0.isMoveOnly ? "(cp)" : "") }.joined(separator: "+")
        combinations[key, default: 0] += 1
    }
    say("録画ごとの res の組み合わせ: \(combinations.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: "・"))")
    // 録り始めから番組の開始までの秒（DIDL の scheduledStartTime − xsrs の scheduledStartDateTime）の分布
    var offsets: [Int: Int] = [:]
    var noProgramStart = 0
    var programBeforeStart = 0
    for title in titles {
        guard let start = title.start, let program = title.programStart else { noProgramStart += 1; continue }
        let seconds = Int(program.timeIntervalSince(start).rounded())
        if seconds < 0 { programBeforeStart += 1 }
        offsets[seconds, default: 0] += 1
    }
    say("録り始めから番組の開始まで（秒）: \(offsets.sorted { $0.key < $1.key }.map { "\($0.key) 秒 \($0.value)" }.joined(separator: "・"))・番組の開始なし \(noProgramStart)・番組の開始が録り始めより前 \(programBeforeStart)")
    let mobileOnly = titles.filter { $0.mobileResource != nil && $0.originalResource == $0.mobileResource }.count
    say("再生できる res がモバイルだけの録画: \(mobileOnly) 件・再生できる res が無い録画: \(titles.filter { !$0.resources.isEmpty && $0.playableResources.isEmpty }.count) 件")
    var modes: [String: Int] = [:]
    for title in titles { modes[title.desiredQualityMode.map(QualityMode.label) ?? "なし", default: 0] += 1 }
    say("画質: \(modes.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: "・"))")
    say("再開位置あり: \(titles.filter { ($0.resumePointSeconds ?? 0) > 0 }.count) 件")
    // 視聴の状態の材料：新着の印・前回の再生の時刻・再開位置の組み合わせと、再開位置の残り（番組名は出さない）
    var playbackShapes: [String: Int] = [:]
    var remaining: [String: Int] = [:]
    for title in titles {
        let resume = title.resumePointSeconds ?? -1
        let shape = "新着\(title.isNew ? "あり" : "なし")・前回の再生\(title.lastPlaybackTime == nil ? "なし" : "あり")・再開位置\(resume < 0 ? "属性なし" : resume == 0 ? "0" : "あり")"
        playbackShapes[shape, default: 0] += 1
        if resume > 0, let duration = title.durationSeconds {
            let left = duration - resume
            let bucket = left < 0 ? "長さを超える" : left < 60 ? "60 秒未満" : left < 300 ? "5 分未満" : "5 分以上"
            remaining[bucket, default: 0] += 1
        }
    }
    say("新着・前回の再生・再開位置: \(playbackShapes.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: "・"))")
    say("再開位置の残り: \(remaining.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: "・"))")
    let newWithPlayback = titles.filter { $0.isNew && $0.lastPlaybackTime != nil }.count
    say("新着なのに前回の再生がある: \(newWithPlayback) 件")
    if flag("--playback") {
        // 前回の再生のある録画（日時・長さ・前回の再生の時刻・再開位置・新着だけ。番組名は出さない）
        for title in titles.filter({ $0.lastPlaybackTime != nil }).sorted(by: { $0.lastPlaybackTime! > $1.lastPlaybackTime! }) {
            say("  録画 \(title.start.map { NasneDateTime.format($0) } ?? "?")・長さ \(title.durationSeconds ?? -1) 秒・前回の再生 \(NasneDateTime.format(title.lastPlaybackTime!))・再開位置 \(title.resumePointSeconds ?? -1) 秒・新着 \(title.isNew ? "あり" : "なし")")
        }
    }
    if flag("--groups") { reportTitleGroups(titles) }
    // --audio：音声が複数ありそうな録画（DIDL の申告）。番組名・局名は出さず、日時・長さ・stream の --pick の番号を出す
    if flag("--audio") {
        let candidates = titles.filter { !$0.isRecording && !$0.resources.isEmpty && ($0.durationSeconds ?? 0) > 0 }
            .sorted { ($0.durationSeconds ?? 0) < ($1.durationSeconds ?? 0) }
        var kinds: [String: Int] = [:]
        for title in titles {
            kinds["audioComponentType \(title.audioComponentType.map(String.init) ?? "なし")・multiESInfo \(title.multiESInfo.map(String.init) ?? "なし")", default: 0] += 1
        }
        say("音声の申告の内訳: \(kinds.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: " / "))")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.timeZone = NasneDateTime.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        for (index, title) in candidates.enumerated() where title.multiESInfo == 1 || title.audioComponentType == 2 {
            say("  --pick \(index): \(title.start.map(formatter.string) ?? "日時なし")・\(title.durationSeconds ?? 0) 秒・audioComponentType \(title.audioComponentType.map(String.init) ?? "なし")・multiESInfo \(title.multiESInfo.map(String.init) ?? "なし")")
        }
    }
}

/// `titles --groups`：DIDL のジャンルの文字の内訳と、同じ番組名でまとめたときの数。番組名は出さない
func reportTitleGroups(_ titles: [RecordedTitle]) {
    var genres: [String: Int] = [:]
    for title in titles { for genre in title.genres { genres[genre, default: 0] += 1 } }
    say("ジャンルの文字（DIDL）: \(genres.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: "・"))")
    say("ジャンルの数（録画ごと）: \(Dictionary(grouping: titles, by: { $0.genres.count }).sorted { $0.key < $1.key }.map { "\($0.key) 個 \($0.value.count) 件" }.joined(separator: "・"))")
    // まとめ方はアプリと同じ（1 段目の名前と、1 件だけのものどうしを頭でまとめる 2 段目）
    let names = RecordingNameGrouping.groupNames(titles)
    let groups = Dictionary(grouping: titles, by: { names[$0.id] ?? $0.title })
    let sizes = groups.values.map(\.count).sorted(by: >)
    let changed = titles.filter { (names[$0.id] ?? $0.title) != $0.title }.count
    say("まとめ: 録画 \(titles.count) 件 → \(groups.count) まとめ・2 件以上のまとめ \(sizes.filter { $0 >= 2 }.count)（その中の録画 \(sizes.filter { $0 >= 2 }.reduce(0, +)) 件）・名前を削った録画 \(changed) 件")
    say("  大きいまとめの件数（上位 15）: \(sizes.prefix(15).map(String.init).joined(separator: " "))")
    // 削った名前のうち、同じまとめに入らなかった（1 件だけの）もの：除き方が足りない見込みの数
    let alone = groups.values.filter { $0.count == 1 && (names[$0[0].id] ?? $0[0].title) != $0[0].title }.count
    say("  名前を削ったのに 1 件だけのまとめ: \(alone)")
    // 形だけを出す（漢字・かな・英字・数字を種類の字に置き換え、続きは 1 つにまとめる。番組名は出さない）
    if flag("--shapes") {
        func shape(_ text: String) -> String {
            var out = ""
            for scalar in text.unicodeScalars {
                let kind: String
                switch scalar.value {
                case 0x3040...0x309F: kind = "あ"
                case 0x30A0...0x30FF, 0xFF66...0xFF9F: kind = "ア"
                case 0x4E00...0x9FFF, 0x3400...0x4DBF: kind = "漢"
                case 0x30...0x39, 0xFF10...0xFF19: kind = "9"
                case 0x41...0x5A, 0x61...0x7A, 0xFF21...0xFF3A, 0xFF41...0xFF5A: kind = "a"
                default: kind = String(scalar)
                }
                if !out.hasSuffix(kind) || !"あア漢9a".contains(kind) { out += kind }
            }
            return out
        }
        for group in groups.values where group.count == 1 && (names[group[0].id] ?? group[0].title) != group[0].title {
            say("  形: \(shape(group[0].title))  →  \(shape(names[group[0].id] ?? group[0].title))")
        }
    }
}

func runSchedules() async throws {
    let (device, _) = try await connect(requiredHost())
    let start = Date()
    let schedules = try await RecordingCatalogService(soap: SOAPTransport(client: client), device: device).schedules()
    say("予約: \(schedules.count) 件（\(elapsed(start))）")
    var modes: [String: Int] = [:]
    for schedule in schedules { modes[QualityMode.label(schedule.desiredQualityMode), default: 0] += 1 }
    if !modes.isEmpty {
        say("画質: \(modes.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: "・"))")
    }
    // 項目の形の数（番組名・局は出さない）
    func tally(_ name: String, _ value: (RecordSchedule) -> String) {
        var counts: [String: Int] = [:]
        for schedule in schedules { counts[value(schedule), default: 0] += 1 }
        say("\(name): \(counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: "・"))")
    }
    let now = Date()
    tally("番組名", { $0.title == nil ? "なし" : "あり" })
    tally("時期", { $0.end < now ? "終わった" : ($0.start <= now ? "録画中" : "これから") })
    tally("conditionID", { $0.conditionID.isEmpty ? "空" : $0.conditionID })
    tally("matchingID の形", { $0.desiredMatchingID.split(separator: ",").count == 0 ? "空" : "\($0.desiredMatchingID.split(separator: ",").count) つの値" })
    // 手動の予約（終わった後も残る。録画が始まる前に消す）の開始まで（番組名・局は出さない）
    let clock = DateFormatter()
    clock.timeZone = NasneDateTime.timeZone
    clock.dateFormat = "MM-dd HH:mm:ss"
    for schedule in schedules where schedule.isLinkedToProgram {
        say("番組の予約: 開始 \(clock.string(from: schedule.start))・長さ \(schedule.durationSeconds) 秒・画質 \(QualityMode.label(schedule.desiredQualityMode))・録画先 \(schedule.recordDestinationID)・matchingID の形 \(schedule.desiredMatchingID.replacingOccurrences(of: "[0-9a-fA-F]", with: "9", options: .regularExpression))")
    }
    for schedule in schedules where !schedule.isLinkedToProgram {
        say("手動の予約: 開始まで \(Int(schedule.start.timeIntervalSince(now) / 60)) 分・長さ \(schedule.durationSeconds / 60) 分")
    }
    // テレビの局のネットワーク ID の数（手動の予約の matchingID は ,,nid,0 なので、同じ nid の局どうしは同じ値になる）
    if let channels = try? await WebAPIDeviceInfoService(transport: WebAPITransport(host: device.host, client: client)).channels(broadcastingType: BroadcastingType.terrestrial) {
        let tv = channels.filter { $0.serviceType == Channel.televisionServiceType }
        say("テレビの局: \(tv.count) 件・ネットワーク ID \(Set(tv.map(\.networkID)).count) 種類・TS \(Set(tv.map(\.transportStreamID)).count) 種類")
    }
    tally("eventId（matchingID の最後）", { $0.desiredMatchingID.split(separator: ",").last.map { $0 == "0" || $0 == "0x0000" ? "0" : "0 でない" } ?? "空" })
    tally("作り手", { $0.reservationCreatorID.isEmpty ? "空" : $0.reservationCreatorID })
    tally("priorityFlag", { String($0.priorityFlag) })
    tally("録画先", { $0.recordDestinationID.isEmpty ? "空" : $0.recordDestinationID })
    tally("ID の形", { $0.id.allSatisfy(\.isNumber) ? "10 進" : "そのほか" })
    if let sample = schedules.first { say("matchingID の例の形: \(sample.desiredMatchingID.replacingOccurrences(of: "[0-9a-fA-F]", with: "9", options: .regularExpression))") }
    let raw = try await RecordingCatalogService(soap: SOAPTransport(client: client), device: device).scheduleItems()
    var names: [String: Int] = [:]
    for item in raw { for key in item.fields.keys { names[key, default: 0] += 1 } }
    say("項目名: \(names.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: "・"))")
}

func runEPG() async throws {
    let (_, registration) = try await connect(requiredHost())
    let transport = WebAPITransport(host: registration.host, client: client)
    let guide = WebAPIProgramGuideService(transport: transport, tokens: try registration.tokenProvider())
    var start = Date()
    let result = try await guide.fetch()
    say("EPGGet: 版数表のサービス \(result.serviceCount) 件・応答 \(result.responseBytes) バイト・平文 \(result.plaintextBytes) バイト（\(elapsed(start))）")
    let events = result.sections.flatMap(\.events)
    var unique = Set<[Int]>()
    for event in events { unique.insert([Int(event.originalNetworkID), Int(event.transportStreamID), Int(event.serviceID), Int(event.eventID)]) }
    say("セクション \(result.sections.count) 件（読めなかったバイト \(result.skippedBytes)）・番組名のある番組 \(unique.count) 件・欠けなく復号できなかった番組名・概要 \(events.filter { !$0.lossless }.count) 件")
    let services = Set(result.sections.map { [Int($0.originalNetworkID), Int($0.transportStreamID), Int($0.serviceID)] })
    say("番組のあるサービス \(services.count) 件")

    let storeURL = option("--store").map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.temporaryDirectory.appendingPathComponent("mirne-mobile-probe-\(UUID().uuidString).sqlite")
    start = Date()
    let store = try EPGStore(fileURL: storeURL)
    store.save(result.sections, receivedAt: Date())
    await store.flushed()
    let stored = store.storedServices()
    var total = 0
    var perDay: [String: Int] = [:]
    let day = DateFormatter()
    day.locale = Locale(identifier: "en_US_POSIX")
    day.timeZone = NasneDateTime.timeZone
    day.dateFormat = "MM-dd"
    let window = Date().addingTimeInterval(-86_400)..<Date().addingTimeInterval(10 * 86_400)
    for service in stored {
        let list = store.events(networkID: service.networkID, transportStreamID: service.transportStreamID,
                                serviceID: service.serviceID, overlapping: window)
        total += list.count
        for event in list { if let start = event.start { perDay[day.string(from: start), default: 0] += 1 } }
    }
    say("EPGStore: サービス \(stored.count) 件・番組 \(total) 件（\(elapsed(start))）")
    say("日別（日本時間）: \(perDay.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: "・"))")
    // 局ごとの番組の有無（番組表に並ぶ本チャンネル・サブチャンネル。局名は出さない）
    let all = try await WebAPIDeviceInfoService(transport: transport).channels(broadcastingType: BroadcastingType.terrestrial)
    let subchannels = Channel.subchannelServiceIDs(all)
    let television = all.filter { $0.serviceType == Channel.televisionServiceType }
    func covered(_ channel: Channel) -> Bool {
        !store.events(networkID: channel.networkID, transportStreamID: channel.transportStreamID, serviceID: channel.serviceID,
                      overlapping: window).isEmpty
    }
    let mains = television.filter { !subchannels.contains($0.serviceID) }
    let subs = television.filter { subchannels.contains($0.serviceID) }
    say("番組のある局: 本チャンネル \(mains.filter(covered).count) / \(mains.count)・サブチャンネル \(subs.filter(covered).count) / \(subs.count)")
    let missing = mains.filter { !covered($0) }
    say("番組の無い本チャンネル: \(missing.count) 件（リモコンキー \(missing.map { $0.remoteControlKey.map(String.init) ?? "なし" }.joined(separator: "・"))）")
    // 一時のデータベースは消す（番組名が入っているので残さない）
    if option("--store") == nil {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + suffix))
        }
    }

    start = Date()
    let logos = try await guide.logos()
    say("ロゴ: \(logos.count) 件（\(elapsed(start))）")
    // 大きさ（PNG の IHDR の幅と高さ）ごとの件数。局を特定しないよう serviceID は出さない
    var sizes: [String: Int] = [:]
    for png in logos.values where png.count >= 24 {
        let bytes = [UInt8](png)
        let width = bytes[16..<20].reduce(0) { $0 << 8 | Int($1) }
        let height = bytes[20..<24].reduce(0) { $0 << 8 | Int($1) }
        sizes["\(width)×\(height)", default: 0] += 1
    }
    say("ロゴの大きさ: \(sizes.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value) 件" }.joined(separator: "・"))")
    // 局と突き合わせる（テレビのサービスのうちロゴのある数・絵として読めるロゴの数）
    let tv = try await WebAPIDeviceInfoService(transport: transport).channels(broadcastingType: BroadcastingType.terrestrial)
        .filter { $0.serviceType == Channel.televisionServiceType }
    let matched = tv.filter { logos[$0.serviceID] != nil }.count
    let decodable = logos.values.filter { png in
        guard let source = CGImageSourceCreateWithData(png as CFData, nil) else { return false }
        return CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
    }.count
    say("ロゴと局: テレビのサービス \(tv.count) 件のうちロゴあり \(matched) 件・絵として読めるロゴ \(decodable) 件")
    // PNG のチャンクの並び（種類と長さだけ。絵の中身は出さない）
    var layouts: [String: Int] = [:]
    for png in logos.values {
        let bytes = [UInt8](png)
        var offset = 8
        var chunks: [String] = []
        while offset + 8 <= bytes.count {
            let length = bytes[offset..<(offset + 4)].reduce(0) { $0 << 8 | Int($1) }
            let type = String(decoding: bytes[(offset + 4)..<(offset + 8)], as: UTF8.self)
            chunks.append(type == "IDAT" ? type : "\(type)(\(length))")
            offset += 12 + length
        }
        if offset != bytes.count { chunks.append("残り \(bytes.count - offset)") }
        layouts[chunks.joined(separator: " ").replacingOccurrences(of: "IDAT IDAT", with: "IDAT…"), default: 0] += 1
    }
    for (layout, count) in layouts.sorted(by: { $0.value > $1.value }).prefix(5) { say("PNG のチャンク（\(count) 件）: \(layout)") }
    if let ihdr = logos.values.first.map({ [UInt8]($0) }), ihdr.count >= 29 {
        say("IHDR: ビット深度 \(ihdr[24])・色の型 \(ihdr[25])・圧縮 \(ihdr[26])・フィルタ \(ihdr[27])・インターレース \(ihdr[28])")
    }
    if matched == 0, let sample = logos.keys.min(), let tvMin = tv.map(\.serviceID).min() {
        say("ロゴの鍵の範囲 \(logos.keys.min()!)〜\(logos.keys.max()!)・局の serviceID の範囲 \(tvMin)〜\(tv.map(\.serviceID).max()!)（\(sample)）")
    }
}

let arguments = CommandLine.arguments.dropFirst()
guard let command = arguments.first, subcommands.contains(where: { $0.name == command }) else {
    printUsage()
    exit(64)
}

do {
    switch command {
    case "discover": try await runDiscover()
    case "info": try await runInfo()
    case "titles": try await runTitles()
    case "schedules": try await runSchedules()
    case "epg": try await runEPG()
    case "credentials": try CredentialsCommand.run(CommandLine.arguments.dropFirst(2).first)
    case "stream": try await StreamCommand.run()
    case "head": try await HeadCommand.run()
    case "live": try await LiveCommand.run()
    case "media": try await MediaCommand.run()
    case "play": try await PlayCommand.run()
    case "view": ViewCommand.run()
    case "extras": try await ExtrasCommand.run()
    case "scpd": try await ScpdCommand.run()
    case "delete-title": try await DeleteTitleCommand.run()
    case "protect-title": try await ProtectTitleCommand.run()
    case "resume-position": try await ResumePositionCommand.run()
    case "repeat-schedule": try await RepeatScheduleCommand.run()
    case "p6": try await Phase6Command.run()
    case "fake-nasne": try await FakeNasneCommand.run()
    default: printUsage(); exit(64)
    }
} catch {
    fail(String(describing: error))
}
