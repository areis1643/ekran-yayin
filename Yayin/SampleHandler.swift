import CoreImage
import ImageIO
import ReplayKit

/// Yayın eklentisi: iPhone ekranını küçültüp JPEG'e çevirir, son kareyi HTTP'den verir.
/// iPad 2 (iOS 9) WebRTC ve fMP4 HLS bilmediği için düz JPEG seçildi.
class SampleHandler: RPBroadcastSampleHandler {
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let encodeQueue = DispatchQueue(label: "ekran.encode")
    private let lock = NSLock()
    private var busy = false
    private var lastTime: CFAbsoluteTime = 0
    private var server: HTTPServer?

    // Eklentinin bellek sınırı ~50 MB; kare boyutu ve hızı bunun içinde kalacak şekilde.
    private let minInterval = 1.0 / 12.0
    private let maxSide: CGFloat = 1024
    private let quality: CGFloat = 0.6

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        NSLog("EkranYayin yayin basladi")
        let s = HTTPServer(port: 8888)
        s.start()
        server = s
    }

    override func broadcastFinished() {
        server?.stop()
        server = nil
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        if busy || now - lastTime < minInterval {
            lock.unlock()
            return
        }
        busy = true
        lastTime = now
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
}

/// Son kodlanan kare; HTTP tarafı buradan okur.
final class FrameStore {
    static let shared = FrameStore()
    private let lock = NSLock()
    private var jpeg: Data?
    private var seq = 0

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
}
