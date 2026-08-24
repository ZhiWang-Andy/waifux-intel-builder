import Foundation
import ScreenCaptureKit
import CoreMedia
import AudioToolbox
import Darwin

private enum BridgeError: Error, CustomStringConvertible {
    case noDisplay
    case unsupportedAudioFormat(String)

    var description: String {
        switch self {
        case .noDisplay:
            return "no display available for ScreenCaptureKit"
        case .unsupportedAudioFormat(let detail):
            return "unsupported audio format: \(detail)"
        }
    }
}

final class SystemAudioLevelBridge: NSObject, SCStreamOutput, SCStreamDelegate {
    private let outputURL: URL
    private let sampleQueue = DispatchQueue(label: "waifux.scene.audio.bridge", qos: .userInitiated)
    private var stream: SCStream?
    private var smoothLeft: Float = 0
    private var smoothRight: Float = 0
    private var lastLogNs: UInt64 = 0
    private var warnedFormat = false

    private let gain: Float

    init(outputPath: String) {
        self.outputURL = URL(fileURLWithPath: outputPath)
        if let raw = ProcessInfo.processInfo.environment["WAIFUX_AUDIO_GAIN"],
           let parsed = Float(raw), parsed > 0 {
            self.gain = parsed
        } else {
            self.gain = 6.0
        }
        super.init()
    }

    func start() async throws {
        try writeLevels(left: 0, right: 0)

        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let display = content.displays.first else {
            throw BridgeError.noDisplay
        }

        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: []
        )

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        // We only consume .audio. Keep the video side intentionally tiny.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()
        self.stream = stream

        print("[audio-bridge] ScreenCaptureKit system audio capture started")
        print("[audio-bridge] output: \(outputURL.path)")
        print("[audio-bridge] envelope gain: \(gain)x")
        print("[audio-bridge] stage-1 mode: stereo RMS envelope copied to all 16 WE spectrum bands")
        fflush(stdout)
    }

    func stop() async {
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        try? writeLevels(left: 0, right: 0)
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio else { return }
        guard let (leftRMS, rightRMS) = rmsLevels(from: sampleBuffer) else { return }

        let targetLeft = min(max(leftRMS * gain, 0), 1)
        let targetRight = min(max(rightRMS * gain, 0), 1)

        // Faster attack, slower release so visible Scene response does not flicker.
        smoothLeft += (targetLeft - smoothLeft) * (targetLeft > smoothLeft ? 0.48 : 0.10)
        smoothRight += (targetRight - smoothRight) * (targetRight > smoothRight ? 0.48 : 0.10)

        try? writeLevels(left: smoothLeft, right: smoothRight)

        let now = DispatchTime.now().uptimeNanoseconds
        if now &- lastLogNs >= 500_000_000 {
            lastLogNs = now
            print(String(format: "[audio-bridge] L=%.3f R=%.3f", smoothLeft, smoothRight))
            fflush(stdout)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        fputs("[audio-bridge] stream stopped: \(error.localizedDescription)\n", stderr)
        try? writeLevels(left: 0, right: 0)
    }

    private func writeLevels(left: Float, right: Float) throws {
        // Renderer input format: exactly 32 whitespace-separated floats.
        // First 16 = left, second 16 = right. Stage 1 intentionally repeats
        // the broadband envelope; Stage 2 will replace this with a real FFT.
        let values = Array(repeating: left, count: 16) + Array(repeating: right, count: 16)
        let text = values.map { String(format: "%.6f", $0) }.joined(separator: " ") + "\n"
        try Data(text.utf8).write(to: outputURL, options: .atomic)
    }

    private func rmsLevels(from sampleBuffer: CMSampleBuffer) -> (Float, Float)? {
        guard CMSampleBufferIsValid(sampleBuffer),
              CMSampleBufferDataIsReady(sampleBuffer),
              CMSampleBufferGetNumSamples(sampleBuffer) > 0,
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else { return nil }

        let asbd = asbdPtr.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM,
              (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0,
              asbd.mBitsPerChannel == 32
        else {
            if !warnedFormat {
                warnedFormat = true
                fputs("[audio-bridge] expected Float32 PCM from ScreenCaptureKit; got formatID=\(asbd.mFormatID) flags=\(asbd.mFormatFlags) bits=\(asbd.mBitsPerChannel)\n", stderr)
            }
            return nil
        }

        var neededSize = 0
        let sizeStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &neededSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: nil
        )
        guard sizeStatus == noErr, neededSize > 0 else { return nil }

        let storage = UnsafeMutableRawPointer.allocate(byteCount: neededSize, alignment: 16)
        defer { storage.deallocate() }
        let list = storage.bindMemory(to: AudioBufferList.self, capacity: 1)
        var blockBuffer: CMBlockBuffer?

        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: list,
            bufferListSize: neededSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, blockBuffer != nil else { return nil }

        return withExtendedLifetime(blockBuffer) {
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            let channelCount = max(Int(asbd.mChannelsPerFrame), 1)
            let nonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0

            if nonInterleaved {
                guard let left = rms(buffer: buffers[0]) else { return nil }
                let right: Float
                if buffers.count >= 2, let r = rms(buffer: buffers[1]) {
                    right = r
                } else {
                    right = left
                }
                return (left, right)
            }

            guard buffers.count >= 1,
                  let data = buffers[0].mData else { return nil }
            let floatCount = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size
            guard floatCount >= channelCount else { return nil }
            let ptr = data.assumingMemoryBound(to: Float.self)

            var leftSum: Double = 0
            var rightSum: Double = 0
            var frames = 0
            var i = 0
            while i + channelCount <= floatCount {
                let l = Double(ptr[i])
                let r = Double(ptr[i + min(1, channelCount - 1)])
                leftSum += l * l
                rightSum += r * r
                frames += 1
                i += channelCount
            }
            guard frames > 0 else { return nil }
            return (
                Float(sqrt(leftSum / Double(frames))),
                Float(sqrt(rightSum / Double(frames)))
            )
        }
    }

    private func rms(buffer: AudioBuffer) -> Float? {
        guard let data = buffer.mData else { return nil }
        let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
        guard count > 0 else { return nil }
        let ptr = data.assumingMemoryBound(to: Float.self)
        var sum: Double = 0
        for i in 0..<count {
            let x = Double(ptr[i])
            sum += x * x
        }
        return Float(sqrt(sum / Double(count)))
    }
}

@main
struct Main {
    static func main() async {
        let args = CommandLine.arguments
        let defaultPath = NSHomeDirectory() + "/Library/Application Support/WaifuX Intel Scene Experimental/live-audio-spectrum.txt"
        let outputPath = args.count >= 2 ? args[1] : defaultPath

        do {
            let parent = URL(fileURLWithPath: outputPath).deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

            let bridge = SystemAudioLevelBridge(outputPath: outputPath)
            try await bridge.start()

            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
            await bridge.stop()
        } catch {
            fputs("[audio-bridge] ERROR: \(error)\n", stderr)
            fputs("[audio-bridge] If macOS denied capture, enable Terminal under Privacy & Security > Screen & System Audio Recording, then restart Terminal and retry.\n", stderr)
            exit(1)
        }
    }
}
