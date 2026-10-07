import AudioToolbox
import Combine
import CoreAudio
import Foundation

struct AudioDevice: Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let transport: UInt32
    let hasInput: Bool
    let hasOutput: Bool

    var isBuiltIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }

    func has(_ direction: AudioDirection) -> Bool { direction == .input ? hasInput : hasOutput }
}

enum AudioDirection: String, CaseIterable {
    case input, output

    fileprivate var scope: AudioObjectPropertyScope {
        self == .input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
    }

    fileprivate var defaultSelector: AudioObjectPropertySelector {
        self == .input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice
    }
}

/// The Mac's audio devices, and the order the person prefers them in. Aloud uses the
/// highest-ranked device that's connected, whatever macOS's own default is. Until someone
/// sets an order for a direction, that direction follows macOS.
final class AudioDevices: ObservableObject {
    static let shared = AudioDevices()

    /// A ranked device, remembered by its UID so it keeps its place while disconnected.
    struct Entry: Codable, Hashable, Identifiable {
        let uid: String
        var name: String
        var transport: UInt32
        var id: String { uid }
    }

    @Published private(set) var connected: [AudioDevice] = []
    @Published private(set) var systemDefault: [AudioDirection: String] = [:]
    @Published private var orders: [AudioDirection: [Entry]] = [:]

    /// Fires on the main queue when the device to use may have changed:
    /// `true` when the person reordered the list, `false` when hardware or macOS's default changed.
    let routeChanged = PassthroughSubject<Bool, Never>()

    private init() {
        for direction in AudioDirection.allCases {
            if let data = UserDefaults.standard.data(forKey: Self.defaultsKey(direction)),
               let entries = try? JSONDecoder().decode([Entry].self, from: data) {
                orders[direction] = entries
            }
        }
        refresh()
        let selectors = [kAudioHardwarePropertyDevices] + AudioDirection.allCases.map(\.defaultSelector)
        for selector in selectors {
            var address = Self.address(selector)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
                self?.refresh()
                self?.routeChanged.send(false)
            }
        }
    }

    // MARK: - Ranking

    /// True once the person has put this direction's devices in an order.
    func isCustom(_ direction: AudioDirection) -> Bool { orders[direction] != nil }

    /// What Settings shows: the chosen order (including disconnected devices), or, while
    /// following macOS, the connected devices with macOS's default first.
    func list(_ direction: AudioDirection) -> [Entry] {
        if let order = orders[direction] { return order }
        let devices = connected.filter { $0.has(direction) }
        let first = devices.filter { $0.uid == systemDefault[direction] }
        return (first + devices.filter { $0.uid != systemDefault[direction] }).map(Self.entry)
    }

    func setOrder(_ entries: [Entry], for direction: AudioDirection) {
        save(entries, for: direction)
        routeChanged.send(true)
    }

    /// Back to using whatever macOS is set to.
    func followSystem(_ direction: AudioDirection) {
        save(nil, for: direction)
        routeChanged.send(true)
    }

    func forget(_ uid: String, for direction: AudioDirection) {
        guard let order = orders[direction] else { return }
        save(order.filter { $0.uid != uid }, for: direction)
    }

    func isConnected(_ uid: String, for direction: AudioDirection) -> Bool {
        connected.contains { $0.uid == uid && $0.has(direction) }
    }

    /// The device Aloud is using (or would use) right now.
    func current(_ direction: AudioDirection) -> String? {
        Self.preferredDevice(direction, order: orders[direction], devices: connected)?.uid
    }

    /// The device to use: the highest-ranked one that's connected, else macOS's default.
    /// Asks Core Audio afresh, so it's right even before a device-change notification arrives.
    static func preferredDevice(_ direction: AudioDirection) -> AudioDevice? {
        preferredDevice(direction, order: shared.orders[direction], devices: scan())
    }

    private static func preferredDevice(_ direction: AudioDirection, order: [Entry]?, devices: [AudioDevice]) -> AudioDevice? {
        let usable = devices.filter { $0.has(direction) }
        for entry in order ?? [] {
            if let device = usable.first(where: { $0.uid == entry.uid }) { return device }
        }
        let id = defaultDeviceID(direction)
        return usable.first { $0.id == id } ?? usable.first
    }

    private func refresh() {
        connected = Self.scan()
        systemDefault = Dictionary(uniqueKeysWithValues: AudioDirection.allCases.compactMap { direction in
            let id = Self.defaultDeviceID(direction)
            return connected.first { $0.id == id }.map { (direction, $0.uid) }
        })
        // New devices join the bottom of a chosen order; known ones pick up name changes.
        for direction in AudioDirection.allCases {
            guard var order = orders[direction] else { continue }
            for device in connected where device.has(direction) {
                if let i = order.firstIndex(where: { $0.uid == device.uid }) {
                    order[i].name = device.name
                    order[i].transport = device.transport
                } else {
                    order.append(Self.entry(device))
                }
            }
            if order != orders[direction] { save(order, for: direction) }
        }
    }

    private func save(_ order: [Entry]?, for direction: AudioDirection) {
        orders[direction] = order
        let key = Self.defaultsKey(direction)
        if let order, let data = try? JSONEncoder().encode(order) {
            UserDefaults.standard.set(data, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private static func defaultsKey(_ direction: AudioDirection) -> String { "audioDeviceOrder.\(direction.rawValue)" }

    private static func entry(_ device: AudioDevice) -> Entry {
        Entry(uid: device.uid, name: device.name, transport: device.transport)
    }

    // MARK: - Core Audio

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func defaultDeviceID(_ direction: AudioDirection) -> AudioDeviceID {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = address(direction.defaultSelector)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return id
    }

    /// Every audio device people would recognise (no hidden or system-made aggregate devices).
    static func scan() -> [AudioDevice] {
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap(device)
    }

    private static func device(_ id: AudioDeviceID) -> AudioDevice? {
        guard let uid = string(id, kAudioDevicePropertyDeviceUID), !uid.hasPrefix("CADefaultDeviceAggregate"),
              uint32(id, kAudioDevicePropertyIsHidden) != 1,
              uint32(id, kAudioDevicePropertyDeviceIsAlive) != 0
        else { return nil }
        let hasInput = streamCount(id, .input) > 0, hasOutput = streamCount(id, .output) > 0
        guard hasInput || hasOutput else { return nil }
        return AudioDevice(id: id, uid: uid, name: string(id, kAudioObjectPropertyName) ?? uid,
                           transport: uint32(id, kAudioDevicePropertyTransportType) ?? 0,
                           hasInput: hasInput, hasOutput: hasOutput)
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func streamCount(_ id: AudioObjectID, _ direction: AudioDirection) -> Int {
        var address = address(kAudioDevicePropertyStreams, scope: direction.scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }

    // MARK: - Engines

    /// Points an engine's input or output unit at a device. The engine must be stopped.
    @discardableResult
    static func use(_ device: AudioDeviceID, on unit: AudioUnit?) -> Bool {
        guard let unit else { return false }
        var id = device
        return AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                    &id, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr
    }

    static func device(of unit: AudioUnit?) -> AudioDeviceID? {
        guard let unit else { return nil }
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, &size) == noErr
        else { return nil }
        return id
    }
}
