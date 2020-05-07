//
//    MIT License
//
//    Copyright (c) 2020 John Boiles
//    Copyright (c) 2020 Ryohei Ikegami
//    Copyright (c) 2020 Philipp Matthes
//
//    Permission is hereby granted, free of charge, to any person obtaining a copy
//    of this software and associated documentation files (the "Software"), to deal
//    in the Software without restriction, including without limitation the rights
//    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//    copies of the Software, and to permit persons to whom the Software is
//    furnished to do so, subject to the following conditions:
//
//    The above copyright notice and this permission notice shall be included in all
//    copies or substantial portions of the Software.
//
//    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//    SOFTWARE.

import Foundation
import AVFoundation
import AppKit
import Vision
import CoreText
import Accelerate
import VideoToolbox


class Stream: NSObject, Object {
    var objectID: CMIOObjectID = 0
    let name = "Neural Greenscreen"
    let width = 1280
    let height = 720
    let webcamFrameRate = 30
    
    private var mask: CIImage?
    private var sequenceNumber: UInt64 = 0
    private var queueAlteredProc: CMIODeviceStreamQueueAlteredProc?
    private var queueAlteredRefCon: UnsafeMutableRawPointer?
    
    private var backgroundImage: CIImage?
        
    private lazy var model = DeepLabV3()
    private lazy var mtlDevice = MTLCreateSystemDefaultDevice()!
    private lazy var capture = VideoCapture()

    private lazy var formatDescription: CMVideoFormatDescription? = {
        var formatDescription: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCVPixelFormatType_32ARGB,
            width: Int32(width),
            height: Int32(height),
            extensions: nil,
            formatDescriptionOut: &formatDescription
        ) == noErr else {return nil}
        return formatDescription
    }()

    private lazy var clock: CFTypeRef? = {
        var clock: Unmanaged<CFTypeRef>? = nil
        guard CMIOStreamClockCreate(
            kCFAllocatorDefault,
            "Neural Greenscreen clock" as CFString,
            Unmanaged.passUnretained(self).toOpaque(),
            CMTimeMake(value: 1, timescale: 10),
            100,
            10,
            &clock
        ) == noErr else {return nil}
        return clock?.takeUnretainedValue()
    }()

    private lazy var queue: CMSimpleQueue? = {
        var queue: CMSimpleQueue?
        guard CMSimpleQueueCreate(
            allocator: kCFAllocatorDefault,
            capacity: 30,
            queueOut: &queue
        ) == noErr else {return nil}
        return queue
    }()

    lazy var properties: [Int : Property] = [
        kCMIOObjectPropertyName: Property(name),
        kCMIOStreamPropertyFormatDescription: Property(formatDescription!),
        kCMIOStreamPropertyFormatDescriptions: Property([formatDescription!] as CFArray),
        kCMIOStreamPropertyDirection: Property(UInt32(0)),
        kCMIOStreamPropertyFrameRate: Property(Float64(webcamFrameRate)),
        kCMIOStreamPropertyFrameRates: Property(Float64(webcamFrameRate)),
        kCMIOStreamPropertyMinimumFrameRate: Property(Float64(0)),
        kCMIOStreamPropertyFrameRateRanges: Property(AudioValueRange(
            mMinimum: Float64(0), mMaximum: Float64(webcamFrameRate)
        )),
        kCMIOStreamPropertyClock: Property(CFTypeRefWrapper(ref: clock!)),
    ]

    func start() {
        capture.delegate = self
        
        URLSession.shared.dataTask(
            with: URL(string: "https://localhost:9000/background")!,
            completionHandler: {
                data, response, error in
                guard
                    let data = data,
                    let backgroundImage = CIImage(data: data),
                    self.backgroundImage != backgroundImage
                else {return}
                self.backgroundImage = backgroundImage
            }
        ).resume()
        
        capture.setUp()
        capture.start()
    }

    func stop() {
        capture.stop()
    }

    func copyBufferQueue(
        queueAlteredProc: CMIODeviceStreamQueueAlteredProc?,
        queueAlteredRefCon: UnsafeMutableRawPointer?
    ) -> CMSimpleQueue? {
        self.queueAlteredProc = queueAlteredProc
        self.queueAlteredRefCon = queueAlteredRefCon
        return self.queue
    }
}

extension Stream: VideoCaptureDelegate {
    func dispatch(pixelBuffer: CVPixelBuffer, toStreamWithTiming timing: CMSampleTimingInfo) {
        guard
            let queue = queue,
            CMSimpleQueueGetCount(queue) < CMSimpleQueueGetCapacity(queue)
        else {return}
        
        let currentTimeNsec = mach_absolute_time()
        var mutableTiming = timing
        
        guard CMIOStreamClockPostTimingEvent(
            timing.presentationTimeStamp,
            currentTimeNsec,
            true,
            self.clock
        ) == noErr else {return}

        var formatDescription: CMFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        ) == noErr else {return}

        var sampleBufferUnmanaged: Unmanaged<CMSampleBuffer>? = nil
        guard CMIOSampleBufferCreateForImageBuffer(
            kCFAllocatorDefault,
            pixelBuffer,
            formatDescription,
            &mutableTiming,
            self.sequenceNumber,
            UInt32(kCMIOSampleBufferNoDiscontinuities),
            &sampleBufferUnmanaged
        ) == noErr else {return}

        CMSimpleQueueEnqueue(queue, element: sampleBufferUnmanaged!.toOpaque())
        self.queueAlteredProc?(
            self.objectID,
            sampleBufferUnmanaged!.toOpaque(),
            self.queueAlteredRefCon
        )

        self.sequenceNumber += 1
    }
    
    func videoCapture(
        _ capture: VideoCapture,
        didCapture pixelBuffer: CVPixelBuffer?,
        with sampleTimingInfo: CMSampleTimingInfo
    ) {
        guard
            let pixelBuffer = pixelBuffer
        else {return}
        
        let ciImage = CIImage(cvImageBuffer: pixelBuffer)
        
        // Render mask into the image and dispatch the masked image
        if let mask = mask {
            var parameters = [String: Any]()
            parameters["inputMaskImage"] = mask
            if let backgroundImage = backgroundImage {
                parameters["inputBackgroundImage"] = backgroundImage
            }
            let maskedImage = ciImage.applyingFilter(
                "CIBlendWithMask",
                parameters: parameters
            )
            let context = CIContext(mtlDevice: mtlDevice)
            context.render(maskedImage, to: pixelBuffer)
        }
        self.dispatch(pixelBuffer: pixelBuffer, toStreamWithTiming: sampleTimingInfo)
        
        // Predict the mask once a second
        if sequenceNumber % UInt64(webcamFrameRate) == 0 {
            self.observeAsynchronously(onCIImage: ciImage)
        }
    }
    
    func byteArrayToCGImage(
        raw: UnsafePointer<UInt8>, w: Int,h: Int
    ) -> CGImage? {

        let bytesPerPixel: Int = 1
        let bitsPerComponent: Int = 8
        let bitsPerPixel = bytesPerPixel * bitsPerComponent;
        let bytesPerRow: Int = w * bytesPerPixel;
        let cfData = CFDataCreate(nil, raw, w * h * bytesPerPixel)
        let cgDataProvider = CGDataProvider.init(data: cfData!)!

        let deviceColorSpace = CGColorSpaceCreateDeviceGray()

        return CGImage(
            width: w,
            height: h,
            bitsPerComponent: bitsPerComponent,
            bitsPerPixel: bitsPerPixel,
            bytesPerRow: bytesPerRow,
            space: deviceColorSpace,
            bitmapInfo: [],
            provider: cgDataProvider,
            decode: nil,
            shouldInterpolate: true,
            intent: CGColorRenderingIntent.defaultIntent
        )
    }
    
    func observeAsynchronously(onCIImage ciImage: CIImage) {
        DispatchQueue(label: "Neural Greenscreen Prediction Queue", qos: .background).async {
            // Resize the passed image to a fitting 513x513 cvpixelbuffer
            var pixelBuffer : CVPixelBuffer? = nil
            guard CVPixelBufferCreate(
                kCFAllocatorDefault,
                513,
                513,
                kCVPixelFormatType_32BGRA,
                nil,
                &pixelBuffer
            ) == noErr else {return}
            let resizedImage = ciImage
                .transformed(by: .init(scaleX: 513 / 1280, y: 513 / 720))
                .cropped(to: .init(x: 0, y: 0, width: 513, height: 513))
            let context = CIContext(mtlDevice: self.mtlDevice)
            context.render(resizedImage, to: pixelBuffer!)
        
            guard let output = try? self.model.prediction(image: pixelBuffer!) else {return}
            
            let height = output.semanticPredictions.shape[0].intValue
            let width = output.semanticPredictions.shape[1].intValue
            
            let intPointer = output.semanticPredictions
                .dataPointer
                .bindMemory(to: Int32.self, capacity: output.semanticPredictions.count)
            let maskArray = Array(UnsafeBufferPointer(
                start: intPointer,
                count: output.semanticPredictions.count
            )).map {UInt8($0 == 15 ? 255 : 0)}
            
            let maskCGImage = self.byteArrayToCGImage(raw: maskArray, w: width, h: height)!
            let maskCIImage = CIImage(cgImage: maskCGImage)
            
            // Scale the image up to the desired size
            let maskCIImageScaled = maskCIImage
                .applyingFilter("CILanczosScaleTransform", parameters: [
                    "inputImage": maskCIImage,
                    "inputScale": Double(720) / Double(513),
                    "inputAspectRatio": Double(1280) / Double(720)
                ])
            let maskCIImageBlurred = maskCIImageScaled
                .applyingFilter("CIGaussianBlur", parameters: [
                    "inputImage": maskCIImageScaled,
                    "inputRadius": Double(4)
                ])
            
            self.mask = maskCIImageBlurred
        }
    }
}
