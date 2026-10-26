import AVFoundation
import CoreMedia
import SpanscreenKit
import UIKit

final class VideoRenderer: @unchecked Sendable {
    let layer = AVSampleBufferDisplayLayer()
    var onNeedsKeyframe: (() -> Void)?
    var onFirstFrame: (() -> Void)?
    private let lock = NSLock()
    private var format: CMVideoFormatDescription?
    private var waitingForKeyframe = true
    private var hasShownFrame = false
    private var lastKeyframeRequest: CFTimeInterval = 0
    private(set) var videoSize = CGSize.zero

    init() {
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = UIColor.black.cgColor
        layer.preventsDisplaySleepDuringVideoPlayback = true
    }

    func setFormat(_ stream: StreamFormat) {
        guard let description = Self.makeFormat(stream) else {
            onNeedsKeyframe?()
            return
        }
        lock.withLock {
            format = description
            videoSize = CGSize(width: stream.width, height: stream.height)
            waitingForKeyframe = true
        }
        layer.sampleBufferRenderer.flush()
    }

    func reset() {
        lock.withLock {
            waitingForKeyframe = true
            hasShownFrame = false
        }
        layer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
    }

    func armFirstFrame() {
        lock.withLock { hasShownFrame = false }
    }

    func resumeAfterBackground() {
        lock.withLock { waitingForKeyframe = true }
        layer.sampleBufferRenderer.flush()
        onNeedsKeyframe?()
    }

    func enqueue(_ frame: VideoFrame) {
        let renderer = layer.sampleBufferRenderer
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            renderer.flush()
            lock.withLock { waitingForKeyframe = true }
            requestKeyframeThrottled()
        }
        let (description, skip, first) = lock.withLock { () -> (CMVideoFormatDescription?, Bool, Bool) in
            if waitingForKeyframe {
                if frame.isKeyframe { waitingForKeyframe = false } else { return (format, true, false) }
            }
            let first = !hasShownFrame
            hasShownFrame = true
            return (format, false, first)
        }
        guard let description, !skip else {
            if skip { requestKeyframeThrottled() }
            return
        }
        guard let sample = Self.makeSample(frame.data, format: description) else { return }
        renderer.enqueue(sample)
        if first { onFirstFrame?() }
    }

    private func requestKeyframeThrottled() {
        let now = CACurrentMediaTime()
        let send = lock.withLock { () -> Bool in
            guard now - lastKeyframeRequest > 0.3 else { return false }
            lastKeyframeRequest = now
            return true
        }
        if send { onNeedsKeyframe?() }
    }

    private static func makeFormat(_ stream: StreamFormat) -> CMVideoFormatDescription? {
        let sets = stream.parameterSets
        guard !sets.isEmpty else { return nil }
        let buffers = sets.map { data -> UnsafeMutablePointer<UInt8> in
            let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count)
            data.copyBytes(to: pointer, count: data.count)
            return pointer
        }
        defer { buffers.forEach { $0.deallocate() } }
        let pointers = buffers.map { UnsafePointer($0) }
        let sizes = sets.map(\.count)
        var description: CMVideoFormatDescription?
        let status: OSStatus
        switch stream.codec {
        case .hevc:
            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: sets.count, parameterSetPointers: pointers, parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &description)
        case .h264:
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: sets.count, parameterSetPointers: pointers, parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &description)
        }
        return status == noErr ? description : nil
    }

    private static func makeSample(_ data: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count, blockAllocator: kCFAllocatorDefault,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: data.count, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == kCMBlockBufferNoErr, let block else { return nil }
        let copied = data.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }
        var sample: CMSampleBuffer?
        var size = data.count
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size,
                                        sampleBufferOut: &sample) == noErr, let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}
