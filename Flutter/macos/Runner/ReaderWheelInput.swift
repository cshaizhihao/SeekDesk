import Cocoa
import FlutterMacOS

struct ReaderWheelSample {
  var timestamp: TimeInterval
  var precise: Bool
  var phase: NSEvent.Phase
  var momentumPhase: NSEvent.Phase
  var modifiers: NSEvent.ModifierFlags
  var locationInBacking: NSPoint
  var contentsScale: Double
  var scrollingDeltaX: Double
  var scrollingDeltaY: Double

  func packet(sequence: Int64, viewId: Int64) -> [String: Any]? {
    guard phase.isEmpty, momentumPhase.isEmpty, sequence > 0, viewId >= 0,
          timestamp.isFinite, timestamp >= 0,
          contentsScale.isFinite, contentsScale > 0,
          locationInBacking.x.isFinite, locationInBacking.y.isFinite,
          scrollingDeltaX.isFinite, scrollingDeltaY.isFinite else { return nil }
    let timestampMicros = timestamp * 1_000_000
    let pixelsPerLine = precise ? 1.0 : 40.0
    let scaledX = -scrollingDeltaX * pixelsPerLine * contentsScale
    let scaledY = -scrollingDeltaY * pixelsPerLine * contentsScale
    guard timestampMicros.isFinite, timestampMicros < Double(Int64.max),
          scaledX.isFinite, scaledY.isFinite else { return nil }
    let shift = modifiers.contains(.shift)
    return [
      "version": ReaderWheelInput.version,
      "sequence": sequence,
      "viewId": viewId,
      "timestampMicros": Int64(timestampMicros),
      "precise": precise,
      "phase": Int(phase.rawValue),
      "momentumPhase": Int(momentumPhase.rawValue),
      "modifiers": Int(modifiers.intersection(.deviceIndependentFlagsMask).rawValue),
      "x": Double(locationInBacking.x),
      "y": -Double(locationInBacking.y),
      "dx": shift ? scaledY : scaledX,
      "dy": shift ? scaledX : scaledY,
    ]
  }
}

final class ReaderWheelInput {
  static let channelName = "cc.seekdesk/native.wheel.v1"
  static let version = 1
  private(set) var isReady = false
  private(set) var sequence: Int64 = 0
  private var generation: UInt64 = 0

  func receive(_ message: Any?, reply: (Any?) -> Void) {
    guard let request = message as? [String: Any],
          request["type"] as? String == "ready",
          let version = request["version"] as? NSNumber,
          CFGetTypeID(version) != CFBooleanGetTypeID(),
          !["f", "d"].contains(String(cString: version.objCType)),
          version.int64Value == Int64(Self.version) else {
      reply(nil)
      return
    }
    let currentGeneration = generation
    reply(["version": Self.version])
    if generation == currentGeneration { isReady = true }
  }

  func reset() {
    isReady = false
    generation &+= 1
  }

  func packet(for sample: ReaderWheelSample, viewId: Int64) -> [String: Any]? {
    guard isReady, sequence < Int64.max,
          let packet = sample.packet(sequence: sequence + 1, viewId: viewId) else { return nil }
    sequence += 1
    return packet
  }
}

final class ReaderWheelFlutterViewController: FlutterViewController {
  private let wheelInput = ReaderWheelInput()
  private var wheelChannel: FlutterBasicMessageChannel?

  override func viewDidLoad() {
    super.viewDidLoad()
    guard wheelChannel == nil else { return }
    let channel = FlutterBasicMessageChannel(
      name: ReaderWheelInput.channelName,
      binaryMessenger: engine.binaryMessenger,
      codec: FlutterStandardMessageCodec.sharedInstance())
    wheelChannel = channel
    channel.setMessageHandler { [weak self] message, reply in
      guard let self else { reply(nil); return }
      self.wheelInput.receive(message, reply: reply)
    }
  }

  override func scrollWheel(with event: NSEvent) {
    defer { super.scrollWheel(with: event) }
    guard wheelInput.isReady, attached(), isViewLoaded, let channel = wheelChannel,
          event.phase.isEmpty, event.momentumPhase.isEmpty,
          let content = view.subviews.first,
          content.isFlipped, content.frame == view.bounds,
          let layer = content.layer else { return }
    // The pinned Flutter controller wraps its flipped render view in an NSView.
    let location = content.convertToBacking(content.convert(event.locationInWindow, from: nil))
    let sample = ReaderWheelSample(
      timestamp: event.timestamp,
      precise: event.hasPreciseScrollingDeltas,
      phase: event.phase,
      momentumPhase: event.momentumPhase,
      modifiers: event.modifierFlags,
      locationInBacking: location,
      contentsScale: layer.contentsScale,
      scrollingDeltaX: event.scrollingDeltaX,
      scrollingDeltaY: event.scrollingDeltaY)
    if let packet = wheelInput.packet(for: sample, viewId: viewIdentifier) {
      channel.sendMessage(packet)
    }
  }

  override func onPreEngineRestart() {
    wheelInput.reset()
    super.onPreEngineRestart()
  }

  deinit {
    wheelChannel?.setMessageHandler(nil)
  }
}
