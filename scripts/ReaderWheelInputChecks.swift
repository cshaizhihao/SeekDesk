import Cocoa
import FlutterMacOS

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
  precondition(condition(), message)
}

private func number(_ packet: [String: Any], _ field: String) -> Double {
  (packet[field] as! NSNumber).doubleValue
}

private func fixture() -> ReaderWheelSample {
  ReaderWheelSample(timestamp: 42.12345675, precise: false, phase: [], momentumPhase: [],
    modifiers: [], locationInBacking: NSPoint(x: 120.5, y: -240.25),
    contentsScale: 1, scrollingDeltaX: 0.25, scrollingDeltaY: -0.975)
}

@main
private enum ReaderWheelInputChecks {
  static func main() {
    let sample = fixture()
    let packet = sample.packet(sequence: 9, viewId: 4)!
    require(Set(packet.keys) == Set(["version", "sequence", "viewId", "timestampMicros",
      "precise", "phase", "momentumPhase", "modifiers", "x", "y", "dx", "dy"]),
      "The protocol has exactly the agreed numeric/classification fields")
    require(number(packet, "version") == 1 && number(packet, "sequence") == 9 &&
      number(packet, "viewId") == 4, "Protocol identity is preserved")
    require(number(packet, "timestampMicros") == 42_123_456,
      "Timestamp conversion truncates fractional microseconds like the engine")
    require(packet["precise"] as? Bool == false && number(packet, "phase") == 0 &&
      number(packet, "momentumPhase") == 0, "Nonprecise classification remains explicit")
    require(number(packet, "x") == 120.5 && number(packet, "y") == 240.25,
      "Already-converted backing X is retained and engine backing Y is inverted")
    require(number(packet, "dx") == -10 && number(packet, "dy") == 39,
      "A fractional nonprecise line uses the engine's 40px multiplier and signs")
    let codec = FlutterStandardMessageCodec.sharedInstance()
    let decoded = codec.decode(codec.encode(packet)) as! [String: Any]
    require(number(decoded, "timestampMicros") == 42_123_456 &&
      decoded["precise"] as? Bool == false && number(decoded, "dy") == 39,
      "The production StandardMessageCodec retains integer, bool and double fields")
    print("PASS native protocol, exact timestamp, coordinates, fractional wheel and codec")

    for scale in [1.0, 1.5, 2.0] {
      var scaled = sample
      scaled.contentsScale = scale
      scaled.locationInBacking = NSPoint(x: 120.5 * scale, y: -240.25 * scale)
      let p = scaled.packet(sequence: 1, viewId: 0)!
      require(number(p, "dx") / scale == -10 && number(p, "dy") / scale == 39,
        "Physical wheel distance scales once and logical distance survives DPR division")
      require(number(p, "x") == 120.5 * scale && number(p, "y") == 240.25 * scale,
        "Backing coordinates are not multiplied by scale a second time")
      scaled.precise = true
      let precise = scaled.packet(sequence: 1, viewId: 0)!
      require(precise["precise"] as? Bool == true &&
        number(precise, "dx") == -0.25 * scale && number(precise, "dy") == 0.975 * scale,
        "Phaseless precise input is reported without the nonprecise line multiplier")
    }
    print("PASS DPR1/fractional/DPR2 and precise-device passthrough classification")

    var shifted = sample
    shifted.modifiers = [.shift, .command, .option, .control, .capsLock, .numericPad, .function]
    shifted.modifiers.insert(NSEvent.ModifierFlags(rawValue: 1))
    let shiftPacket = shifted.packet(sequence: 1, viewId: 0)!
    require(number(shiftPacket, "dx") == 39 && number(shiftPacket, "dy") == -10,
      "Shift undoes AppKit's axis swap exactly once")
    require(UInt(number(shiftPacket, "modifiers")) == shifted.modifiers
      .intersection(.deviceIndependentFlagsMask).rawValue,
      "All device-independent flags survive while device-specific low bits are removed")
    shifted.precise = true
    let shiftedPrecise = shifted.packet(sequence: 1, viewId: 0)!
    require(number(shiftedPrecise, "dx") == 0.975 && number(shiftedPrecise, "dy") == -0.25,
      "The engine applies its Shift normalization to precise pointer-scroll input too")
    print("PASS Shift normalization and complete device-independent modifier flags")

    let phases: [NSEvent.Phase] = [.mayBegin, .began, .stationary, .changed, .ended, .cancelled,
      [.began, .changed]]
    for phase in phases {
      var phased = sample
      phased.phase = phase
      require(phased.packet(sequence: 1, viewId: 0) == nil,
        "Phased pan/zoom is not classified as a pointer-scroll signal")
      phased.phase = []
      phased.momentumPhase = phase
      require(phased.packet(sequence: 1, viewId: 0) == nil,
        "Native momentum is left to the engine's existing gesture handling")
    }
    print("PASS phase and momentum exclusion, including compound phase flags")

    let invalid: [(inout ReaderWheelSample) -> Void] = [
      { $0.timestamp = .nan }, { $0.timestamp = .infinity }, { $0.timestamp = -1 },
      { $0.timestamp = Double(Int64.max) / 1_000_000 },
      { $0.contentsScale = 0 }, { $0.contentsScale = -1 },
      { $0.contentsScale = .nan }, { $0.contentsScale = .infinity },
      { $0.locationInBacking.x = .nan }, { $0.locationInBacking.y = .infinity },
      { $0.scrollingDeltaX = .nan }, { $0.scrollingDeltaY = .infinity },
      { $0.scrollingDeltaY = .greatestFiniteMagnitude },
    ]
    for mutate in invalid {
      var bad = sample
      mutate(&bad)
      require(bad.packet(sequence: 1, viewId: 0) == nil,
        "Nonfinite, overflow and invalid scale/time inputs fail closed without conversion traps")
    }
    require(sample.packet(sequence: 0, viewId: 0) == nil &&
      sample.packet(sequence: 1, viewId: -1) == nil, "Invalid identity is not published")
    var zero = sample
    zero.scrollingDeltaX = 0
    zero.scrollingDeltaY = 0
    require(zero.packet(sequence: 1, viewId: 0) != nil,
      "Native classification does not invent Dart eligibility for no-effect input")
    print("PASS finite/range rejection and zero-delta classification")

    let input = ReaderWheelInput()
    require(!input.isReady && input.packet(for: sample, viewId: 0) == nil && input.sequence == 0,
      "No metadata is produced before the Dart handler is ready")
    let invalidMessages: [Any] = [NSNull(), ["type": "ready"], ["type": "other", "version": 1],
      ["type": "ready", "version": 2], ["type": "ready", "version": true],
      ["type": "ready", "version": 1.0], ["type": "ready", "version": "1"]]
    for bad in invalidMessages {
      var replied = false
      input.receive(bad) { reply in
        replied = true
        require(reply == nil, "Invalid handshake replies with no accepted version")
      }
      require(replied && !input.isReady, "An invalid handshake never enables publication")
    }
    var readyReplies = 0
    let ready = codec.decode(codec.encode(["type": "ready", "version": 1]))
    input.receive(ready) { reply in
      readyReplies += 1
      require((reply as? [String: Int]) == ["version": 1], "Handshake returns the agreed version")
      require(!input.isReady && input.packet(for: sample, viewId: 0) == nil,
        "Publication is still disabled while returning the ready reply")
    }
    require(readyReplies == 1 && input.isReady, "Publication enables only after replying")
    let first = input.packet(for: sample, viewId: 0)!
    let duplicateTime = input.packet(for: sample, viewId: 0)!
    require(number(first, "sequence") == 1 && number(duplicateTime, "sequence") == 2 &&
      number(first, "timestampMicros") == number(duplicateTime, "timestampMicros"),
      "Native sequence distinguishes equal timestamps without altering event time")
    var rejected = sample
    rejected.phase = .changed
    require(input.packet(for: rejected, viewId: 0) == nil && input.sequence == 2,
      "Rejected samples neither publish nor consume a packet sequence")
    input.reset()
    require(!input.isReady && input.packet(for: sample, viewId: 0) == nil,
      "Engine restart revokes readiness before further wheel publication")
    input.receive(ready) { _ in input.reset() }
    require(!input.isReady, "A reset during reply cannot revive a stale ready handshake")
    input.receive(ready) { _ in }
    require(number(input.packet(for: sample, viewId: 0)!, "sequence") == 3,
      "A fresh ready handshake resumes monotonic sequence after engine restart")
    print("PASS ready handshake ordering, invalid messages, duplicate time and restart lifecycle")
  }
}
