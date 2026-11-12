// Captures BlackHole with one HAL unit and plays through a second HAL unit.
// Converts sample rates without changing the output device’s hardware rate.

import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation
import os

struct AudioSetupError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

struct Device {
    let id: AudioDeviceID
    let name: String
    let inputChannels: Int
    let outputChannels: Int
    let nominalRate: Float64
    let availableRates: [AudioValueRange]
    var containsBlackHole = false
    var isBluetooth = false

    func supports(_ rate: Double) -> Bool {
        availableRates.contains { rate >= $0.mMinimum && rate <= $0.mMaximum }
    }

    var isCallOnly: Bool {
        !availableRates.isEmpty && availableRates.allSatisfy { $0.mMaximum <= 16000 }
    }
}

func propertyAddress(_ selector: AudioObjectPropertySelector,
                     scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector,
                               mScope: scope,
                               mElement: kAudioObjectPropertyElementMain)
}

func deviceName(_ id: AudioObjectID) -> String {
    var address = propertyAddress(kAudioObjectPropertyName)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
    guard status == noErr, let value else { return "" }
    return value.takeRetainedValue() as String
}

func nominalRate(_ id: AudioDeviceID) -> Float64 {
    var address = propertyAddress(kAudioDevicePropertyNominalSampleRate)
    var rate: Float64 = 0
    var size = UInt32(MemoryLayout<Float64>.size)
    AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate)
    return rate
}

func availableRates(_ id: AudioDeviceID) -> [AudioValueRange] {
    var address = propertyAddress(kAudioDevicePropertyAvailableNominalSampleRates)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
    let count = Int(size) / MemoryLayout<AudioValueRange>.stride
    var ranges = Array(repeating: AudioValueRange(mMinimum: 0, mMaximum: 0), count: count)
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &ranges) == noErr else { return [] }
    return ranges
}

func channelCount(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
    var address = propertyAddress(kAudioDevicePropertyStreamConfiguration, scope: scope)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { memory.deallocate() }
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, memory) == noErr else { return 0 }
    let list = memory.assumingMemoryBound(to: AudioBufferList.self)
    return UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + Int($1.mNumberChannels) }
}

// Multi-Output Devices are aggregate devices too. Check their members to prevent feedback.
func containsBlackHole(_ id: AudioDeviceID, visited: Set<AudioDeviceID> = []) -> Bool {
    guard !visited.contains(id) else { return false }
    if deviceName(id).localizedCaseInsensitiveContains("blackhole") { return true }
    var address = propertyAddress(kAudioAggregateDevicePropertyActiveSubDeviceList)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return false }
    var members = Array(repeating: AudioDeviceID(0), count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &members) == noErr else { return true }
    return members.contains { containsBlackHole($0, visited: visited.union([id])) }
}

func isBluetooth(_ id: AudioDeviceID) -> Bool {
    var address = propertyAddress(kAudioDevicePropertyTransportType)
    var transport: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transport) == noErr else { return false }
    return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
}

func allDevices() -> [Device] {
    var address = propertyAddress(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    let system = AudioObjectID(kAudioObjectSystemObject)
    guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    var ids = Array(repeating: AudioDeviceID(0), count: count)
    guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
    return ids.map {
        Device(id: $0,
               name: deviceName($0),
               inputChannels: channelCount($0, scope: kAudioDevicePropertyScopeInput),
               outputChannels: channelCount($0, scope: kAudioDevicePropertyScopeOutput),
               nominalRate: nominalRate($0),
               availableRates: availableRates($0),
               containsBlackHole: containsBlackHole($0),
               isBluetooth: isBluetooth($0))
    }
}

func rateList(_ device: Device) -> String {
    device.availableRates.map { range in
        range.mMinimum == range.mMaximum
            ? String(Int(range.mMinimum))
            : "\(Int(range.mMinimum))-\(Int(range.mMaximum))"
    }.joined(separator: ",")
}

func printDevices(_ devices: [Device]) {
    for device in devices {
        print(String(format: "%4u  in=%-2d out=%-2d  %6.0f Hz  [%@]  %@",
                     device.id,
                     device.inputChannels,
                     device.outputChannels,
                     device.nominalRate,
                     rateList(device),
                     device.name))
    }
}

func chooseInput(_ devices: [Device], wanted: String?) throws -> Device {
    let matches = devices.filter { device in
        if let wanted {
            return device.name.compare(wanted, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                && device.inputChannels > 0
        }
        return device.name.localizedCaseInsensitiveContains("blackhole")
            && device.name.localizedCaseInsensitiveContains("2ch")
            && device.inputChannels >= 2
    }
    guard let found = matches.first else {
        throw AudioSetupError(message: "BlackHole 2ch is not installed. Install it, then reopen AudioRelay Bridge.")
    }
    return found
}

func defaultOutputID() -> AudioDeviceID? {
    var address = propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
    guard status == noErr, id != 0 else { return nil }
    return id
}

func isBlackHole(_ device: Device) -> Bool {
    device.containsBlackHole || device.name.localizedCaseInsensitiveContains("blackhole")
}

func isMusicOutput(_ device: Device) -> Bool {
    guard device.outputChannels >= 1, !device.isCallOnly, !isBlackHole(device) else { return false }
    if device.nominalRate >= 40000 { return true }
    return device.availableRates.contains { $0.mMaximum >= 40000 }
}

func sameName(_ device: Device, as name: String) -> Bool {
    device.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
}

func musicDevice(named name: String, in devices: [Device]) -> Device? {
    let music = devices.filter { sameName($0, as: name) && isMusicOutput($0) }
    return music.first { $0.nominalRate >= 40000 } ?? music.first
}

func chooseOutput(_ devices: [Device], wanted: String?) throws -> Device {
    if let wanted {
        guard let found = musicDevice(named: wanted, in: devices) else {
            throw AudioSetupError(message: "No music output named \(wanted). It may be using its call connection.")
        }
        return found
    }
    guard let defaultID = defaultOutputID(), let current = devices.first(where: { $0.id == defaultID }) else {
        throw AudioSetupError(message: "No default output device.")
    }
    if isMusicOutput(current) { return current }
    if let sibling = musicDevice(named: current.name, in: devices) { return sibling }
    throw AudioSetupError(message: "\(current.name) is not a music output.")
}

func check(_ status: OSStatus, _ what: String) throws {
    if status != noErr {
        throw AudioSetupError(message: "\(what) failed (\(status)).")
    }
}

func makeHAL() throws -> AudioUnit {
    var description = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                                componentSubType: kAudioUnitSubType_HALOutput,
                                                componentManufacturer: kAudioUnitManufacturer_Apple,
                                                componentFlags: 0,
                                                componentFlagsMask: 0)
    guard let component = AudioComponentFindNext(nil, &description) else {
        throw AudioSetupError(message: "HAL output component not found.")
    }
    var unit: AudioUnit?
    let status = AudioComponentInstanceNew(component, &unit)
    guard status == noErr, let unit else {
        throw AudioSetupError(message: "Could not create HAL unit (\(status)).")
    }
    return unit
}

func setEnabled(_ unit: AudioUnit, scope: AudioUnitScope, element: UInt32, enabled: Bool) throws {
    var value: UInt32 = enabled ? 1 : 0
    try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, scope, element, &value, 4),
              "EnableIO scope \(scope) element \(element)")
}

func selectDevice(_ id: AudioDeviceID, on unit: AudioUnit) throws {
    var device = id
    try check(AudioUnitSetProperty(unit,
                                   kAudioOutputUnitProperty_CurrentDevice,
                                   kAudioUnitScope_Global,
                                   0,
                                   &device,
                                   UInt32(MemoryLayout<AudioDeviceID>.size)),
              "select device \(id)")
}

func streamFormat(_ unit: AudioUnit, scope: AudioUnitScope, element: UInt32) throws -> AudioStreamBasicDescription {
    var format = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    try check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, scope, element, &format, &size),
              "read stream format")
    return format
}

func floatFormat(rate: Float64, channels: UInt32) -> AudioStreamBasicDescription {
    AudioStreamBasicDescription(mSampleRate: rate,
                                mFormatID: kAudioFormatLinearPCM,
                                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                mBytesPerPacket: channels * 4,
                                mFramesPerPacket: 1,
                                mBytesPerFrame: channels * 4,
                                mChannelsPerFrame: channels,
                                mBitsPerChannel: 32,
                                mReserved: 0)
}

func setStreamFormat(_ format: AudioStreamBasicDescription, on unit: AudioUnit, scope: AudioUnitScope, element: UInt32) throws {
    var format = format
    try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, scope, element, &format,
                                   UInt32(MemoryLayout<AudioStreamBasicDescription>.size)),
              "set stream format")
}

func setMaxFrames(_ unit: AudioUnit, _ frames: UInt32) throws {
    var frames = frames
    try check(AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &frames, 4),
              "set max frames")
}

final class Ring: @unchecked Sendable {
    let capacity: Int
    private let data: UnsafeMutablePointer<Float>
    private let lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
    private var readPos = 0
    private var writePos = 0

    init(capacity: Int) {
        self.capacity = capacity
        data = .allocate(capacity: capacity)
        data.initialize(repeating: 0, count: capacity)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        data.deallocate()
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    var available: Int {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return writePos - readPos
    }

    func write(_ source: UnsafePointer<Float>, count: Int) {
        guard count > 0 else { return }
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        if writePos - readPos + count > capacity {
            readPos = writePos + count - capacity
        }
        var remaining = count
        var sourceOffset = 0
        while remaining > 0 {
            let index = writePos % capacity
            let chunk = min(remaining, capacity - index)
            data.advanced(by: index).update(from: source.advanced(by: sourceOffset), count: chunk)
            writePos += chunk
            sourceOffset += chunk
            remaining -= chunk
        }
    }

    func read(_ destination: UnsafeMutablePointer<Float>, count: Int) -> Int {
        guard count > 0 else { return 0 }
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        let have = min(count, writePos - readPos)
        var remaining = have
        var destinationOffset = 0
        while remaining > 0 {
            let index = readPos % capacity
            let chunk = min(remaining, capacity - index)
            destination.advanced(by: destinationOffset).update(from: data.advanced(by: index), count: chunk)
            readPos += chunk
            destinationOffset += chunk
            remaining -= chunk
        }
        return have
    }
}

func configureChannelMix(_ converter: AudioConverterRef, inputChannels: Int, outputChannels: Int) throws {
    guard inputChannels == 2, outputChannels == 1 else { return }
    var downmix: UInt32 = 1
    try check(AudioConverterSetProperty(converter, kAudioConverterPropertyPerformDownmix, 4, &downmix),
              "enable mono downmix")
    var gains: [Float32] = [0.5, 0.5]
    try check(AudioConverterSetProperty(converter, kAudioConverterPropertyChannelMixMap,
                                       UInt32(gains.count * MemoryLayout<Float32>.size), &gains),
              "mix both stereo channels to mono")
}

func primingSamples(rate: Double, channels: Int, capacity: Int) -> Int {
    let channels = max(channels, 1)
    // Reserve half the ring for capture bursts, even at BlackHole’s highest rates.
    return min(Int(rate * 0.2), capacity / channels / 2) * channels
}

final class Engine: @unchecked Sendable {
    let inputDevice: Device
    let outputDevice: Device
    let maxFrames = 8192
    let ring: Ring
    var inputUnit: AudioUnit?
    var outputUnit: AudioUnit?
    var converter: AudioConverterRef?
    var inputChannels = 0
    var outputChannels = 0
    var inputRate: Float64 = 0
    var primed = false
    var onFault: (() -> Void)?
    // Input and output callbacks run on different audio threads.
    private let faultState = OSAllocatedUnfairLock(initialState: (input: 0, output: 0, reported: false))
    let inputScratch: UnsafeMutablePointer<Float>
    let converterScratch: UnsafeMutablePointer<Float>
    let inputList: UnsafeMutablePointer<AudioBufferList>

    init(input: Device, output: Device) {
        inputDevice = input
        outputDevice = output
        ring = Ring(capacity: 262144)
        inputScratch = .allocate(capacity: maxFrames * 2)
        converterScratch = .allocate(capacity: maxFrames * 2)
        inputList = .allocate(capacity: 1)
        inputList.pointee.mNumberBuffers = 1
        inputList.pointee.mBuffers = AudioBuffer(mNumberChannels: 2,
                                                 mDataByteSize: 0,
                                                 mData: UnsafeMutableRawPointer(inputScratch))
    }

    deinit {
        stop()
        inputScratch.deallocate()
        converterScratch.deallocate()
        inputList.deallocate()
    }

    func start() throws {
        stop()
        let capture = try makeHAL()
        inputUnit = capture
        try setEnabled(capture, scope: kAudioUnitScope_Input, element: 1, enabled: true)
        try setEnabled(capture, scope: kAudioUnitScope_Output, element: 0, enabled: false)
        try selectDevice(inputDevice.id, on: capture)
        let hardwareIn = try streamFormat(capture, scope: kAudioUnitScope_Input, element: 1)
        inputChannels = Int(hardwareIn.mChannelsPerFrame)
        inputRate = hardwareIn.mSampleRate
        guard inputChannels > 0, inputRate >= 1 else {
            throw AudioSetupError(message: microphoneMessage())
        }
        guard inputChannels <= 2 else {
            throw AudioSetupError(message: "Use BlackHole 2ch; this bridge supports at most two input channels.")
        }
        inputList.pointee.mBuffers.mNumberChannels = UInt32(inputChannels)
        let clientIn = floatFormat(rate: hardwareIn.mSampleRate, channels: hardwareIn.mChannelsPerFrame)
        try setStreamFormat(clientIn, on: capture, scope: kAudioUnitScope_Output, element: 1)
        try setMaxFrames(capture, UInt32(maxFrames))
        var inputCallback = AURenderCallbackStruct(inputProc: captureCallback,
                                                   inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try check(AudioUnitSetProperty(capture,
                                       kAudioOutputUnitProperty_SetInputCallback,
                                       kAudioUnitScope_Global,
                                       0,
                                       &inputCallback,
                                       UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
                  "set input callback")

        let playback = try makeHAL()
        outputUnit = playback
        try setEnabled(playback, scope: kAudioUnitScope_Output, element: 0, enabled: true)
        try setEnabled(playback, scope: kAudioUnitScope_Input, element: 1, enabled: false)
        let rateBefore = nominalRate(outputDevice.id)
        try selectDevice(outputDevice.id, on: playback)
        let rateAfter = nominalRate(outputDevice.id)
        let hardwareOut = try streamFormat(playback, scope: kAudioUnitScope_Output, element: 0)
        outputChannels = Int(hardwareOut.mChannelsPerFrame)
        guard outputChannels > 0 else {
            throw AudioSetupError(message: "Headset opened with no output channels.")
        }
        if outputDevice.isBluetooth && hardwareOut.mSampleRate > 0 && hardwareOut.mSampleRate < 40000 {
            throw AudioSetupError(message: "Refusing to play: \(outputDevice.name) opened at \(Int(hardwareOut.mSampleRate)) Hz, which is the call device. Do not use it as the Mac input.")
        }
        if rateAfter != rateBefore {
            print("Warning: opening \(outputDevice.name) changed its rate from \(Int(rateBefore)) to \(Int(rateAfter)).")
        }
        let clientOut = floatFormat(rate: hardwareOut.mSampleRate, channels: hardwareOut.mChannelsPerFrame)
        try setStreamFormat(clientOut, on: playback, scope: kAudioUnitScope_Input, element: 0)
        try setMaxFrames(playback, UInt32(maxFrames))
        var outputCallback = AURenderCallbackStruct(inputProc: playbackCallback,
                                                    inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try check(AudioUnitSetProperty(playback,
                                       kAudioUnitProperty_SetRenderCallback,
                                       kAudioUnitScope_Input,
                                       0,
                                       &outputCallback,
                                       UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
                  "set output callback")

        var converter: AudioConverterRef?
        var source = clientIn
        var destination = clientOut
        try check(AudioConverterNew(&source, &destination, &converter), "create converter")
        guard let converter else {
            throw AudioSetupError(message: "Converter was not created.")
        }
        self.converter = converter
        try configureChannelMix(converter, inputChannels: inputChannels, outputChannels: outputChannels)
        var quality = UInt32(kAudioConverterQuality_Max)
        AudioConverterSetProperty(converter,
                                  kAudioConverterSampleRateConverterQuality,
                                  UInt32(MemoryLayout<UInt32>.size),
                                  &quality)

        try check(AudioUnitInitialize(capture), "initialize input")
        try check(AudioUnitInitialize(playback), "initialize output")
        try check(AudioOutputUnitStart(capture), "start input")
        try check(AudioOutputUnitStart(playback), "start output")
        print(String(format: "input  %@  %.0f Hz %d ch", inputDevice.name, hardwareIn.mSampleRate, inputChannels))
        print(String(format: "output %@  %.0f Hz %d ch", outputDevice.name, hardwareOut.mSampleRate, outputChannels))
        print("Bridge running. AudioRelay output must be BlackHole 2ch. Playback follows the menu-bar output.")
        fflush(stdout)
    }

    func stop() {
        if let outputUnit {
            AudioOutputUnitStop(outputUnit)
            AudioUnitUninitialize(outputUnit)
            AudioComponentInstanceDispose(outputUnit)
        }
        if let inputUnit {
            AudioOutputUnitStop(inputUnit)
            AudioUnitUninitialize(inputUnit)
            AudioComponentInstanceDispose(inputUnit)
        }
        if let converter {
            AudioConverterDispose(converter)
        }
        outputUnit = nil
        inputUnit = nil
        converter = nil
        primed = false
    }

    func renderInput(frames: UInt32,
                     time: UnsafePointer<AudioTimeStamp>,
                     flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>) -> OSStatus {
        guard let inputUnit, frames > 0, frames <= UInt32(maxFrames) else { return noErr }
        inputList.pointee.mBuffers.mDataByteSize = frames * UInt32(inputChannels) * 4
        inputList.pointee.mBuffers.mData = UnsafeMutableRawPointer(inputScratch)
        let status = AudioUnitRender(inputUnit, flags, time, 1, frames, inputList)
        recordResult(status, input: true)
        guard status == noErr else { return status }
        ring.write(inputScratch, count: Int(frames) * inputChannels)
        return noErr
    }

    func renderOutput(frames: UInt32, data: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
        guard let data, let converter else { return noErr }
        let prime = primingSamples(rate: inputRate, channels: inputChannels, capacity: ring.capacity)
        if !primed {
            if ring.available < prime {
                silence(data)
                return noErr
            }
            primed = true
        }
        var packetCount = frames
        let status = AudioConverterFillComplexBuffer(converter, converterInput, Unmanaged.passUnretained(self).toOpaque(), &packetCount, data, nil)
        recordResult(status, input: false)
        return status
    }

    func recordResult(_ status: OSStatus, input: Bool) {
        let notify = faultState.withLock { state in
            if input {
                state.input = status == noErr ? 0 : min(state.input + 1, 20)
            } else {
                state.output = status == noErr ? 0 : min(state.output + 1, 20)
            }
            guard !state.reported, state.input >= 20 || state.output >= 20 else { return false }
            state.reported = true
            return true
        }
        if notify {
            DispatchQueue.main.async { [weak self] in self?.onFault?() }
        }
    }

    func fillConverter(packets: UnsafeMutablePointer<UInt32>, data: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let frames = min(Int(packets.pointee), maxFrames)
        let samples = frames * inputChannels
        let got = ring.read(converterScratch, count: samples)
        if got < samples {
            converterScratch.advanced(by: got).initialize(repeating: 0, count: samples - got)
        }
        data.pointee.mNumberBuffers = 1
        data.pointee.mBuffers.mNumberChannels = UInt32(inputChannels)
        data.pointee.mBuffers.mDataByteSize = UInt32(samples * 4)
        data.pointee.mBuffers.mData = UnsafeMutableRawPointer(converterScratch)
        packets.pointee = UInt32(frames)
        return noErr
    }

    func silence(_ data: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(data)
        for buffer in buffers {
            guard let bytes = buffer.mData else { continue }
            memset(bytes, 0, Int(buffer.mDataByteSize))
        }
    }
}

private func captureCallback(inRefCon: UnsafeMutableRawPointer,
                             ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                             inTimeStamp: UnsafePointer<AudioTimeStamp>,
                             inBusNumber: UInt32,
                             inNumberFrames: UInt32,
                             ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    Unmanaged<Engine>.fromOpaque(inRefCon).takeUnretainedValue().renderInput(frames: inNumberFrames,
                                                                             time: inTimeStamp,
                                                                             flags: ioActionFlags)
}

private func playbackCallback(inRefCon: UnsafeMutableRawPointer,
                              ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                              inTimeStamp: UnsafePointer<AudioTimeStamp>,
                              inBusNumber: UInt32,
                              inNumberFrames: UInt32,
                              ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    Unmanaged<Engine>.fromOpaque(inRefCon).takeUnretainedValue().renderOutput(frames: inNumberFrames, data: ioData)
}

private func converterInput(inAudioConverter: AudioConverterRef,
                            ioNumberDataPackets: UnsafeMutablePointer<UInt32>,
                            ioData: UnsafeMutablePointer<AudioBufferList>,
                            outDataPacketDescription: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
                            inUserData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let inUserData else { return kAudioConverterErr_UnspecifiedError }
    return Unmanaged<Engine>.fromOpaque(inUserData).takeUnretainedValue().fillConverter(packets: ioNumberDataPackets, data: ioData)
}

func microphoneMessage() -> String {
    let status = AVCaptureDevice.authorizationStatus(for: .audio)
    return "BlackHole opened with no audio format (microphone permission: \(status)). macOS treats reading BlackHole as microphone access. Allow AudioRelay Bridge in System Settings → Privacy & Security → Microphone."
}

// Lifecycle and device listeners are confined to the main queue.
final class Supervisor {
    var onStatus: ((String, Bool) -> Void)?
    private(set) var isWatching = false
    let wantedInput: String?
    let wantedOutput: String?
    private var engine: Engine?
    private var runningInput: AudioDeviceID?
    private var runningOutput: AudioDeviceID?
    private var runningInputRate: Float64?
    private var runningOutputRate: Float64?
    private var lastReport = ""
    private var evaluating = false
    private var dirty = false
    private var retryItem: DispatchWorkItem?
    private var deviceBlock: AudioObjectPropertyListenerBlock?
    private var watches: [(AudioDeviceID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    init(wantedInput: String?, wantedOutput: String?) {
        self.wantedInput = wantedInput
        self.wantedOutput = wantedOutput
    }

    func startWatching() {
        guard !isWatching else { return }
        isWatching = true
        lastReport = ""
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.evaluate()
        }
        deviceBlock = block
        let system = AudioObjectID(kAudioObjectSystemObject)
        var devicesAddress = propertyAddress(kAudioHardwarePropertyDevices)
        var defaultAddress = propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(system, &devicesAddress, .main, block)
        AudioObjectAddPropertyListenerBlock(system, &defaultAddress, .main, block)
        evaluate()
    }

    func stopWatching() {
        isWatching = false
        cancelRetry()
        if let block = deviceBlock {
            let system = AudioObjectID(kAudioObjectSystemObject)
            var devicesAddress = propertyAddress(kAudioHardwarePropertyDevices)
            var defaultAddress = propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
            AudioObjectRemovePropertyListenerBlock(system, &devicesAddress, .main, block)
            AudioObjectRemovePropertyListenerBlock(system, &defaultAddress, .main, block)
        }
        deviceBlock = nil
        stopEngine()
        lastReport = ""
    }

    func evaluate() {
        guard isWatching else { return }
        if evaluating {
            dirty = true
            return
        }
        evaluating = true
        defer {
            evaluating = false
            if dirty {
                dirty = false
                evaluate()
            }
        }

        let devices = allDevices()
        let input = try? chooseInput(devices, wanted: wantedInput)
        let output = try? chooseOutput(devices, wanted: wantedOutput)
        guard let input, let output else {
            stopEngine()
            report(waitingMessage(devices))
            scheduleRetry()
            return
        }
        if engine != nil,
           runningInput == input.id, runningOutput == output.id,
           runningInputRate == input.nominalRate, runningOutputRate == output.nominalRate {
            return
        }

        stopEngine()
        let started = Engine(input: input, output: output)
        started.onFault = { [weak self, weak started] in
            guard let self, let started, self.engine === started else { return }
            self.report("audio device stopped")
            self.stopEngine()
            self.evaluate()
        }
        do {
            try started.start()
            engine = started
            runningInput = input.id
            runningOutput = output.id
            runningInputRate = input.nominalRate
            runningOutputRate = output.nominalRate
            lastReport = ""
            cancelRetry()
            watch(input.id)
            watch(output.id)
            onStatus?("BlackHole 2ch → \(output.name)\n\(Int(input.nominalRate)) Hz → \(Int(output.nominalRate)) Hz", true)
        } catch {
            started.stop()
            report(String(describing: error))
            scheduleRetry()
        }
    }

    func waitingMessage(_ devices: [Device]) -> String {
        if (try? chooseInput(devices, wanted: wantedInput)) == nil {
            return "waiting for BlackHole 2ch"
        }
        if let wantedOutput {
            let named = devices.filter { sameName($0, as: wantedOutput) }
            if named.isEmpty {
                return "waiting for \(wantedOutput). Playback starts when that device connects."
            }
            return "\(wantedOutput) is connected as a call device. Waiting for its music connection."
        }
        guard let defaultID = defaultOutputID(), let current = devices.first(where: { $0.id == defaultID }) else {
            return "waiting for an output device. Choose the headphones in the menu bar."
        }
        if isBlackHole(current) {
            return "Mac output includes BlackHole, which would loop. Choose the headphones directly in the menu bar."
        }
        if current.isCallOnly || current.outputChannels < 1 || current.nominalRate < 40000 {
            return "\(current.name) is connected as a call device. Waiting for its music connection. Do not use it as the Mac input."
        }
        return "waiting for a usable output. Current Mac output is \(current.name)."
    }

    func stopEngine() {
        clearWatches()
        engine?.stop()
        engine = nil
        runningInput = nil
        runningOutput = nil
        runningInputRate = nil
        runningOutputRate = nil
    }

    func report(_ message: String) {
        guard message != lastReport else { return }
        lastReport = message
        onStatus?(message, false)
        print(message)
        fflush(stdout)
    }

    func scheduleRetry() {
        guard engine == nil, retryItem == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            self?.retryItem = nil
            self?.evaluate()
        }
        retryItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: item)
    }

    func cancelRetry() {
        retryItem?.cancel()
        retryItem = nil
    }

    func watch(_ id: AudioDeviceID) {
        for selector in [kAudioDevicePropertyNominalSampleRate, kAudioDevicePropertyDeviceIsAlive,
                         kAudioAggregateDevicePropertyActiveSubDeviceList] {
            var address = propertyAddress(selector)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.evaluate()
            }
            AudioObjectAddPropertyListenerBlock(id, &address, .main, block)
            watches.append((id, address, block))
        }
    }

    func clearWatches() {
        for (id, address, block) in watches {
            var address = address
            AudioObjectRemovePropertyListenerBlock(id, &address, .main, block)
        }
        watches.removeAll()
    }
}
