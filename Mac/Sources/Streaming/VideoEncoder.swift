import CoreMedia
import Foundation
import SpanscreenKit
import VideoToolbox

final class VideoEncoder: @unchecked Sendable {
    struct Output {
        var data: Data
        var isKeyframe: Bool
        var parameterSets: [Data]?
        var captureTime: UInt64
        var codec: VideoCodec
        var width: Int
        var height: Int
    }

    var onOutput: ((Output) -> Void)?
    private(set) var codec: VideoCodec = .hevc
    private(set) var width = 0
    private(set) var height = 0
    private var session: VTCompressionSession?
    private var frameCount: Int64 = 0
    private var framesPerSecond = 60
    private var bitrate = 20_000_000
    private let lock = NSLock()
    private let keyLock = NSLock()
    private var forceKeyframe = true

    deinit { Self.finish(session) }

    func configure(width: Int, height: Int, framesPerSecond: Int, bitrate: Int) throws {
        lock.lock()
        if session != nil, width == self.width, height == self.height, framesPerSecond == self.framesPerSecond {
            applyBitrate(bitrate)
            lock.unlock()
            return
        }
        let old = session
        session = nil
        lock.unlock()
        Self.finish(old)
        lock.lock(); defer { lock.unlock() }
        self.width = width
        self.height = height
        self.framesPerSecond = framesPerSecond
        var created: VTCompressionSession?
        for candidate in [VideoCodec.hevc, .h264] {
            if let s = Self.makeSession(codec: candidate, width: width, height: height) {
                created = s
                codec = candidate
                break
            }
        }
        guard let session = created else { throw NSError(domain: "Spanscreen", code: 1, userInfo: [NSLocalizedDescriptionKey: "No hardware video encoder available."]) }
        let profile = codec == .hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: profile)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: framesPerSecond as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 100_000 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 3_600 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ColorPrimaries, value: kCVImageBufferColorPrimaries_ITU_R_709_2)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_TransferFunction, value: kCVImageBufferTransferFunction_ITU_R_709_2)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_YCbCrMatrix, value: kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        VTCompressionSessionPrepareToEncodeFrames(session)
        self.session = session
        keyLock.withLock { forceKeyframe = true }
        applyBitrate(bitrate)
    }

    private static func makeSession(codec: VideoCodec, width: Int, height: Int) -> VTCompressionSession? {
        let type = codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
        let specs: [[CFString: Any]] = [
            [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true,
             kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true],
            [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
        ]
        for spec in specs {
            var session: VTCompressionSession?
            let status = VTCompressionSessionCreate(
                allocator: nil, width: Int32(width), height: Int32(height), codecType: type,
                encoderSpecification: spec as CFDictionary, imageBufferAttributes: nil,
                compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &session)
            if status == noErr, let session { return session }
        }
        return nil
    }

    func setBitrate(_ bitrate: Int) {
        lock.lock(); defer { lock.unlock() }
        applyBitrate(bitrate)
    }

    private func applyBitrate(_ value: Int) {
        bitrate = value
        guard let session else { return }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: value as CFNumber)
        let bytesPerSecond = Double(value) / 8 * 1.5
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: [bytesPerSecond, 1.0] as CFArray)
    }

    func requestKeyframe() {
        keyLock.withLock { forceKeyframe = true }
    }

    func encode(_ pixelBuffer: CVPixelBuffer, captureTime: UInt64) {
        lock.lock()
        guard let session else { lock.unlock(); return }
        frameCount += 1
        let pts = CMTime(value: frameCount, timescale: CMTimeScale(framesPerSecond))
        let codec = self.codec, width = self.width, height = self.height
        lock.unlock()
        let force = keyLock.withLock { () -> Bool in
            defer { forceKeyframe = false }
            return forceKeyframe
        }
        let properties: CFDictionary? = force ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        VTCompressionSessionEncodeFrame(session, imageBuffer: pixelBuffer, presentationTimeStamp: pts, duration: .invalid,
                                        frameProperties: properties, infoFlagsOut: nil) { [weak self] status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer, let self else {
                self?.requestKeyframe()
                return
            }
            self.emit(sampleBuffer, captureTime: captureTime, codec: codec, width: width, height: height)
        }
    }

    private func emit(_ sampleBuffer: CMSampleBuffer, captureTime: UInt64, codec: VideoCodec, width: Int, height: Int) {
        guard let block = sampleBuffer.dataBuffer else { return }
        let length = CMBlockBufferGetDataLength(block)
        var data = Data(count: length)
        let copied = data.withUnsafeMutableBytes { raw in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
        }
        guard copied == kCMBlockBufferNoErr else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        let isKeyframe = !notSync
        var parameterSets: [Data]?
        if isKeyframe, let format = sampleBuffer.formatDescription {
            parameterSets = Self.parameterSets(format, codec: codec)
        }
        onOutput?(Output(data: data, isKeyframe: isKeyframe, parameterSets: parameterSets, captureTime: captureTime, codec: codec, width: width, height: height))
    }

    private static func parameterSets(_ format: CMFormatDescription, codec: VideoCodec) -> [Data] {
        var count = 0
        var sets: [Data] = []
        var index = 0
        repeat {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status: OSStatus
            if codec == .hevc {
                status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            } else {
                status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            }
            guard status == noErr, let pointer else { break }
            sets.append(Data(bytes: pointer, count: size))
            index += 1
        } while index < count
        return sets
    }

    func invalidate() {
        lock.lock()
        let old = session
        session = nil
        lock.unlock()
        Self.finish(old)
    }

    private static func finish(_ session: VTCompressionSession?) {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
    }
}
