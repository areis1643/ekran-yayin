import AudioToolbox
import AVFoundation
import CoreImage
import ImageIO
import ReplayKit
import os

private let alog = Logger(subsystem: "tr.niladsp.ekran", category: "ses")

/// Yayın eklentisi: iPhone ekranını H.264 + PCM olarak TCP'den, JPEG'i HTTP'den verir.
class SampleHandler: RPBroadcastSampleHandler {
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let encodeQueue = DispatchQueue(label: "ekran.encode")
    private let lock = NSLock()
    private var busy = false
    private var audioErrorCount = 0
    private var audioSent = 0
    private var lastJpegTime: CFAbsoluteTime = 0
    private var httpServer: HTTPServer?
    private var streamServer: StreamServer?
    private var h264Encoder: H264Encoder?

    // Eklentinin bellek sınırı ~50 MB; JPEG yalnız istek varken ve sınırlı hızda üretilir.
    private let minInterval = 1.0 / 20.0
    private let maxSide: CGFloat = 800
    private let quality: CGFloat = 0.5

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        NSLog("EkranYayin yayin basladi")
        let stream = StreamServer(port: 8889)
        let encoder = H264Encoder { [weak stream] type, payload in
            stream?.send(type: type, payload: payload)
        }
        stream.onNewClient = { [weak encoder] in
            encoder?.requestKeyframe()
            NSLog("EkranYayin yeni istemci; anahtar kare istendi")
        }
        stream.start()

        let http = HTTPServer(port: 8888)
        http.start()

        streamServer = stream
        h264Encoder = encoder
        httpServer = http
    }

    // Arama gibi kesintilerde sistem çağırır; sunucular açık bırakılır.
    override func broadcastPaused() {
        NSLog("EkranYayin yayin duraklatildi")
    }

    override func broadcastResumed() {
        NSLog("EkranYayin yayin surduruldu")
        h264Encoder?.requestKeyframe()
    }

    override func broadcastFinished() {
        h264Encoder?.stop()
        streamServer?.stop()
        httpServer?.stop()
        h264Encoder = nil
        streamServer = nil
        httpServer = nil
        NSLog("EkranYayin yayin bitti")
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        switch sampleBufferType {
        case .video:
            processVideo(sampleBuffer)
        case .audioApp:
            processAudio(sampleBuffer)
        default:
            break // .audioMic yok sayılır
        }
    }

    private func processVideo(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        h264Encoder?.encode(pixelBuffer, presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))

        // JPEG yolu yalnız son 3 sn içinde HTTP isteği geldiyse çalışır.
        guard FrameStore.shared.isRequestedRecently else { return }

        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        if busy || now - lastJpegTime < minInterval {
            lock.unlock()
            return
        }
        busy = true
        lastJpegTime = now
        lock.unlock()

        var orientation = CGImagePropertyOrientation.up
        if let n = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber,
           let o = CGImagePropertyOrientation(rawValue: n.uint32Value) {
            orientation = o
        }

        encodeQueue.async { [weak self] in
            guard let self else { return }
            autoreleasepool {
                var image = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)
                let extent = image.extent
                let scale = min(1, self.maxSide / max(extent.width, extent.height))
                if scale < 1 {
                    image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                }
                let qualityKey = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
                let options: [CIImageRepresentationOption: Any] = [qualityKey: self.quality]
                if let jpeg = self.ciContext.jpegRepresentation(of: image, colorSpace: self.colorSpace, options: options) {
                    FrameStore.shared.put(jpeg)
                    if FrameStore.shared.get().1 % 60 == 1 {
                        NSLog("EkranYayin kare %d bayt %d", FrameStore.shared.get().1, jpeg.count)
                    }
                } else {
                    NSLog("EkranYayin JPEG uretilemedi")
                }
            }
            self.lock.lock()
            self.busy = false
            self.lock.unlock()
        }
    }

    private func processAudio(_ sampleBuffer: CMSampleBuffer) {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else { return }
        let asbd = asbdPointer.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM else { return }

        let sourceChannels = Int(asbd.mChannelsPerFrame)
        let channels = min(sourceChannels, 2)
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard channels > 0, frames > 0 else { return }

        // Gereken liste boyutu önce sorulur; sabit boyut verilince çağrı her pakette
        // hata döndürüyordu (sahada görüldü).
        var neededSize = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: &neededSize, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        guard neededSize > 0 else {
            alog.error("ses liste boyutu alinamadi")
            return
        }
        let rawList = UnsafeMutableRawPointer.allocate(byteCount: neededSize, alignment: 16)
        defer { rawList.deallocate() }
        let listPointer = rawList.bindMemory(to: AudioBufferList.self, capacity: 1)
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: listPointer,
            bufferListSize: neededSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else {
            if audioErrorCount % 200 == 0 {
                alog.error("ses buffer listesi alinamadi: \(Int(status), privacy: .public) boyut \(neededSize, privacy: .public)")
            }
            audioErrorCount += 1
            return
        }
        let audioBufferList = UnsafeMutableAudioBufferListPointer(listPointer)

        let formatFlags = asbd.mFormatFlags
        let isFloat = (formatFlags & kAudioFormatFlagIsFloat) != 0
        let isBigEndian = (formatFlags & kAudioFormatFlagIsBigEndian) != 0
        let isNonInterleaved = (formatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let isSigned = (formatFlags & kAudioFormatFlagIsSignedInteger) != 0
        let bits = Int(asbd.mBitsPerChannel)
        if isFloat {
            guard bits == 32 else { return }
        } else {
            guard bits == 8 || bits == 16 || bits == 24 || bits == 32 else { return }
        }
        let sampleBytes = max(1, (bits + 7) / 8)
        let frameStride = Int(asbd.mBytesPerFrame) > 0 ? Int(asbd.mBytesPerFrame) : sampleBytes * sourceChannels
        let channelStride = max(sampleBytes, frameStride / max(1, sourceChannels))

        var samples = [Int16]()
        samples.reserveCapacity(frames * channels)

        for frame in 0..<frames {
            for channel in 0..<channels {
                let bufferIndex = isNonInterleaved ? channel : 0
                guard bufferIndex < audioBufferList.count else { continue }
                let buffer = audioBufferList[bufferIndex]
                guard let base = buffer.mData else { continue }

                let offset: Int
                if isNonInterleaved {
                    let bufferStride = max(sampleBytes, Int(buffer.mDataByteSize) / max(1, frames))
                    offset = frame * bufferStride
                } else {
                    offset = frame * frameStride + channel * channelStride
                }
                guard offset + sampleBytes <= Int(buffer.mDataByteSize) else { continue }
                samples.append(readSample(base, offset: offset, bits: bits, isFloat: isFloat, isSigned: isSigned, bigEndian: isBigEndian))
            }
        }
        _ = blockBuffer

        guard !samples.isEmpty else { return }
        let sampleRate = UInt32(max(0, min(Double(UInt32.max), asbd.mSampleRate.rounded())))
        let pcm = samples.withUnsafeBufferPointer { Data(buffer: $0) }

        var payload = Data(capacity: pcm.count + 5)
        payload.append(UInt8((sampleRate >> 24) & 0xFF))
        payload.append(UInt8((sampleRate >> 16) & 0xFF))
        payload.append(UInt8((sampleRate >> 8) & 0xFF))
        payload.append(UInt8(sampleRate & 0xFF))
        payload.append(UInt8(channels))
        payload.append(pcm)
        audioSent += 1
        if audioSent % 500 == 1 {
            alog.notice("ses paketi \(self.audioSent, privacy: .public): \(sampleRate, privacy: .public) Hz \(channels, privacy: .public) kanal, bayrak \(formatFlags, privacy: .public), \(bits, privacy: .public) bit, \(frames, privacy: .public) kare")
        }
        streamServer?.send(type: 0x41, payload: payload)
    }

    /// ASBD'deki float/int örneği Int16 little-endian'a çevirir.
    private func readSample(
        _ base: UnsafeMutableRawPointer,
        offset: Int,
        bits: Int,
        isFloat: Bool,
        isSigned: Bool,
        bigEndian: Bool
    ) -> Int16 {
        let bytes = max(1, (bits + 7) / 8)
        let pointer = (base + offset).assumingMemoryBound(to: UInt8.self)
        var raw: UInt32 = 0
        for index in 0..<min(bytes, 4) {
            if bigEndian {
                raw = (raw << 8) | UInt32(pointer[index])
            } else {
                raw |= UInt32(pointer[index]) << (8 * index)
            }
        }

        if isFloat {
            guard bits == 32 else { return 0 }
            return pcm16(Double(Float(bitPattern: raw)))
        }
        guard bits >= 8, bits <= 32 else { return 0 }

        let mask: UInt32 = bits == 32 ? UInt32.max : (UInt32(1) << UInt32(bits)) - 1
        let value = raw & mask
        let half = Int64(1) << (bits - 1)
        let signedValue: Int64
        if isSigned && (value & (UInt32(1) << UInt32(bits - 1))) != 0 {
            signedValue = Int64(value) - (Int64(1) << bits)
        } else {
            signedValue = Int64(value)
        }

        let normalized: Double
        if isSigned {
            normalized = Double(signedValue) / Double(half)
        } else {
            normalized = (Double(signedValue) - Double(half)) / Double(half)
        }
        return pcm16(normalized)
    }

    private func pcm16(_ value: Double) -> Int16 {
        let clamped = max(-1.0, min(1.0, value))
        return Int16((clamped * 32767.0).rounded())
    }
}

/// Son kodlanan kare; HTTP tarafı buradan okur.
final class FrameStore {
    static let shared = FrameStore()
    private let lock = NSLock()
    private var jpeg: Data?
    private var seq = 0
    private var lastRequest: CFAbsoluteTime = 0

    func put(_ data: Data) {
        lock.lock()
        jpeg = data
        seq += 1
        lock.unlock()
    }

    func get() -> (Data?, Int) {
        lock.lock()
        defer { lock.unlock() }
        return (jpeg, seq)
    }

    func touch() {
        lock.lock()
        lastRequest = CFAbsoluteTimeGetCurrent()
        lock.unlock()
    }

    var isRequestedRecently: Bool {
        lock.lock()
        defer { lock.unlock() }
        return CFAbsoluteTimeGetCurrent() - lastRequest < 3.0
    }
}
