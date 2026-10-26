import Foundation

public enum Spanscreen {
    public static let protocolVersion = 1
    public static let displayServiceType = "_spanscreen._tcp"
    public static let hostServiceType = "_spanscreen-host._tcp"
    public static let devicePort: UInt16 = 47_913
    public static let maxMessageSize = 32 * 1024 * 1024
    public static let macDownloadURL = URL(string: "https://codextde.github.io/spanscreen/#download")!
    public static let macDirectDownloadURL = URL(string: "https://github.com/codextde/spanscreen/releases/latest/download/Spanscreen.dmg")!
    public static let iOSAppURL = URL(string: "https://apps.apple.com/app/id6827203170")!
    public static let websiteURL = URL(string: "https://codextde.github.io/spanscreen/")!
}

public enum MessageType: UInt8, Sendable {
    case deviceInfo = 1
    case hostHello = 2
    case accept = 3
    case decline = 4
    case format = 5
    case frame = 6
    case display = 7
    case input = 8
    case keyframeRequest = 9
    case ack = 10
    case ping = 11
    case pong = 12
    case session = 13
    case setOptions = 14
    case pause = 15
    case resume = 16
    case bye = 17
    case connectRequest = 18
}

public struct DisplayInfo: Codable, Equatable, Sendable {
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var scale: Double
    public var pixelsPerInch: Double
    public var maxRefreshRate: Int

    public init(pixelWidth: Int, pixelHeight: Int, scale: Double, pixelsPerInch: Double, maxRefreshRate: Int) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.scale = scale
        self.pixelsPerInch = pixelsPerInch
        self.maxRefreshRate = maxRefreshRate
    }

    public var isPortrait: Bool { pixelHeight > pixelWidth }

    public var physicalSizeMillimeters: (width: Double, height: Double) {
        let ppi = pixelsPerInch > 0 ? pixelsPerInch : 460
        return (Double(pixelWidth) / ppi * 25.4, Double(pixelHeight) / ppi * 25.4)
    }
}

public struct DeviceInfo: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var deviceID: String
    public var name: String
    public var model: String
    public var appVersion: String
    public var display: DisplayInfo
    public var busy: Bool
    public var nonce: Data

    public init(protocolVersion: Int = Spanscreen.protocolVersion, deviceID: String, name: String, model: String, appVersion: String, display: DisplayInfo, busy: Bool = false, nonce: Data = Pairing.nonce()) {
        self.protocolVersion = protocolVersion
        self.deviceID = deviceID
        self.name = name
        self.model = model
        self.appVersion = appVersion
        self.display = display
        self.busy = busy
        self.nonce = nonce
    }
}

public enum HostIntent: String, Codable, Sendable {
    case probe
    case connect
}

public struct HostHello: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var hostID: String
    public var name: String
    public var model: String
    public var appVersion: String
    public var intent: HostIntent
    public var requestedByDevice: Bool
    public var nonce: Data
    public var publicKey: Data
    public var proof: Data?

    public init(protocolVersion: Int = Spanscreen.protocolVersion, hostID: String, name: String, model: String, appVersion: String, intent: HostIntent,
                requestedByDevice: Bool = false, nonce: Data = Pairing.nonce(), publicKey: Data = Data(), proof: Data? = nil) {
        self.protocolVersion = protocolVersion
        self.hostID = hostID
        self.name = name
        self.model = model
        self.appVersion = appVersion
        self.intent = intent
        self.requestedByDevice = requestedByDevice
        self.nonce = nonce
        self.publicKey = publicKey
        self.proof = proof
    }
}

public struct AcceptInfo: Codable, Equatable, Sendable {
    public var proof: Data?
    public var publicKey: Data?

    public init(proof: Data? = nil, publicKey: Data? = nil) {
        self.proof = proof
        self.publicKey = publicKey
    }
}

public enum DeclineReason: String, Codable, Sendable {
    case userDeclined
    case busy
    case incompatible
}

public struct Decline: Codable, Equatable, Sendable {
    public var reason: DeclineReason
    public init(reason: DeclineReason) { self.reason = reason }
}

public enum DisplayMode: String, Codable, CaseIterable, Sendable {
    case extend
    case mirror
}

public enum TextSize: String, Codable, CaseIterable, Sendable {
    case larger
    case standard
    case moreSpace
    case mostSpace

    public var pixelsPerPoint: Double {
        switch self {
        case .larger: return 2.4
        case .standard: return 2.0
        case .moreSpace: return 1.6
        case .mostSpace: return 1.33
        }
    }
}

public enum StreamQuality: String, Codable, CaseIterable, Sendable {
    case efficient
    case balanced
    case best

    public var bitsPerPixelFrame: Double {
        switch self {
        case .efficient: return 0.05
        case .balanced: return 0.09
        case .best: return 0.16
        }
    }
}

public struct SessionOptions: Codable, Equatable, Sendable {
    public var mode: DisplayMode
    public var textSize: TextSize
    public var quality: StreamQuality
    public var highRefreshRate: Bool

    public init(mode: DisplayMode = .extend, textSize: TextSize = .standard, quality: StreamQuality = .balanced, highRefreshRate: Bool = false) {
        self.mode = mode
        self.textSize = textSize
        self.quality = quality
        self.highRefreshRate = highRefreshRate
    }
}

public enum TransportKind: String, Codable, Sendable {
    case wifi
    case usb
}

public struct SessionState: Codable, Equatable, Sendable {
    public var hostName: String
    public var options: SessionOptions
    public var transport: TransportKind
    public var canUseHighRefreshRate: Bool

    public init(hostName: String, options: SessionOptions, transport: TransportKind, canUseHighRefreshRate: Bool) {
        self.hostName = hostName
        self.options = options
        self.transport = transport
        self.canUseHighRefreshRate = canUseHighRefreshRate
    }
}

public enum VideoCodec: String, Codable, Sendable {
    case hevc
    case h264
}

public struct StreamFormat: Codable, Equatable, Sendable {
    public var codec: VideoCodec
    public var width: Int
    public var height: Int
    public var parameterSets: [Data]
    public var refreshRate: Int

    public init(codec: VideoCodec, width: Int, height: Int, parameterSets: [Data], refreshRate: Int) {
        self.codec = codec
        self.width = width
        self.height = height
        self.parameterSets = parameterSets
        self.refreshRate = refreshRate
    }
}

public struct Ack: Codable, Equatable, Sendable {
    public var frameIndex: UInt32
    public init(frameIndex: UInt32) { self.frameIndex = frameIndex }
}

public struct Ping: Codable, Equatable, Sendable {
    public var sentAt: Double
    public var latencyMilliseconds: Double?
    public var bitrate: Double?
    public var framesPerSecond: Double?

    public init(sentAt: Double, latencyMilliseconds: Double? = nil, bitrate: Double? = nil, framesPerSecond: Double? = nil) {
        self.sentAt = sentAt
        self.latencyMilliseconds = latencyMilliseconds
        self.bitrate = bitrate
        self.framesPerSecond = framesPerSecond
    }
}

public struct ConnectRequest: Codable, Equatable, Sendable {
    public var deviceID: String
    public var name: String
    public init(deviceID: String, name: String) {
        self.deviceID = deviceID
        self.name = name
    }
}
