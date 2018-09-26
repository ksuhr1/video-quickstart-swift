//
//  ExampleScreenCapturer.swift
//  ScreenCapturerExample
//
//  Copyright © 2016-2017 Twilio, Inc. All rights reserved.
//

import MetalKit
import TwilioVideo
import WebKit

@available(iOS 10.0, *)
class ExampleScreenCapturer: NSObject, TVIVideoCapturer {

    public var isScreencast: Bool = true
    public var supportedFormats: [TVIVideoFormat]

    // Private variables
    weak var captureConsumer: TVIVideoCaptureConsumer?
    weak var view: UIView?
    var displayTimer: CADisplayLink?
    var willEnterForegroundObserver: NSObjectProtocol?
    var didEnterBackgroundObserver: NSObjectProtocol?

    // Constants
    let desiredFrameRate = 5
    let captureScaleFactor: CGFloat = 1.0

    enum ViewRenderingMode {
        // Generic, create and manage a CGContext to draw a UIView.
        case cgcontext
        // If the CALayer has CGImage contents, then snapshot it.
        case calayercontents
        // If the view is an MTKView, then attempt to download the texture from the drawable.
        case mtkview
        // Generic, use UIGraphicsImageContext to draw standard range contents in Device RGB.
        case uigraphicsimagecontext
        // Generic, use UIGraphicsImageRenderer to draw a UIView in sRGB.
        case uigraphicsimagerenderer
        // If the view is a WKWebView, use snapshotting APIs to draw the contents.
        case wkwebview
    }

    let renderingMode: ViewRenderingMode = .wkwebview;

    init(aView: UIView) {
        captureConsumer = nil
        view = aView

        /* 
         * Describe the supported format.
         * For this example we cheat and assume that we will be capturing the entire screen.
         */
        let screenSize = UIScreen.main.bounds.size
        let format = TVIVideoFormat()
        format.pixelFormat = TVIPixelFormat.format32BGRA
        format.frameRate = UInt(desiredFrameRate)
        format.dimensions = CMVideoDimensions(width: Int32(screenSize.width), height: Int32(screenSize.height))
        supportedFormats = [format]

        // We don't need to call startCapture, this method is invoked when a TVILocalVideoTrack is added with this capturer.
    }

    func startCapture(_ format: TVIVideoFormat, consumer: TVIVideoCaptureConsumer) {
        DispatchQueue.main.async {
            if (self.view == nil || self.view?.superview == nil) {
                print("Can't capture from a nil view, or one with no superview:", self.view as Any)
                consumer.captureDidStart(false)
                return
            }

            print("Start capturing. UIView.layer.contentsFormat was", self.view?.layer.contentsFormat as Any)

            self.startTimer()
            self.registerNotificationObservers()

            self.captureConsumer = consumer;
            consumer.captureDidStart(true)
        }
    }

    func stopCapture() {
        print("Stop capturing.")

        DispatchQueue.main.async {
            self.unregisterNotificationObservers()
            self.invalidateTimer()
        }
    }

    func startTimer() {
        invalidateTimer()

        // Use a CADisplayLink timer so that our drawing is synchronized to the display vsync.
        displayTimer = CADisplayLink(target: self, selector: #selector(ExampleScreenCapturer.captureView))

        displayTimer?.preferredFramesPerSecond = desiredFrameRate
        displayTimer?.add(to: RunLoop.main, forMode: RunLoopMode.commonModes)
        displayTimer?.isPaused = UIApplication.shared.applicationState == UIApplicationState.background
    }

    func invalidateTimer() {
        displayTimer?.invalidate()
        displayTimer = nil
    }

    func registerNotificationObservers() {
        let notificationCenter = NotificationCenter.default;

        willEnterForegroundObserver = notificationCenter.addObserver(forName: NSNotification.Name.UIApplicationWillEnterForeground,
                                                                     object: nil,
                                                                     queue: OperationQueue.main,
                                                                     using: { (Notification) in
                                                                        self.displayTimer?.isPaused = false;
        })

        didEnterBackgroundObserver = notificationCenter.addObserver(forName: NSNotification.Name.UIApplicationDidEnterBackground,
                                                                     object: nil,
                                                                     queue: OperationQueue.main,
                                                                     using: { (Notification) in
                                                                        self.displayTimer?.isPaused = true;
        })
    }

    func unregisterNotificationObservers() {
        let notificationCenter = NotificationCenter.default

        notificationCenter.removeObserver(willEnterForegroundObserver!)
        notificationCenter.removeObserver(didEnterBackgroundObserver!)

        willEnterForegroundObserver = nil
        didEnterBackgroundObserver = nil
    }

    func captureView( timer: CADisplayLink ) {

        // Ensure the view is alive for the duration of our capture to make Swift happy.
        guard let targetView = self.view else { return }
        // We cant capture a 0x0 image.
        let targetSize = targetView.bounds.size
        guard targetSize != CGSize.zero else {
            return
        }

        // This is our main drawing loop. Start by using the UIGraphics APIs to draw the UIView we want to capture.
        var contextImage: UIImage? = nil
        var pixelFormat: TVIPixelFormat = TVIPixelFormat.format32BGRA
        var orientation: TVIVideoOrientation = TVIVideoOrientation.up

        autoreleasepool {
            switch renderingMode {
            case .calayercontents:
                if let contents = targetView.layer.contents {
                    let contentsImage = contents as! CGImage
                    pixelFormat = contentsImage.bitmapInfo.rawValue == CGImageByteOrderInfo.orderDefault.rawValue
                        ? TVIPixelFormat.format32ARGB : TVIPixelFormat.format32BGRA
                    contextImage = UIImage(cgImage: contents as! CGImage)
                } else {
                    return
                }
            case .cgcontext:
                // According to Apple's docs UIGraphicsBeginImageContextWithOptions uses device RGB.
                //                let colorSpace = CGColorSpaceCreateDeviceRGB()
                guard let colorSpace = CGColorSpace.init(name: CGColorSpace.genericRGBLinear),
                    var context = CGContext(data: nil, width: Int(targetSize.width), height: Int(targetSize.height), bitsPerComponent: 8, bytesPerRow: Int(targetSize.width) * 4, space: colorSpace, bitmapInfo: (CGImageAlphaInfo.noneSkipFirst.rawValue | CGImageByteOrderInfo.order32Little.rawValue))
                    else {
                        return
                }

                // Prepare CGContext to be used with UIKit, matching the top to bottom y-axis coordinate system.
                //                context.scaleBy(x: -1, y: 1)
                //                pixelFormat = TVIPixelFormat.format32ARGB
                // Not quite... this is mirrored.
                orientation = TVIVideoOrientation.down
                UIGraphicsPushContext(context); defer { UIGraphicsPopContext() }

                targetView.drawHierarchy(in: targetView.bounds, afterScreenUpdates: true)
                guard let imageRef = context.makeImage()
                else { return }

                contextImage = UIImage(cgImage: imageRef)
            case .uigraphicsimagecontext:
                // Our classic implementation, using the now discouraged UIGraphics APIs.
                UIGraphicsBeginImageContextWithOptions((self.view?.bounds.size)!, true, captureScaleFactor)
                targetView.drawHierarchy(in: (self.view?.bounds)!, afterScreenUpdates: false)
                contextImage = UIGraphicsGetImageFromCurrentImageContext()
                UIGraphicsEndImageContext()
            case .uigraphicsimagerenderer:
                /*
                 * We will use UIGraphicsImageRenderer for more control over color management when rendering a UIView.
                 * On iOS 12, UIGraphicsBeginImageContextWithOptions performs an expensive color conversion on devices with
                 * wide gamut screens.
                 */
                if #available(iOS 12.0, *) {
                    let rendererFormat = UIGraphicsImageRendererFormat.init()
                    rendererFormat.opaque = true
                    rendererFormat.scale = captureScaleFactor
                    // WebRTC expects content to be rec.709, and does not properly handle video in other color spaces.
                    rendererFormat.preferredRange = UIGraphicsImageRendererFormat.Range.standard
                    let renderer = UIGraphicsImageRenderer.init(bounds: targetView.bounds, format: rendererFormat)

                    contextImage = renderer.image(actions: { (UIGraphicsImageRendererContext) in
                        // No special drawing to do, we just want an opaque image of the UIView contents.
                        targetView.drawHierarchy(in: targetView.bounds, afterScreenUpdates: false)
                    })
                }
            case .mtkview:
                // Unfortunately, this is not the correct place to access currentDrawable. A capturer would need to be
                // more integrated.
                let metalKitView = targetView as! MTKView
                if let drawable = metalKitView.currentDrawable {
                    captureFrom(drawable: drawable, timestamp: timer.timestamp)
                }
            case .wkwebview:
                if #available(iOS 11.0, *) {
                    let webView = targetView as! WKWebView
                    let configuration = WKSnapshotConfiguration()
                    // Configure a width appropriate for our scale factor.
                    configuration.snapshotWidth = NSNumber(value: Double(webView.bounds.width * captureScaleFactor))
                    webView.takeSnapshot(with:configuration, completionHandler: { (image, error) in
                        if let deliverableImage = image {
                            // TODO: Neither BGRA or ARGB are correct, is this ABGR?
                            self.deliverCapturedImage(image: deliverableImage,
                                                      format: TVIPixelFormat.format32BGRA,
                                                      orientation: orientation,
                                                      timestamp: timer.timestamp)
                        }
                    })
                }
            }
        }

        if let deliverableImage = contextImage {
            deliverCapturedImage(image: deliverableImage, format: pixelFormat, orientation: orientation, timestamp: timer.timestamp)
        }
    }

    func captureFrom(drawable: CAMetalDrawable, timestamp: CFTimeInterval) {
        let texture = drawable.texture

        // There are only so many pixel formats that we can handle right now.
        let pixelFormat = texture.pixelFormat
        switch pixelFormat {
        case .bgra8Unorm:
            // Create a CVPixelBuffer and copy the bytes into it.
            var buffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(nil, texture.width, texture.height, kCVPixelFormatType_32BGRA, nil, &buffer)

            if let pixelBuffer = buffer {
                // Copy the drawable into our buffer.
                CVPixelBufferLockBaseAddress(pixelBuffer, CVPixelBufferLockFlags(rawValue: 0))
                let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer)

                var region = MTLRegion.init()
                region.origin = MTLOrigin(x: 0, y: 0, z: 0)
                region.size = MTLSize(width: texture.width, height: texture.height, depth: texture.depth)

                texture.getBytes(baseAddress!,
                                 bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                 from: region, mipmapLevel: 0)

                CVPixelBufferUnlockBaseAddress(pixelBuffer, CVPixelBufferLockFlags(rawValue: 0))

                // Deliver a frame to the consumer.
                let frame = TVIVideoFrame(timeInterval: timestamp,
                                          buffer: pixelBuffer,
                                          orientation: TVIVideoOrientation.up)

                // The consumer retains the CVPixelBuffer and will own it as the buffer flows through the video pipeline.
                captureConsumer?.consumeCapturedFrame(frame!)
            } else {
                print("CVPixelBuffer creation failed with status: ", status, ".")
            }
        default:
            // Unsupported.
            print("Unsupported format :", pixelFormat, "")
            break
        }
    }

    func deliverCapturedImage(image: UIImage, format: TVIPixelFormat, orientation: TVIVideoOrientation, timestamp: CFTimeInterval) {
        /*
         * Make a copy of the UIImage's underlying data. We do this by getting the CGImage, and its CGDataProvider.
         * Note that this technique is inefficient because it causes an extra malloc / copy to occur for every frame.
         * For a more performant solution, provide a pool of buffers and use them to back a CGBitmapContext.
         */
        let image: CGImage? = image.cgImage
        let dataProvider: CGDataProvider? = image?.dataProvider
        let data: CFData? = dataProvider?.data
        let baseAddress = CFDataGetBytePtr(data!)

        /*
         * We own the copied CFData which will back the CVPixelBuffer, thus the data's lifetime is bound to the buffer.
         * We will use a CVPixelBufferReleaseBytesCallback callback in order to release the CFData when the buffer dies.
         */
        let unmanagedData = Unmanaged<CFData>.passRetained(data!)
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreateWithBytes(nil,
                                                  (image?.width)!,
                                                  (image?.height)!,
                                                  format.rawValue,
                                                  UnsafeMutableRawPointer( mutating: baseAddress!),
                                                  (image?.bytesPerRow)!,
                                                  { releaseContext, baseAddress in
                                                    let contextData = Unmanaged<CFData>.fromOpaque(releaseContext!)
                                                    contextData.release()
        },
                                                  unmanagedData.toOpaque(),
                                                  nil,
                                                  &pixelBuffer)

        if let buffer = pixelBuffer {
            // Deliver a frame to the consumer.
            let frame = TVIVideoFrame(timeInterval: timestamp,
                                      buffer: buffer,
                                      orientation: orientation)

            // The consumer retains the CVPixelBuffer and will own it as the buffer flows through the video pipeline.
            captureConsumer?.consumeCapturedFrame(frame!)
        } else {
            print("Capture failed with status code: \(status).")
        }
    }
}
