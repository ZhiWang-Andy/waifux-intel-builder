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

private enum AudioAnalysisMode: String {
    case fft
    case rms
}

final class SystemAudioLevelBridge: NSObject, SCStreamOutput, SCStreamDelegate {
    private let outputURL: URL
    private let sampleQueue = DispatchQueue(label: "waifux.scene.audio.bridge", qos: .userInitiated)
    private var stream: SCStream?

    private let sampleRate = 48_000
    private let fftSize = 2_048
    private let hopSize = 1_024
    private let gain: Float
    private let mode: AudioAnalysisMode
    private let hannWindow: [Double]
    private let bandRanges: [(Int, Int)]

    private var leftPCM: [Float] = []
    private var rightPCM: [Float] = []
    private var smoothLeftBands = Array(repeating: Float(0), count: 16)
    private var smoothRightBands = Array(repeating: Float(0), count: 16)
    private var lastLogNs: UInt64 = 0
    private var warnedFormat = false

    init(outputPath: String) {
        self.outputURL = URL(fileURLWithPath: outputPath)

        if let raw = ProcessInfo.processInfo.environment["WAIFUX_AUDIO_GAIN"],
           let parsed = Float(raw), parsed > 0 {
            self.gain = parsed
        } else {
            self.gain = 10.0
        }

        let modeRaw = ProcessInfo.processInfo.environment["WAIFUX_AUDIO_MODE"]?.lowercased() ?? "fft"
        self.mode = AudioAnalysisMode(rawValue: modeRaw) ?? .fft

        self.hannWindow = (0..<2_048).map { i in
            0.5 - 0.5 * cos(2.0 * Double.pi * Double(i) / Double(2_048 - 1))
        }

        // 16 logarithmic bands from 20 Hz to 20 kHz. The renderer expects
        // the same compact 16-band left/right layout used by Wallpaper Engine.
        var ranges: [(Int, Int)] = []
        let minHz = 20.0
        let maxHz = 20_000.0
        let ratio = pow(maxHz / minHz, 1.0 / 16.0)
        for band in 0..<16 {
            let lowHz = minHz * pow(ratio, Double(band))
            let highHz = minHz * pow(ratio, Double(band + 1))
            let lowBin = max(1, Int(floor(lowHz * Double(2_048) / 48_000.0)))
            let highBin = min(2_048 / 2, max(lowBin, Int(ceil(highHz * Double(2_048) / 48_000.0))))
            ranges.append((lowBin, highBin))
        }
        self.bandRanges = ranges

        super.init()
    }

    func start() async throws {
        try writeSpectrum(left: Array(repeating: 0, count: 16), right: Array(repeating: 0, count: 16))

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
        config.sampleRate = sampleRate
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
        print("[audio-bridge] analysis mode: \(mode.rawValue)")
        print("[audio-bridge] gain: \(gain)x")
        if mode == .fft {
            print("[audio-bridge] FFT: 2048-point Hann window, 50% overlap, 16 logarithmic bands (20 Hz-20 kHz)")
        } else {
            print("[audio-bridge] RMS compatibility mode: stereo envelope copied to all 16 bands")
        }
        fflush(stdout)
    }

    func stop() async {
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        try? writeSpectrum(left: Array(repeating: 0, count: 16), right: Array(repeating: 0, count: 16))
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio else { return }
        guard let (left, right) = pcmChannels(from: sampleBuffer) else { return }

        switch mode {
        case .rms:
            processRMS(left: left, right: right)
        case .fft:
            processFFT(left: left, right: right)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        fputs("[audio-bridge] stream stopped: \(error.localizedDescription)\n", stderr)
        try? writeSpectrum(left: Array(repeating: 0, count: 16), right: Array(repeating: 0, count: 16))
    }

    private func processRMS(left: [Float], right: [Float]) {
        let leftRMS = rms(samples: left)
        let rightRMS = rms(samples: right)
        let targetLeft = min(max(leftRMS * gain, 0), 1)
        let targetRight = min(max(rightRMS * gain, 0), 1)

        for i in 0..<16 {
            smoothLeftBands[i] += (targetLeft - smoothLeftBands[i]) * (targetLeft > smoothLeftBands[i] ? 0.48 : 0.10)
            smoothRightBands[i] += (targetRight - smoothRightBands[i]) * (targetRight > smoothRightBands[i] ? 0.48 : 0.10)
        }

        try? writeSpectrum(left: smoothLeftBands, right: smoothRightBands)
        logLevelsIfNeeded(prefix: "RMS")
    }

    private func processFFT(left: [Float], right: [Float]) {
        leftPCM.append(contentsOf: left)
        rightPCM.append(contentsOf: right)

        while leftPCM.count >= fftSize && rightPCM.count >= fftSize {
            let leftFrame = Array(leftPCM.prefix(fftSize))
            let rightFrame = Array(rightPCM.prefix(fftSize))
            let leftTarget = fftBands(samples: leftFrame)
            let rightTarget = fftBands(samples: rightFrame)

            for i in 0..<16 {
                let l = leftTarget[i]
                let r = rightTarget[i]
                smoothLeftBands[i] += (l - smoothLeftBands[i]) * (l > smoothLeftBands[i] ? 0.55 : 0.16)
                smoothRightBands[i] += (r - smoothRightBands[i]) * (r > smoothRightBands[i] ? 0.55 : 0.16)
            }

            try? writeSpectrum(left: smoothLeftBands, right: smoothRightBands)
            leftPCM.removeFirst(min(hopSize, leftPCM.count))
            rightPCM.removeFirst(min(hopSize, rightPCM.count))
        }

        // Prevent an unusual capture burst from growing the buffers forever.
        if leftPCM.count > fftSize * 4 {
            leftPCM = Array(leftPCM.suffix(fftSize * 2))
        }
        if rightPCM.count > fftSize * 4 {
            rightPCM = Array(rightPCM.suffix(fftSize * 2))
        }

        logLevelsIfNeeded(prefix: "FFT")
    }

    private func fftBands(samples: [Float]) -> [Float] {
        guard samples.count == fftSize else { return Array(repeating: 0, count: 16) }

        var real = Array(repeating: Double(0), count: fftSize)
        var imag = Array(repeating: Double(0), count: fftSize)
        for i in 0..<fftSize {
            real[i] = Double(samples[i]) * hannWindow[i]
        }

        // Iterative radix-2 Cooley-Tukey FFT. Keeping it local avoids a
        // dependency on a second DSP runtime and is inexpensive at 2048 points.
        var j = 0
        if fftSize > 1 {
            for i in 1..<fftSize {
                var bit = fftSize >> 1
                while (j & bit) != 0 {
                    j ^= bit
                    bit >>= 1
                }
                j ^= bit
                if i < j {
                    real.swapAt(i, j)
                    imag.swapAt(i, j)
                }
            }
        }

        var length = 2
        while length <= fftSize {
            let angle = -2.0 * Double.pi / Double(length)
            let stepR = cos(angle)
            let stepI = sin(angle)
            let half = length / 2

            var base = 0
            while base < fftSize {
                var wr = 1.0
                var wi = 0.0
                for k in 0..<half {
                    let even = base + k
                    let odd = even + half
                    let vr = real[odd] * wr - imag[odd] * wi
                    let vi = real[odd] * wi + imag[odd] * wr
                    let ur = real[even]
                    let ui = imag[even]
                    real[even] = ur + vr
                    imag[even] = ui + vi
                    real[odd] = ur - vr
                    imag[odd] = ui - vi

                    let nextWr = wr * stepR - wi * stepI
                    wi = wr * stepI + wi * stepR
                    wr = nextWr
                }
                base += length
            }
            length <<= 1
        }

        var magnitudes = Array(repeating: Double(0), count: fftSize / 2 + 1)
        let normalization = 2.0 / Double(fftSize)
        for bin in 1...fftSize / 2 {
            magnitudes[bin] = hypot(real[bin], imag[bin]) * normalization
        }

        var bands = Array(repeating: Float(0), count: 16)
        for band in 0..<16 {
            let (lo, hi) = bandRanges[band]
            var energy = 0.0
            var count = 0
            if lo <= hi {
                for bin in lo...hi {
                    let m = magnitudes[bin]
                    energy += m * m
                    count += 1
                }
            }
            let rmsMagnitude = count > 0 ? sqrt(energy / Double(count)) : 0.0

            // Gain is intentionally user-tunable. sqrt compression makes quiet
            // frequency bands visible without flattening strong bass transients.
            let amplified = max(0.0, rmsMagnitude * Double(gain))
            let compressed = sqrt(amplified)
            bands[band] = Float(min(compressed, 1.0))
        }
        return bands
    }

    private func logLevelsIfNeeded(prefix: String) {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now &- lastLogNs >= 500_000_000 else { return }
        lastLogNs = now

        if mode == .fft {
            let lPeak = smoothLeftBands.max() ?? 0
            let rPeak = smoothRightBands.max() ?? 0
            print(String(
                format: "[audio-bridge] %@ Lpeak=%.3f Rpeak=%.3f bands L[0,4,8,12,15]=%.2f %.2f %.2f %.2f %.2f",
                prefix,
                lPeak,
                rPeak,
                smoothLeftBands[0],
                smoothLeftBands[4],
                smoothLeftBands[8],
                smoothLeftBands[12],
                smoothLeftBands[15]
            ))
        } else {
            print(String(format: "[audio-bridge] %@ L=%.3f R=%.3f", prefix, smoothLeftBands[0], smoothRightBands[0]))
        }
        fflush(stdout)
    }

    private func writeSpectrum(left: [Float], right: [Float]) throws {
        guard left.count == 16, right.count == 16 else { return }
        let values = left + right
        let text = values.map { String(format: "%.6f", $0) }.joined(separator: " ") + "\n"
        try Data(text.utf8).write(to: outputURL, options: .atomic)
    }

    private func pcmChannels(from sampleBuffer: CMSampleBuffer) -> ([Float], [Float])? {
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
                guard let left = samples(buffer: buffers[0]) else { return nil }
                let right: [Float]
                if buffers.count >= 2, let r = samples(buffer: buffers[1]) {
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

            let frameCount = floatCount / channelCount
            var left = [Float]()
            var right = [Float]()
            left.reserveCapacity(frameCount)
            right.reserveCapacity(frameCount)

            var i = 0
            while i + channelCount <= floatCount {
                left.append(ptr[i])
                right.append(ptr[i + min(1, channelCount - 1)])
                i += channelCount
            }
            return (left, right)
        }
    }

    private func samples(buffer: AudioBuffer) -> [Float]? {
        guard let data = buffer.mData else { return nil }
        let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
        guard count > 0 else { return nil }
        let ptr = data.assumingMemoryBound(to: Float.self)
        return Array(UnsafeBufferPointer(start: ptr, count: count))
    }

    private func rms(samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum = 0.0
        for x in samples {
            let d = Double(x)
            sum += d * d
        }
        return Float(sqrt(sum / Double(samples.count)))
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
