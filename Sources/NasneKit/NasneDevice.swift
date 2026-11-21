// torne mobile HB（MIT、© mar1mo-41414）の lib/core/models/device.dart と services/discovery.dart の
// デバイス記述の読み方を Swift へ移植したもの。

import Foundation

/// デバイス記述にあった UPnP のサービス 1 つ（control URL は絶対 URL に直してある）
public struct UPnPServiceInfo: Sendable, Equatable {
    public let serviceType: String
    public let controlURL: URL
    public let scpdURL: URL?
    public let eventSubURL: URL?
}

/// 発見した UPnP の機器。nasne かどうかはデバイス記述の中身で判定する
/// （実機の SSDP の応答には DMS の USN が無いので、ヘッダには頼らない。plan.md §11.2）
public struct NasneDevice: Sendable, Equatable {
    /// デバイス記述を取ったホスト（IP アドレスかホスト名）。ログ・画面にそのまま出さない
    public let host: String
    public let descriptionURL: URL
    public let friendlyName: String
    public let modelName: String
    public let manufacturer: String
    /// UDN（uuid:…）。アドレスが変わったときの探し直しの手がかり
    public let udn: String
    /// serviceType → サービス
    public let services: [String: UPnPServiceInfo]

    /// nasne の modelName（実測。SIE 製の個体）。手で入れたアドレスから作るときの名前にも使う
    public static let nasneModelName = "nasne"
    /// Buffalo 製の個体の modelName（実測。manufacturer は Buffalo Inc.）
    public static let buffaloNasneModelName = "buffalo-nasne"
    /// nasne と見なす modelName（実測したものだけ）
    public static let nasneModelNames: Set<String> = [nasneModelName, buffaloNasneModelName]

    public var isNasne: Bool { Self.nasneModelNames.contains(modelName) }

    /// SIE 製の個体のデバイス記述の在りか（DMS のポートの `/`。Buffalo 製は SSDP の LOCATION にだけある）
    static let descriptionRootPath = "/"

    /// サービスの control URL。デバイス記述に無ければ、実測した既定のパスで作る
    public func controlURL(for service: SOAPService) -> URL {
        if let url = services[service.serviceType]?.controlURL { return url }
        return Self.url(host: host, port: service.defaultPort, path: service.fallbackControlPaths[0])
    }

    static func url(host: String, port: Int, path: String) -> URL {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = port
        components.path = path
        return components.url!
    }

    /// 手で入れたアドレスから作る（デバイス記述を取れなかったとき）。表の既定の control URL を使う
    public static func direct(host: String, profile: NasneProfile = NasneProfiles.standard) -> NasneDevice {
        var services: [String: UPnPServiceInfo] = [:]
        for service in profile.soap.knownServices {
            services[service.serviceType] = UPnPServiceInfo(
                serviceType: service.serviceType,
                controlURL: url(host: host, port: service.defaultPort, path: service.fallbackControlPaths[0]),
                scpdURL: nil, eventSubURL: nil)
        }
        return NasneDevice(host: host, descriptionURL: url(host: host, port: profile.ports.dms, path: descriptionRootPath),
                           friendlyName: nasneModelName, modelName: nasneModelName, manufacturer: "", udn: "",
                           services: services)
    }

    /// デバイス記述の文書を読む。`location` は文書を取った URL で、相対の control URL の基点
    public static func parseDescription(_ data: Data, location: URL) throws -> NasneDevice {
        let source = "ssdp:describe"
        let root = try XMLTree.parse(data, source: source)
        guard let device = root.firstDescendant(named: "device") else {
            throw NasneError.parse(source, "<device> の要素が無い")
        }
        func text(_ name: String) -> String { device.childText(name)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        func resolve(_ value: String?) -> URL? {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return URL(string: value, relativeTo: location)?.absoluteURL
        }
        var services: [String: UPnPServiceInfo] = [:]
        for service in device.child(named: "serviceList")?.children(named: "service") ?? [] {
            guard let type = service.childText("serviceType")?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let control = resolve(service.childText("controlURL")) else { continue }
            services[type] = UPnPServiceInfo(serviceType: type, controlURL: control,
                                             scpdURL: resolve(service.childText("SCPDURL")),
                                             eventSubURL: resolve(service.childText("eventSubURL")))
        }
        return NasneDevice(host: location.host ?? "", descriptionURL: location, friendlyName: text("friendlyName"),
                           modelName: text("modelName"), manufacturer: text("manufacturer"), udn: text("UDN"),
                           services: services)
    }
}

/// 登録した nasne。PIN は持たず、PIN の素の MAC アドレスを持つ（保存先は Keychain）
public struct RegisteredNasne: Sendable, Equatable, Codable {
    public var host: String
    public var udn: String
    public var friendlyName: String
    /// `status/networkIfInfoGet` の macAddr（PIN の素）。ログ・画面にそのまま出さない
    public var macAddress: String
    public var registeredAt: Date?

    public init(host: String, udn: String, friendlyName: String, macAddress: String, registeredAt: Date? = nil) {
        self.host = host
        self.udn = udn
        self.friendlyName = friendlyName
        self.macAddress = macAddress
        self.registeredAt = registeredAt
    }

    public func tokenProvider() throws -> TokenProvider {
        try TokenProvider(macAddress: macAddress)
    }
}
