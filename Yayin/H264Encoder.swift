import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
import os

private let log = Logger(subsystem: "tr.niladsp.ekran", category: "h264")

/// ReplayKit karelerini H.264'e çevirir; SPS/PPS'i 'V', AVCC kareyi 'F' olarak verir.
final class H264Encoder {
    private let queue = DispatchQueue(label: "ekran.h264")
    private let onData: (UInt8, Data) -> Void

    private var session: VTCompressionSession?
    private var transferSession: VTPixelTransferSession?
    private var targetWidth = 0
    private var targetHeight = 960
    private var forceKeyframe = true
    private var lastEncodeTime: CFAbsoluteTime = 0
    private var isStopped = false

    init(onData: @escaping (UInt8, Data) -> Void) {
        self.onData = onData
    }

    func requestKeyframe() {
        queue.async { [weak self] in
            self?.forceKeyframe = true
        }
    }

    /// Her kare çağrılabilir; en çok 30 kare/sn kodlanır.
    func encode(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        queue.async { [weak self] in
            self?.encodeLocked(pixelBuffer, presentationTime: presentationTime)
        }
    }

    func stop() {
        queue.sync {
            isStopped = true
            invalidateSession()
        }
    }

    private func encodeLocked(_ source: CVPixelBuffer, presentationTime: CMTime) {
        guard !isStopped else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastEncodeTime >= 1.0 / 31.0 else { return } // 60 Hz kaynakta 30 kare/sn
        lastEncodeTime = now

        if session == nil {
            setupSession(source: source)
        }
        guard let session else { return }
        guard let pool = VTCompressionSessionGetPixelBufferPool(session) else {
            log.error("pixel buffer havuzu yok")
            invalidateSession()
            return
        }

        var destination: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &destination) == kCVReturnSuccess,
              let destination else {
            log.error("hedef pixel buffer alinamadi")
            return
        }

        if transferSession == nil {
            setupTransferSession()
        }
        guard let transferSession else { return }

        let scaleStatus = VTPixelTransferSessionTransferImage(transferSession, from: source, to: destination)
        guard scaleStatus == noErr else {
            log.error("olcekleme hatasi: \(Int(scaleStatus))")
            invalidateSession()
            return
        }

        var properties: CFDictionary?
        if forceKeyframe {
            properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
        }
        forceKeyframe = false

        let timestamp = presentationTime.isValid ? presentationTime : CMClockGetTime(CMClockGetHostTimeClock())
        let encodeStatus = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: destination,
            presentationTimeStamp: timestamp,
            duration: .invalid,
            frameProperties: properties,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
        if encodeStatus != noErr {
            log.error("kodlama hatasi: \(Int(encodeStatus))")
            invalidateSession()
        }
    }

    private func setupSession(source: CVPixelBuffer) {
        let sourceWidth = CVPixelBufferGetWidth(source)
        let sourceHeight = CVPixelBufferGetHeight(source)
        guard sourceWidth > 0, sourceHeight > 0 else { return }

        targetHeight = 960
        var width = Int((Double(sourceWidth) * Double(targetHeight) / Double(sourceHeight)).rounded())
        width = max(2, width + (width % 2))
        targetWidth = width

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: targetWidth,
            kCVPixelBufferHeightKey as String: targetHeight,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ]

        var newSession: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(targetWidth),
            height: Int32(targetHeight),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: h264OutputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &newSession
        )
        guard status == noErr, let newSession else {
            log.error("H.264 oturumu kurulamadi: \(Int(status))")
            return
        }

        check(VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue), "realtime")
        check(VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Main_AutoLevel), "profil")
        check(VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse), "reordering")
        check(VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: 30)), "fps")
        check(VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: 2_500_000)), "bitrate")
        check(VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: NSNumber(value: 2)), "anahtar aralik")
        _ = VTCompressionSessionPrepareToEncodeFrames(newSession)

        session = newSession
        transferSession = nil
        log.notice("H.264 \(self.targetWidth)x\(self.targetHeight)")
    }

    private func setupTransferSession() {
        var newSession: VTPixelTransferSession?
        let status = VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &newSession)
        guard status == noErr, let newSession else {
            log.error("olcekleme oturumu kurulamadi: \(Int(status))")
            return
        }
        check(VTSessionSetProperty(newSession, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Letterbox), "scaling mode")
        transferSession = newSession
    }

    private func check(_ status: OSStatus, _ name: String) {
        if status != noErr {
            log.error("\(name, privacy: .public) ayarlanamadi: \(Int(status))")
        }
    }

    private func invalidateSession() {
        if let session {
            VTCompressionSessionInvalidate(session)
        }
        session = nil
        transferSession = nil
        targetWidth = 0
        targetHeight = 960
        forceKeyframe = true
    }

    fileprivate func handleOutput(status: OSStatus, sampleBuffer: CMSampleBuffer?) {
        queue.async { [weak self] in
            self?.processOutput(status: status, sampleBuffer: sampleBuffer)
        }
    }

    private func processOutput(status: OSStatus, sampleBuffer: CMSampleBuffer?) {
        guard status == noErr else {
            log.error("kodlayici cikis hatasi: \(Int(status))")
            invalidateSession()
            return
        }
        guard let sampleBuffer, CMSampleBufferDataIsReady(sampleBuffer) else { return }

        let keyframe = isKeyframe(sampleBuffer)
        if keyframe, let format = CMSampleBufferGetFormatDescription(sampleBuffer),
           let sets = parameterSets(from: format) {
            onData(0x56, sets) // 'V'
        }

        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0 else { return }

        var data = Data(count: length)
        let copyStatus = data.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return OSStatus(-1) }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
        }
        guard copyStatus == noErr else {
            log.error("kare kopyalanamadi: \(Int(copyStatus))")
            return
        }

        var payload = Data(capacity: length + 1)
        payload.append(keyframe ? 1 : 0)
        payload.append(data)
        onData(0x46, payload) // 'F'
    }

    private func isKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[String: Any]],
              let first = attachments.first else {
            return true
        }
        return (first[kCMSampleAttachmentKey_NotSync as String] as? Bool) != true
    }

    private func parameterSets(from format: CMFormatDescription) -> Data? {
        var count = 0
        let countStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format,
            parameterSetIndex: 0,
            parameterSetPointerOut: nil,
            parameterSetSizeOut: nil,
            parameterSetCountOut: &count,
            nalUnitHeaderLengthOut: nil
        )
        guard countStatus == noErr, count > 0 else { return nil }

        var data = Data()
        for index in 0..<min(count, 2) {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format,
                parameterSetIndex: index,
                parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil
            )
            guard status == noErr, let pointer, size > 0, size <= Int(UInt16.max) else { continue }
            data.append(UInt8((size >> 8) & 0xFF))
            data.append(UInt8(size & 0xFF))
            data.append(contentsOf: UnsafeBufferPointer(start: pointer, count: size))
        }
        return data.isEmpty ? nil : data
    }
}

private func h264OutputCallback(
    _ refcon: UnsafeMutableRawPointer?,
    _ sourceFrameRefcon: UnsafeMutableRawPointer?,
    _ status: OSStatus,
    _ infoFlags: VTEncodeInfoFlags,
    _ sampleBuffer: CMSampleBuffer?
) {
    guard let refcon else { return }
    let encoder = Unmanaged<H264Encoder>.fromOpaque(refcon).takeUnretainedValue()
    encoder.handleOutput(status: status, sampleBuffer: sampleBuffer)
}
