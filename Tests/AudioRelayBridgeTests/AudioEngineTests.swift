import XCTest
import CoreAudio
import AudioToolbox
@testable import AudioRelayBridge

final class AudioEngineTests: XCTestCase {
    private func device(_ id: AudioDeviceID = 1, name: String, input: Int = 0, output: Int = 2,
                        rate: Double = 48000, supported: [Double] = [44100, 48000]) -> Device {
        Device(id: id, name: name, inputChannels: input, outputChannels: output,
               nominalRate: rate, availableRates: supported.map { AudioValueRange(mMinimum: $0, mMaximum: $0) })
    }

    func testBlackHoleCannotFeedBackIntoItself() {
        XCTAssertFalse(isMusicOutput(device(name: "BlackHole 2ch", input: 2)))
        XCTAssertThrowsError(try chooseOutput([device(name: "BlackHole 2ch", input: 2)], wanted: "BlackHole 2ch"))
    }

    func testMultiOutputContainingBlackHoleIsRejected() {
        var aggregate = device(name: "Multi-Output Device")
        aggregate.containsBlackHole = true
        XCTAssertFalse(isMusicOutput(aggregate))
        XCTAssertThrowsError(try chooseOutput([aggregate], wanted: aggregate.name))
    }

    func testHighRateInputCanPrimeWithinRingCapacity() {
        for rate in [48000.0, 705600, 768000] {
            let threshold = primingSamples(rate: rate, channels: 2, capacity: 262144)
            XCTAssertGreaterThan(threshold, 0)
            XCTAssertLessThan(threshold, 262144)
            XCTAssertEqual(threshold % 2, 0)
        }
        XCTAssertEqual(primingSamples(rate: 48000, channels: 2, capacity: 262144), 19200)
    }

    func testMonoConversionIncludesRightChannel() throws {
        var source = floatFormat(rate: 48000, channels: 2)
        var destination = floatFormat(rate: 48000, channels: 1)
        var created: AudioConverterRef?
        try check(AudioConverterNew(&source, &destination, &created), "create test converter")
        let converter = try XCTUnwrap(created)
        defer { AudioConverterDispose(converter) }
        try configureChannelMix(converter, inputChannels: 2, outputChannels: 1)
        let input: [Float] = [0, 1, 1, 0, 1, 1, -1, 1]
        var output = Array(repeating: Float(0), count: 4)
        var bytes = UInt32(output.count * MemoryLayout<Float>.size)
        let status = input.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                AudioConverterConvertBuffer(converter, UInt32(source.count), source.baseAddress!,
                                            &bytes, destination.baseAddress!)
            }
        }
        XCTAssertEqual(status, noErr)
        XCTAssertEqual(output, [0.5, 0.5, 1, 0])
    }

    func testMusicConnectionWinsOverSameNamedCallDevice() throws {
        let call = device(1, name: "Bluetooth Headphones", rate: 16000, supported: [16000])
        let music = device(2, name: "Bluetooth Headphones", rate: 44100)
        XCTAssertEqual(try chooseOutput([call, music], wanted: "bluetooth headphones").id, 2)
        XCTAssertThrowsError(try chooseOutput([call], wanted: "Bluetooth Headphones"))
    }

    func testInputSelectionNeverFallsBackToPhysicalMicrophone() throws {
        let mic = device(name: "Built-in Microphone", input: 1, output: 0)
        let wrong = device(2, name: "BlackHole 16ch", input: 16)
        let blackHole = device(3, name: "BlackHole 2ch", input: 2)
        XCTAssertThrowsError(try chooseInput([mic, wrong], wanted: nil))
        XCTAssertEqual(try chooseInput([mic, wrong, blackHole], wanted: nil).id, 3)
    }

    func testRingWrapsAndKeepsNewestAudioOnOverflow() {
        let ring = Ring(capacity: 8)
        func write(_ samples: [Float]) { samples.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: $0.count) } }
        func read(_ count: Int) -> [Float] {
            var buffer = Array(repeating: Float(-1), count: count)
            let got = buffer.withUnsafeMutableBufferPointer { ring.read($0.baseAddress!, count: count) }
            return Array(buffer.prefix(got))
        }
        write([0, 1, 2, 3, 4, 5])
        XCTAssertEqual(read(4), [0, 1, 2, 3])
        write([6, 7, 8, 9, 10, 11, 12, 13])
        XCTAssertEqual(ring.available, 8)
        XCTAssertEqual(read(10), [6, 7, 8, 9, 10, 11, 12, 13])
        XCTAssertEqual(read(1), [])
        write(Array(20...31).map(Float.init))
        XCTAssertEqual(read(8), Array(24...31).map(Float.init))
    }

    func testStoppedSupervisorIgnoresQueuedDeviceEvents() {
        let supervisor = Supervisor(wantedInput: nil, wantedOutput: nil)
        var reported = false
        supervisor.onStatus = { _, _ in reported = true }
        supervisor.stopWatching()
        supervisor.evaluate()
        XCTAssertFalse(supervisor.isWatching)
        XCTAssertFalse(reported)
    }

    func testHealthyInputDoesNotHideFailingPlayback() {
        let engine = Engine(input: device(name: "BlackHole 2ch", input: 2), output: device(name: "Speakers"))
        let fault = expectation(description: "Output fault reaches supervisor once")
        fault.assertForOverFulfill = true
        engine.onFault = { fault.fulfill() }
        for _ in 0..<25 {
            engine.recordResult(-1, input: false)
            engine.recordResult(noErr, input: true)
        }
        wait(for: [fault], timeout: 1)
    }
}
