import CoreMedia
import Foundation
import SpanscreenKit

struct StreamStats: Equatable {
    var latencyMilliseconds: Double = 0
    var bitrate: Double = 0
    var framesPerSecond: Double = 0
}

final class StreamPipeline: @unchecked Sendable {
    var onStats: ((StreamStats) -> Void)?
    var onCaptureStopped: ((Error?) -> Void)?

    private let queue = DispatchQueue(label: "de.codext.spanscreen.pipeline", qos: .userInteractive)
    private let encoder = VideoEncoder()
    private let capturer: ScreenCapturer
    private var transport: MessageTransport?
    private var frameIndex: UInt32 = 0
    private var lastAcked: UInt32 = 0
    private var latestBuffer: CVPixelBuffer?
    private var pendingFrame = false
    private var lastFrameAt: UInt64 = 0
    private var refinements = 0
    private var sentFormat: StreamFormat?
    private var refreshRate = 60
    private var targetBitrate = 20_000_000
    private var minimumBitrate = 3_000_000
    private var bitrate = 20_000_000
    private var maxInFlight = 4
    private var paused = true
    private var sendTimes: [UInt32: UInt64] = [:]
    private var latencySamples: [Double] = []
    private var bytesThisWindow = 0
    private var framesThisWindow = 0
    private var dropsThisWindow = 0
    private var windowStart: UInt64 = 0
    private var timer: DispatchSourceTimer?

    init() {
        capturer = ScreenCapturer()
        capturer.onFrame = { [weak self] buffer in
            self?.queue.async { self?.handleCaptured(buffer) }
        }
        capturer.onStop = { [weak self] error in self?.onCaptureStopped?(error) }
        encoder.onOutput = { [weak self] output in
            self?.queue.async { self?.send(output) }
        }
    }

    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds / 1_000 }

    func setTransport(_ transport: MessageTransport?) {
        queue.sync {
            self.transport = transport
            lastAcked = frameIndex
            sendTimes.removeAll()
            sentFormat = nil
            pendingFrame = false
        }
        if transport != nil { requestKeyframe() }
    }

    func start(capture: ScreenCapturer.Configuration, targetBitrate: Int, maxBitrate: Int) async throws {
        queue.sync {
            refreshRate = capture.framesPerSecond
            maxInFlight = capture.framesPerSecond > 60 ? 6 : 4
            self.targetBitrate = min(targetBitrate, maxBitrate)
            minimumBitrate = max(2_000_000, self.targetBitrate / 8)
            bitrate = self.targetBitrate
            sentFormat = nil
            latestBuffer = nil
            paused = false
        }
        try encoder.configure(width: capture.width, height: capture.height, framesPerSecond: capture.framesPerSecond, bitrate: bitrate)
        encoder.requestKeyframe()
        try await capturer.start(capture)
        startTimer()
    }

    func stop() async {
        queue.sync {
            paused = true
            latestBuffer = nil
        }
        timer?.cancel()
        timer = nil
        await capturer.stop()
        encoder.invalidate()
    }

    func pause() {
        queue.async { self.paused = true }
    }

    func resume() {
        queue.async {
            self.paused = false
            self.lastAcked = self.frameIndex
            self.sendTimes.removeAll()
        }
        requestKeyframe()
    }

    func requestKeyframe() {
        encoder.requestKeyframe()
        queue.async {
            guard !self.paused, self.latestBuffer != nil else { return }
            if self.inFlight < self.maxInFlight { self.encodeLatest() } else { self.pendingFrame = true }
        }
    }

    func acknowledge(_ index: UInt32) {
        queue.async {
            guard index > self.lastAcked, index <= self.frameIndex else { return }
            self.lastAcked = index
            if let sentAt = self.sendTimes.removeValue(forKey: index) {
                self.latencySamples.append(Double(Self.now() - sentAt) / 1_000)
            }
            self.sendTimes = self.sendTimes.filter { $0.key > index }
            if self.pendingFrame, self.inFlight < self.maxInFlight {
                self.pendingFrame = false
                self.encodeLatest()
            }
        }
    }

    private var inFlight: Int { Int(frameIndex &- lastAcked) }

    private func handleCaptured(_ buffer: CVPixelBuffer) {
        latestBuffer = buffer
        lastFrameAt = Self.now()
        refinements = 0
        guard !paused, transport != nil else { return }
        if inFlight >= maxInFlight {
            pendingFrame = true
            dropsThisWindow += 1
            return
        }
        encodeLatest()
    }

    private func encodeLatest() {
        guard let buffer = latestBuffer else { return }
        encoder.encode(buffer, captureTime: Self.now())
    }

    private func send(_ output: VideoEncoder.Output) {
        guard let transport, !paused else { return }
        if let sets = output.parameterSets {
            let format = StreamFormat(codec: output.codec, width: output.width, height: output.height, parameterSets: sets, refreshRate: refreshRate)
            if format != sentFormat {
                sentFormat = format
                transport.send(.format, format)
            }
        }
        guard sentFormat != nil else {
            encoder.requestKeyframe()
            if inFlight < maxInFlight { encodeLatest() } else { pendingFrame = true }
            return
        }
        frameIndex &+= 1
        sendTimes[frameIndex] = output.captureTime
        bytesThisWindow += output.data.count
        framesThisWindow += 1
        let frame = VideoFrame(index: frameIndex, isKeyframe: output.isKeyframe, captureTime: output.captureTime, data: output.data)
        transport.send(Message(type: .frame, payload: frame.encoded()))
    }

    private func startTimer() {
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
        windowStart = Self.now()
    }

    private func tick() {
        let now = Self.now()
        if !paused, transport != nil, latestBuffer != nil, refinements < 2, inFlight == 0, now - lastFrameAt > 250_000 {
            refinements += 1
            lastFrameAt = now
            encodeLatest()
        }
        if !paused, inFlight > 0, let oldest = sendTimes.keys.min(), let sentAt = sendTimes[oldest], now - sentAt > 2_000_000 {
            lastAcked = frameIndex
            sendTimes.removeAll()
            encoder.requestKeyframe()
            encodeLatest()
        }
        let elapsed = Double(now - windowStart) / 1_000_000
        guard elapsed >= 1 else { return }
        let latency = latencySamples.isEmpty ? 0 : latencySamples.reduce(0, +) / Double(latencySamples.count)
        if dropsThisWindow > 2 || latency > 70 {
            bitrate = max(minimumBitrate, Int(Double(bitrate) * 0.75))
            encoder.setBitrate(bitrate)
        } else if dropsThisWindow == 0, latency < 35, bitrate < targetBitrate {
            bitrate = min(targetBitrate, Int(Double(bitrate) * 1.1))
            encoder.setBitrate(bitrate)
        }
        let stats = StreamStats(latencyMilliseconds: latency, bitrate: Double(bytesThisWindow * 8) / elapsed, framesPerSecond: Double(framesThisWindow) / elapsed)
        latencySamples.removeAll(keepingCapacity: true)
        bytesThisWindow = 0
        framesThisWindow = 0
        dropsThisWindow = 0
        windowStart = now
        onStats?(stats)
    }
}
