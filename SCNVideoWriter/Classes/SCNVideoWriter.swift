//
//  SCNVideoWriter.swift
//  Pods-SCNVideoWriter_Example
//
//  Created by Tomoya Hirano on 2017/07/31.
//

import UIKit
import SceneKit
import AVFoundation

public class SCNVideoWriter {
  enum State {
    case idle
    case progress
    case finished
  }
  
  private let writer: AVAssetWriter
  private let input: AVAssetWriterInput
  private let pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor
  private let renderer: SCNRenderer
  private var frameInfo: FrameInfo
  private let options: Options
  
  private let frameQueue = DispatchQueue(label: "com.noppelabs.SCNVideoWriter.frameQueue")
  private let renderQueue = DispatchQueue(label: "com.noppelabs.SCNVideoWriter.RenderQueue")
  private let renderSemaphore = DispatchSemaphore(value: 3)
  private var displayLink: CADisplayLink? = nil
  private var currentTime: CMTime = kCMTimeZero
  
  private var finishedCompletionHandler: ((_ url: URL) -> Void)? = nil
  
  public init?(scene: SCNScene, options: Options = .default) throws {
    self.options = options
    self.frameInfo = FrameInfo(with: options.fps)
    self.renderer = SCNRenderer(device: nil, options: nil)
    renderer.scene = scene
    
    self.writer = try AVAssetWriter(outputURL: options.outputUrl,
                                    fileType: options.fileType)
    self.input = AVAssetWriterInput(mediaType: AVMediaTypeVideo,
                                    outputSettings: options.assetWriterInputSettings)
    
    self.pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
                                                                   sourcePixelBufferAttributes: options.sourcePixelBufferAttributes)
    prepare(with: options)
  }
  
  private func prepare(with options: Options) {
    if options.deleteFileIfExists {
      FileController.delete(file: options.outputUrl)
    }
    renderer.autoenablesDefaultLighting = true
    writer.add(input)
  }
  
  public func startWriting() {
    renderQueue.async { [weak self] in
      self?.renderSemaphore.wait()
      self?.startDisplayLink()
      self?.startInputPipeline()
    }
  }
  
  public func finisheWriting(completionHandler: (@escaping (_ url: URL) -> Void)) {
    let outputUrl = options.outputUrl
    input.markAsFinished()
    writer.finishWriting(completionHandler: { [weak self] in
      completionHandler(outputUrl)
      self?.stopDisplayLink()
      self?.renderSemaphore.signal()
    })
  }
  
  private func startDisplayLink() {
    displayLink = CADisplayLink(target: self, selector: #selector(updateDisplayLink))
    displayLink?.add(to: .main, forMode: .commonModes)
  }
  
  @objc private func updateDisplayLink() {
    guard let link = displayLink else { return }
    currentTime = CMTimeMake(Int64(link.duration) * 600, 600)
  }
  
  private func startInputPipeline() {
    writer.startWriting()
    writer.startSession(atSourceTime: kCMTimeZero)
    input.requestMediaDataWhenReady(on: frameQueue) { [weak self] in
      guard let input = self?.input, input.isReadyForMoreMediaData else { return }
      guard let pool = self?.pixelBufferAdaptor.pixelBufferPool else { return }
      guard let size = self?.options.videoSize else { return }
      self?.renderSnapshot(with: pool, video: size)
    }
  }
  
  private func renderSnapshot(with pool: CVPixelBufferPool, video size: CGSize) {
    // TODO: presentation timeをちゃんとした値にする
    
    let image = renderer.snapshot(atTime: displayLink!.duration * 1000,
                                  with: size,
                                  antialiasingMode: SCNAntialiasingMode.multisampling4X)
    let pixelBuffer = PixelBufferFactory.make(withSize: size, fromImage: image, usingBufferPool: pool)
    pixelBufferAdaptor.append(pixelBuffer, withPresentationTime: CMTimeMake(Int64(displayLink!.duration * 1000.0) * 600, 600))
    print(frameInfo.snapshotTime, frameInfo.presentationTime, displayLink?.timestamp, displayLink?.targetTimestamp, displayLink?.duration)
    frameInfo.incrementFrame()
    
//    let image = renderer.snapshot(atTime: frameInfo.snapshotTime,
//                                  with: size,
//                                  antialiasingMode: SCNAntialiasingMode.multisampling4X)
//    let pixelBuffer = PixelBufferFactory.make(withSize: size, fromImage: image, usingBufferPool: pool)
//    pixelBufferAdaptor.append(pixelBuffer, withPresentationTime: frameInfo.presentationTime)
//    frameInfo.incrementFrame()
//    print(frameInfo.snapshotTime, frameInfo.presentationTime, displayLink?.timestamp, displayLink?.targetTimestamp, displayLink?.duration)
  }
  
  private func stopDisplayLink() {
    displayLink?.invalidate()
    displayLink = nil
  }
}

extension SCNVideoWriter {
  struct FrameInfo {
    init(with fps: Int = 60) {
      self.fps = fps
    }
    
    private let timescale: Float = 600
    private var frameNumber: Int = 0
    private var fps: Int
    
    private var intervalDuration: CFTimeInterval {
      return CFTimeInterval(1.0 / Double(fps))
    }
    
    private var frameDuration: CMTime {
      let kTimescale: Int32 = Int32(timescale)
      return CMTimeMake(Int64( floor(timescale / Float(fps)) ), kTimescale)
    }
    
    var snapshotTime: CFTimeInterval {
      return CFTimeInterval(intervalDuration * CFTimeInterval(frameNumber))
    }
    
    var presentationTime: CMTime {
      return CMTimeMultiply(frameDuration, Int32(frameNumber))
    }
    
    mutating func incrementFrame() {
      frameNumber += 1
    }
  }
  
  public struct Options {
    public var videoSize: CGSize
    public var fps: Int
    public var outputUrl: URL
    public var fileType: String
    public var codec: String
    public var deleteFileIfExists: Bool
    
    public static var `default`: Options {
      return Options(videoSize: CGSize(width: 640, height: 640),
                     fps: 60,
                     outputUrl: URL(fileURLWithPath: NSTemporaryDirectory() + "output.mp4"),
                     fileType: AVFileTypeAppleM4V,
                     codec: AVVideoCodecH264,
                     deleteFileIfExists: true)
    }
    
    var assetWriterInputSettings: [String : Any] {
      return [
        AVVideoCodecKey: codec,
        AVVideoWidthKey: videoSize.width,
        AVVideoHeightKey: videoSize.height
      ]
    }
    var sourcePixelBufferAttributes: [String : Any] {
      return [
        kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: kCVPixelFormatType_32ARGB),
        kCVPixelBufferWidthKey as String: videoSize.width,
        kCVPixelBufferHeightKey as String: videoSize.height
      ]
    }
  }
}
