import CoreMedia
import Foundation
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case displayNotFound
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .displayNotFound: return "The display to capture is not available."
        case .permissionDenied: return "Spanscreen needs Screen Recording permission."
        }
    }
}

final class ScreenCapturer: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct Configuration: Equatable {
        var displayID: CGDirectDisplayID
        var width: Int
        var height: Int
        var framesPerSecond: Int
    }

    var onFrame: ((CVPixelBuffer) -> Void)?
    var onStop: ((Error?) -> Void)?
    private(set) var configuration: Configuration?
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "de.codext.spanscreen.capture", qos: .userInteractive)

    func start(_ configuration: Configuration) async throws {
        if let current = self.configuration, current.displayID == configuration.displayID, let stream {
            try await stream.updateConfiguration(Self.streamConfiguration(configuration))
            self.configuration = configuration
            return
        }
        await stop()
        let display = try await Self.findDisplay(configuration.displayID)
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: Self.streamConfiguration(configuration), delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        self.configuration = configuration
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        configuration = nil
        try? await stream.stopCapture()
    }

    private static func findDisplay(_ id: CGDirectDisplayID) async throws -> SCDisplay {
        var lastError: Error = CaptureError.displayNotFound
        for _ in 0..<30 {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                if let display = content.displays.first(where: { $0.displayID == id }) { return display }
            } catch {
                lastError = error
                if (error as NSError).code == SCStreamError.userDeclined.rawValue { throw CaptureError.permissionDenied }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw lastError
    }

    private static func streamConfiguration(_ c: Configuration) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = c.width
        config.height = c.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(c.framesPerSecond))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorSpaceName = CGColorSpace.sRGB
        config.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        config.queueDepth = 5
        config.showsCursor = true
        config.scalesToFit = true
        config.preservesAspectRatio = true
        config.captureResolution = .best
        config.capturesAudio = false
        return config
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }
        onFrame?(pixelBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard stream === self.stream else { return }
        self.stream = nil
        configuration = nil
        onStop?(error)
    }
}
