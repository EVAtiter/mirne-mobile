// torne mobile HB（MIT、© mar1mo-41414）の lib/core/transport/ssdp_transport.dart・services/discovery.dart・
// services/discovery_scan.dart を Swift へ移植したもの。

import Darwin
import Foundation

/// nasne を探す
public protocol DiscoveryService: Sendable {
    /// LAN の nasne を探す
    func discover() async throws -> [NasneDevice]
}

/// SSDP の 1 応答
struct SSDPResponse: Sendable {
    /// 見出しの名前は大文字にしてある
    let headers: [String: String]
    var location: String? { headers["LOCATION"] }
}

/// SSDP の M-SEARCH を送り、応答を集める（BSD の UDP ソケット）
enum SSDPTransport {
    static let multicastAddress = "239.255.255.250"
    static let port: UInt16 = 1900
    /// MediaServer を探す ST
    static let mediaServerSearchTarget = "urn:schemas-upnp-org:device:MediaServer:1"
    /// マルチキャストで探すときの MX（応答を散らす秒数の上限）
    static let multicastMX = 3
    /// 1 台へユニキャストで問い合わせるときの MX（実測：Buffalo 製の個体は MX が無いと応えず、1 で応えた）
    static let unicastMX = 1
    /// 応答を待つ時間
    static let listenDuration: TimeInterval = 3
    /// 取りこぼしに備えて、もう 1 回送るまでの間
    static let resendDelay: TimeInterval = 0.4
    /// 受信を待つ 1 回の長さ（poll の時間切れ）
    static let pollIntervalMilliseconds: Int32 = 100
    /// 受け取る 1 応答の上限
    static let receiveBufferSize = 4096
    /// M-SEARCH で見つからなかったときに、`NOTIFY ssdp:alive` を待つ長さの上限。
    /// Buffalo 製の個体は長く動いていると M-SEARCH に応えなくなるが、知らせは約 30 秒ごとに出し続ける
    /// （pydtcpip の Issue #4・#17。pydtcpip も 35 秒待って拾う）。1 回の間隔より少し長くする
    static let announcementListenDuration: TimeInterval = 35
    /// 生存の知らせの NTS
    static let aliveNotificationSubtype = "ssdp:alive"

    /// 送って集める。ブロックするので呼び出し側が別のスレッドで呼ぶ。
    ///
    /// `unicastHost` を渡すと、マルチキャストではなくそのホストの 1900 番へ送り、最初の応答で返す
    /// （手で入れたアドレスの記述の在りかを知るため）。HOST の見出しはどちらもマルチキャストの表記（実測した形）
    static func search(target: String = mediaServerSearchTarget, unicastHost: String? = nil) throws -> [SSDPResponse] {
        let source = unicastHost == nil ? "ssdp:search" : "ssdp:locate"
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw NasneError.unreachable(source, cause: POSIXError(.init(rawValue: errno) ?? .EIO)) }
        defer { close(fd) }

        var destination = sockaddr_in()
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = port.bigEndian
        if let unicastHost {
            guard let address = ipv4Address(unicastHost) else {
                throw NasneError.unreachable(source, cause: POSIXError(.EADDRNOTAVAIL))
            }
            destination.sin_addr = address
        } else {
            inet_pton(AF_INET, multicastAddress, &destination.sin_addr)
        }
        let mx = unicastHost == nil ? multicastMX : unicastMX
        let request = """
            M-SEARCH * HTTP/1.1\r\nHOST: \(multicastAddress):\(port)\r\nMAN: "ssdp:discover"\r\nMX: \(mx)\r\nST: \(target)\r\n\r\n
            """
        func send() throws {
            let bytes = Array(request.utf8)
            let sent = withUnsafePointer(to: &destination) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if sent < 0 { throw NasneError.unreachable(source, cause: POSIXError(.init(rawValue: errno) ?? .EIO)) }
        }

        try send()
        let start = Date()
        var resent = false
        var responses: [SSDPResponse] = []
        var buffer = [UInt8](repeating: 0, count: receiveBufferSize)
        while Date().timeIntervalSince(start) < listenDuration {
            if !resent, Date().timeIntervalSince(start) >= resendDelay {
                try send()
                resent = true
            }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, pollIntervalMilliseconds) > 0 else { continue }
            let count = recv(fd, &buffer, buffer.count, 0)
            guard count > 0 else { continue }
            if let response = parse(Data(buffer[0..<count])) {
                responses.append(response)
                if unicastHost != nil, response.location != nil { break }
            }
        }
        return responses
    }

    /// マルチキャストの 1900 番で `NOTIFY ssdp:alive` を聞き、MediaServer の LOCATION を集める。
    /// ブロックするので呼び出し側が別のスレッドで呼ぶ。
    ///
    /// `ignoring` に無い LOCATION が 1 つ届いたところで返す（呼び出し側が記述を見て、nasne でなければ残りの時間でまた聞く）。
    /// ポートを取れない・グループに入れないときは空を返す（M-SEARCH の結果だけで続けられるように、誤りにしない）
    static func listenForAnnouncements(duration: TimeInterval, target: String = mediaServerSearchTarget,
                                       ignoring known: Set<String> = []) -> [String] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        // ほかの UPnP の利用者と 1900 番を分け合う
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &on, socklen_t(MemoryLayout<Int32>.size))
        var local = sockaddr_in()
        local.sin_family = sa_family_t(AF_INET)
        local.sin_port = port.bigEndian
        local.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &local) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return [] }
        var membership = ip_mreq()
        inet_pton(AF_INET, multicastAddress, &membership.imr_multiaddr)
        membership.imr_interface.s_addr = INADDR_ANY
        guard setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &membership, socklen_t(MemoryLayout<ip_mreq>.size)) == 0
        else { return [] }

        let start = Date()
        var buffer = [UInt8](repeating: 0, count: receiveBufferSize)
        while Date().timeIntervalSince(start) < duration {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, pollIntervalMilliseconds) > 0 else { continue }
            let count = recv(fd, &buffer, buffer.count, 0)
            guard count > 0, let location = parseAnnouncement(Data(buffer[0..<count]), target: target),
                  !known.contains(location) else { continue }
            return [location]
        }
        return []
    }

    /// `NOTIFY` の生存の知らせで、NT が `target` のものの LOCATION。ほかの形は nil
    static func parseAnnouncement(_ data: Data, target: String = mediaServerSearchTarget) -> String? {
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.components(separatedBy: "\r\n")
        guard let first = lines.first, first.hasPrefix("NOTIFY ") else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).uppercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["NTS"] == aliveNotificationSubtype, headers["NT"] == target,
              let location = headers["LOCATION"], !location.isEmpty else { return nil }
        return location
    }

    /// 1 台へユニキャストで問い合わせ、デバイス記述の在りか（LOCATION）を返す。応えなければ nil
    static func locate(host: String) async throws -> URL? {
        let responses = try await Task.detached { try search(unicastHost: host) }.value
        return responses.lazy.compactMap { $0.location.flatMap(URL.init(string:)) }.first
    }

    /// IPv4 のアドレス（数字の表記か、ホスト名を引いたもの）
    static func ipv4Address(_ host: String) -> in_addr? {
        var address = in_addr()
        if inet_pton(AF_INET, host, &address) == 1 { return address }
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_DGRAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else { return nil }
        defer { freeaddrinfo(list) }
        guard let socketAddress = first.pointee.ai_addr else { return nil }
        return socketAddress.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
    }

    static func parse(_ data: Data) -> SSDPResponse? {
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.components(separatedBy: "\r\n")
        guard let first = lines.first, first.contains("200") else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).uppercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return SSDPResponse(headers: headers)
    }
}

/// デバイス記述を取って nasne か確かめる
public struct DeviceDescriber: Sendable {
    private let client: any HTTPExchanging
    private let locate: @Sendable (String) async throws -> URL?
    /// 記述を取る前（機種が分からない）に使う表
    private let profile: NasneProfile

    public init(client: any HTTPExchanging, profile: NasneProfile = NasneProfiles.standard) {
        self.init(client: client, profile: profile, locate: { try await SSDPTransport.locate(host: $0) })
    }

    /// `locate` は、手で入れたアドレスの記述の在りかを SSDP で問い合わせるもの（試験で差し替える）
    init(client: any HTTPExchanging, profile: NasneProfile = NasneProfiles.standard,
         locate: @escaping @Sendable (String) async throws -> URL?) {
        self.client = client
        self.profile = profile
        self.locate = locate
    }

    public func describe(_ location: URL) async throws -> NasneDevice {
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await client.send(URLRequest(url: location))
        } catch {
            throw NasneError.unreachable("ssdp:describe", cause: error)
        }
        guard response.statusCode == 200 else { throw NasneError.http(response.statusCode, "ssdp:describe") }
        return try NasneDevice.parseDescription(data, location: location)
    }

    /// 手で入れたアドレス（またはデバイス記述の URL）のデバイス記述。
    ///
    /// `http://` で始まる URL なら、その記述をそのまま取る（Buffalo 製の個体が SSDP に応えなくなったとき、
    /// 記述の URL を知っていれば登録できる。pydtcpip の Issue #4）。
    /// アドレスなら、まずポート 58888 の `/` を取る（SIE 製の個体の在りか）。取れなければ、そのアドレスへ SSDP で
    /// 問い合わせて LOCATION を取る（Buffalo 製の個体は `/` が 404 で、記述は `/XD/<uuid>` にだけある。実測）
    public func describe(host: String) async throws -> NasneDevice {
        if let url = Self.descriptionURL(host) { return try await describe(url) }
        let firstError: any Error
        do {
            return try await describe(NasneDevice.url(host: host, port: profile.ports.dms, path: NasneDevice.descriptionRootPath))
        } catch {
            firstError = error
        }
        guard let location = try? await locate(host) else { throw firstError }
        return try await describe(location)
    }

    /// 入力がデバイス記述の URL（http・ホストあり）なら、その URL。アドレスなら nil
    static func descriptionURL(_ input: String) -> URL? {
        guard input.lowercased().hasPrefix("http://"), let url = URL(string: input), url.host?.isEmpty == false else {
            return nil
        }
        return url
    }
}

/// SSDP で探す
public struct SSDPDiscoveryService: DiscoveryService {
    private let describer: DeviceDescriber
    /// 診断ログ（件数と所要時間だけ。アドレスは出さない）
    private let diagnostics: NasneDiagnostics
    /// M-SEARCH を送って応答を集める（試験で差し替える）
    private let search: @Sendable () throws -> [SSDPResponse]
    /// 知らせを聞く（残りの時間・もう見た LOCATION → 新しい LOCATION。試験で差し替える）
    private let listen: @Sendable (TimeInterval, Set<String>) -> [String]
    /// 知らせを待つ長さの上限
    private let announcementDuration: TimeInterval

    public init(client: any HTTPExchanging, diagnostics: NasneDiagnostics = .osLog) {
        self.init(client: client, diagnostics: diagnostics,
                  search: { try SSDPTransport.search() },
                  listen: { SSDPTransport.listenForAnnouncements(duration: $0, ignoring: $1) },
                  announcementDuration: SSDPTransport.announcementListenDuration)
    }

    init(client: any HTTPExchanging, diagnostics: NasneDiagnostics = .osLog,
         search: @escaping @Sendable () throws -> [SSDPResponse],
         listen: @escaping @Sendable (TimeInterval, Set<String>) -> [String],
         announcementDuration: TimeInterval) {
        describer = DeviceDescriber(client: client, locate: { _ in nil })
        self.diagnostics = diagnostics
        self.search = search
        self.listen = listen
        self.announcementDuration = announcementDuration
    }

    public func discover() async throws -> [NasneDevice] {
        try await discover(udn: nil)
    }

    /// 記述の UDN が `udn` の nasne だけを探す（アドレスが変わった登録済みの nasne を探し直す）。
    /// M-SEARCH で見つからなければ、知らせ（NOTIFY）を待つ間もほかの nasne は読み飛ばす。`udn` が nil ならどの nasne でもよい
    public func discover(udn: String?) async throws -> [NasneDevice] {
        let started = ContinuousClock.now
        let responses: [SSDPResponse]
        do {
            let search = self.search
            responses = try await Task.detached { try search() }.value
        } catch {
            diagnostics(.discovery, "SSDP: 探せない（\(NasneDiagnostics.summary(error))）")
            throw error
        }
        var locations: [String] = []
        for response in responses {
            if let location = response.location, !location.isEmpty, !locations.contains(location) {
                locations.append(location)
            }
        }
        var devices: [NasneDevice] = []
        for location in locations {
            guard let url = URL(string: location),
                  let device = try? await describer.describe(url), device.isNasne,
                  udn == nil || device.udn == udn else { continue }
            if !devices.contains(where: { $0.udn == device.udn && $0.host == device.host }) {
                devices.append(device)
            }
        }
        diagnostics(.discovery, "SSDP: 応答 \(responses.count) 件・機器の記述 \(locations.count) か所・nasne \(devices.count) 台・"
                    + "\(started.elapsedMilliseconds) ms")
        if devices.isEmpty {
            devices = await listenForAnnouncements(known: Set(locations), udn: udn)
        }
        return devices
    }

    /// M-SEARCH で見つからなかったとき、生存の知らせ（NOTIFY）を待つ。nasne（`udn` があればその nasne）が 1 台見つかったところで返す
    private func listenForAnnouncements(known initial: Set<String>, udn: String?) async -> [NasneDevice] {
        let started = ContinuousClock.now
        let deadline = Date().addingTimeInterval(announcementDuration)
        var known = initial
        var heard = 0
        let listen = self.listen
        while case let remaining = deadline.timeIntervalSinceNow, remaining > 0 {
            let snapshot = known
            let locations = await Task.detached { listen(remaining, snapshot) }.value
            guard !locations.isEmpty else { break }
            for location in locations {
                known.insert(location)
                heard += 1
                guard let url = URL(string: location),
                      let device = try? await describer.describe(url), device.isNasne,
                      udn == nil || device.udn == udn else { continue }
                diagnostics(.discovery, "SSDP の知らせ: \(heard) か所目で nasne・\(started.elapsedMilliseconds) ms")
                return [device]
            }
        }
        diagnostics(.discovery, "SSDP の知らせ: \(heard) か所・nasne 0 台・\(started.elapsedMilliseconds) ms")
        return []
    }
}

/// 自分の /24 を走査して探す（SSDP が使えない環境向け。plan.md §16.3）。
///
/// ⚠️ 254 台へ HTTP を送るので、**利用者がはっきり選んだときだけ使う**（会社などのネットワークでは
/// 侵入検知に触れうる）。自動では走らせない。
public struct SubnetScanDiscoveryService: DiscoveryService {
    /// 1 台への問い合わせの時間切れ（torne mobile HB と同じ。1 つの /24 は最悪 ceil(254/64)×0.8 ≈ 3.2 秒）
    public static let probeTimeout: TimeInterval = 0.8
    /// 同時に問い合わせる台数
    public static let concurrency = 64
    /// /24 のホスト番号の範囲
    static let hostNumbers = 1...254

    private let client: any HTTPExchanging
    private let describer: DeviceDescriber
    private let subnetBases: @Sendable () -> [String]
    /// 走査に使う表（機種が分からないうちに使う）
    private let profile: NasneProfile
    /// 診断ログ（何番目の /24 か・件数・所要時間だけ。アドレスは出さない）
    private let diagnostics: NasneDiagnostics

    /// `client` は短い時間切れ（`probeTimeout`）のものを渡す。`subnetBases` は「192.168.0」の形の一覧
    public init(client: any HTTPExchanging, describeClient: any HTTPExchanging,
                subnetBases: @escaping @Sendable () -> [String] = LocalNetwork.privateSubnetBases,
                profile: NasneProfile = NasneProfiles.standard,
                diagnostics: NasneDiagnostics = .osLog) {
        self.client = client
        self.profile = profile
        describer = DeviceDescriber(client: describeClient, profile: profile)
        self.subnetBases = subnetBases
        self.diagnostics = diagnostics
    }

    public func discover() async throws -> [NasneDevice] {
        // 1 つずつ走査し、見つかった /24 で止める（仮想の /24 を後から走査し続けない）
        let bases = subnetBases()
        for (index, base) in bases.enumerated() {
            let started = ContinuousClock.now
            let devices = await scan(base)
            diagnostics(.discovery, "走査: /24 の \(index + 1) / \(bases.count) 個目・nasne \(devices.count) 台・"
                        + "\(started.elapsedMilliseconds) ms")
            if !devices.isEmpty { return devices }
        }
        return []
    }

    private func scan(_ base: String) async -> [NasneDevice] {
        let hosts = Self.hostNumbers.map { "\(base).\($0)" }
        var candidates: [String] = []
        for start in stride(from: 0, to: hosts.count, by: Self.concurrency) {
            let batch = hosts[start..<min(start + Self.concurrency, hosts.count)]
            await withTaskGroup(of: (String, Bool).self) { group in
                for host in batch {
                    group.addTask { (host, await probe(host)) }
                }
                for await (host, ok) in group where ok {
                    candidates.append(host)
                }
            }
        }
        var devices: [NasneDevice] = []
        for host in candidates.sorted() {
            if let device = try? await describer.describe(host: host) {
                if device.isNasne { devices.append(device) }
            } else {
                devices.append(NasneDevice.direct(host: host, profile: profile))
            }
        }
        return devices
    }

    /// 安い一次の篩：`status/boxNameGet` が errorcode 0 と name を返すか
    private func probe(_ host: String) async -> Bool {
        var request = URLRequest(url: NasneDevice.url(host: host, port: profile.ports.webAPI,
                                                      path: profile.webAPI.boxNameGet.path))
        request.timeoutInterval = Self.probeTimeout
        guard let (data, response) = try? await client.send(request), response.statusCode == 200,
              let object = try? JSONObject(data: data, source: "scan") else { return false }
        return object.int("errorcode") == 0 && object.string("name") != nil
    }
}

/// 自分の IPv4 の私設アドレス
public enum LocalNetwork {
    /// 自分に付いている私設 IPv4 アドレスの /24 の頭（「192.168.0」の形）。ネットマスクは /24 と仮定する
    @Sendable public static func privateSubnetBases() -> [String] {
        var bases = Set<String>()
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
                  entry.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0,
                              NI_NUMERICHOST) == 0 else { continue }
            let text = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if isPrivateIPv4(text) {
                bases.insert(text.split(separator: ".").prefix(3).joined(separator: "."))
            }
        }
        return bases.sorted()
    }

    /// 10/8・172.16/12・192.168/16
    public static func isPrivateIPv4(_ address: String) -> Bool {
        let parts = address.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        return isPrivateIPv4(octets: parts)
    }

    /// オクテットの配列で判定する（試験はこちらで書く。私設アドレスの文字列を直書きすると漏れ検査に当たるため）
    public static func isPrivateIPv4(octets: [Int]) -> Bool {
        guard octets.count == 4 else { return false }
        if octets[0] == 10 { return true }
        if octets[0] == 172, (16...31).contains(octets[1]) { return true }
        return octets[0] == 192 && octets[1] == 168
    }
}

/// 登録：MAC アドレスを取り → PIN を導き → `config/PINVerify` で確かめる。
/// PIN そのものは送らず、保存もしない（素の MAC アドレスだけを持つ）
public struct WebAPIRegistrationService: Sendable {
    private let client: any HTTPExchanging
    /// 頼み方の表。nil なら、登録では機器の記述に合う表、確かめでは `NasneProfiles.standard`
    private let profile: NasneProfile?
    /// 診断ログ（段の遷移だけ。MAC アドレス・PIN・トークンは出さない）
    private let diagnostics: NasneDiagnostics

    public init(client: any HTTPExchanging, profile: NasneProfile? = nil, diagnostics: NasneDiagnostics = .osLog) {
        self.client = client
        self.profile = profile
        self.diagnostics = diagnostics
    }

    public func register(_ device: NasneDevice, now: Date = Date()) async throws -> RegisteredNasne {
        let profile = profile ?? NasneProfiles.profile(for: device)
        let plain = WebAPITransport(host: device.host, client: client, profile: profile, diagnostics: diagnostics)
        let network = try await plain.getJSON(profile.webAPI.networkIfInfoGet)
        let macAddress = try network.requiredString("macAddr", source: "webapi:\(profile.webAPI.networkIfInfoGet.path)")
        let tokens = try TokenProvider(macAddress: macAddress)
        diagnostics(.webapi, "登録: MAC アドレスを読んだ。PINVerify で確かめる")
        // 確かめられなければ投げる（webapi・http・unreachable）
        _ = try await plain.authenticated(with: tokens).postJSON(profile.webAPI.pinVerify)
        diagnostics(.webapi, "登録: PINVerify が通った")
        return RegisteredNasne(host: device.host, udn: device.udn, friendlyName: device.friendlyName,
                               macAddress: macAddress, registeredAt: now)
    }

    /// 登録がまだ通るか。拒まれたら false、届かなければ投げる
    public func verify(_ registration: RegisteredNasne) async throws -> Bool {
        let profile = profile ?? NasneProfiles.standard
        let transport = WebAPITransport(host: registration.host, client: client, tokens: try registration.tokenProvider(),
                                        profile: profile, diagnostics: diagnostics)
        do {
            _ = try await transport.postJSON(profile.webAPI.pinVerify)
            return true
        } catch let error as NasneError where error.category == .webapi || error.category == .http {
            return false
        }
    }
}
