import AudioToolbox
import CoreAudio
import Foundation
import HeyBudsBluetooth

enum SystemAudio {
    struct Output {
        let route:BluetoothAudioRoute
        let name:String
        let address:String?
    }
    struct Level:Equatable {
        let value:Float
        let writable:Bool
    }
    struct VolumeService {
        var level:(BluetoothAudioRoute) -> Level? = SystemAudio.level
        var set:(Float,BluetoothAudioRoute) -> Level? = { SystemAudio.set($0,on:$1) }
        var changes:(BluetoothAudioRoute) -> AsyncStream<Void> = SystemAudio.volumeChanges
    }

    private static let system = AudioObjectID(kAudioObjectSystemObject)
    private static func property(_ selector:AudioObjectPropertySelector, output:Bool=false) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector:selector,mScope:output ? kAudioDevicePropertyScopeOutput : kAudioObjectPropertyScopeGlobal,
                                   mElement:kAudioObjectPropertyElementMain)
    }
    private static func read<T>(_ device:AudioObjectID,_ property:AudioObjectPropertyAddress,initial:T) -> T? {
        var property=property, value=initial, size=UInt32(MemoryLayout<T>.size)
        let status=withUnsafeMutableBytes(of:&value) {
            AudioObjectGetPropertyData(device,&property,0,nil,&size,$0.baseAddress!)
        }
        return status == noErr && size == MemoryLayout<T>.size ? value : nil
    }
    private static func string(_ device:AudioObjectID,_ selector:AudioObjectPropertySelector) -> String? {
        let result:Unmanaged<CFString>? = read(device,property(selector),initial:Optional<Unmanaged<CFString>>.none) ?? nil
        return result?.takeRetainedValue() as String?
    }
    private static func isBluetoothOutput(_ device:AudioObjectID) -> Bool {
        guard let type=read(device,property(kAudioDevicePropertyTransportType),initial:UInt32(0)),
              type == kAudioDeviceTransportTypeBluetooth || type == kAudioDeviceTransportTypeBluetoothLE else { return false }
        var streams=property(kAudioDevicePropertyStreams,output:true), size:UInt32=0
        return AudioObjectGetPropertyDataSize(device,&streams,0,nil,&size) == noErr && size >= MemoryLayout<AudioStreamID>.size
            && read(device,property(kAudioDevicePropertyDeviceIsAlive),initial:UInt32(0)) == 1
    }

    // Some Bluetooth HAL UIDs contain the paired address followed by a profile suffix.
    // Other UIDs are opaque and stay associated only with their own Core Audio object.
    static func bluetoothAddress(in value:String) -> String? {
        let bytes = Array(value.lowercased().utf8)
        func hex(_ byte:UInt8) -> Bool { (48...57).contains(byte) || (97...102).contains(byte) }
        for length in [17,12] where bytes.count >= length {
            guard bytes.count == length || [45,58,47].contains(bytes[length]) else { continue }
            let prefix=bytes.prefix(length)
            if length == 17 {
                let separator=bytes[2]
                guard [45,58].contains(separator),
                      prefix.enumerated().allSatisfy({ $0.offset % 3 == 2 ? $0.element == separator : hex($0.element) }) else { continue }
            } else if !prefix.allSatisfy(hex) { continue }
            return String(decoding:prefix.filter(hex),as:UTF8.self)
        }
        return nil
    }
    private static func outputs() -> [Output]? {
        var list=property(kAudioHardwarePropertyDevices), size:UInt32=0
        guard AudioObjectGetPropertyDataSize(system,&list,0,nil,&size) == noErr else { return nil }
        if size == 0 { return [] }
        var ids=[AudioDeviceID](repeating:0,count:Int(size)/MemoryLayout<AudioDeviceID>.size)
        let status=ids.withUnsafeMutableBytes { AudioObjectGetPropertyData(system,&list,0,nil,&size,$0.baseAddress!) }
        guard status == noErr else { return nil }
        return ids.prefix(Int(size)/MemoryLayout<AudioDeviceID>.size).compactMap { id in
            guard isBluetoothOutput(id), let uid=string(id,kAudioDevicePropertyDeviceUID),
                  let name=string(id,kAudioObjectPropertyName) else { return nil }
            let address=bluetoothAddress(in:uid) ?? string(id,kAudioObjectPropertySerialNumber).flatMap(bluetoothAddress)
            return Output(route:.init(uid:uid,objectID:id),name:name,address:address)
        }
    }
    actor Inventory {
        private var lastOutputs:[Output]=[]
        func devices(paired:[DeviceCandidate]) -> [DeviceCandidate] {
            // A transient HAL read failure is not a disconnect event.
            if let snapshot=outputs() { lastOutputs=snapshot }
            return merge(paired:paired,outputs:lastOutputs,defaultOutput:read(system,property(kAudioHardwarePropertyDefaultOutputDevice),initial:UInt32(0)))
        }
    }
    static func merge(paired:[DeviceCandidate],outputs:[Output],defaultOutput:AudioDeviceID?) -> [DeviceCandidate] {
        var groups=Dictionary(grouping:outputs) { $0.address ?? "audio:"+$0.route.uid }
        func preferred(_ outputs:[Output]) -> BluetoothAudioRoute? {
            if outputs.count == 1 { return outputs[0].route }
            return outputs.first { $0.route.objectID == defaultOutput }?.route
        }
        var devices=paired.map { candidate in
            var device=candidate
            if let address=candidate.classicAddress.flatMap(bluetoothAddress), let matches=groups.removeValue(forKey:address), candidate.audioConnected {
                device.audioRoute=preferred(matches)
            }
            return device
        }
        for key in groups.keys.sorted() {
            guard let group=groups[key], let output=group.first else { continue }
            let id=output.address.map { address in
                stride(from:0,to:12,by:2).map { String(address.dropFirst($0).prefix(2)) }.joined(separator:"-")
            } ?? key
            devices.append(DeviceCandidate(id:id,name:output.name,audioConnected:true,classicAddress:nil,systemAudioOnly:true,audioRoute:preferred(group)))
        }
        return devices
    }
    private static func volumeControl(_ id:AudioObjectID) -> (AudioObjectPropertyAddress,Level)? {
        guard isBluetoothOutput(id) else { return nil }
        var readable:(AudioObjectPropertyAddress,Level)?
        for selector in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume,kAudioDevicePropertyVolumeScalar] {
            var address=property(selector,output:true)
            guard AudioObjectHasProperty(id,&address), let value=read(id,address,initial:Float32(0)),
                  value.isFinite,(0...1).contains(value) else { continue }
            let level=Level(value:value,writable:isWritable(id,address))
            if level.writable { return (address,level) }
            if readable == nil { readable=(address,level) }
        }
        return readable
    }
    private static func isWritable(_ id:AudioObjectID,_ property:AudioObjectPropertyAddress) -> Bool {
        var address=property
        var writable:DarwinBoolean=false
        return AudioObjectIsPropertySettable(id,&address,&writable) == noErr && writable.boolValue
    }
    struct VolumeEndpoint {
        var uid:String
        var level:Level
        var write:(Float) -> Void
    }
    static func endpoint(_ id:AudioObjectID) -> VolumeEndpoint? {
        guard let uid=string(id,kAudioDevicePropertyDeviceUID), let (property,level)=volumeControl(id) else { return nil }
        return VolumeEndpoint(uid:uid,level:level) { value in
            guard string(id,kAudioDevicePropertyDeviceUID) == uid else { return }
            var address=property
            var volume=value
            _=AudioObjectSetPropertyData(id,&address,0,nil,UInt32(MemoryLayout.size(ofValue:volume)),&volume)
        }
    }
    static func level(_ route:BluetoothAudioRoute) -> Level? {
        guard let device=endpoint(route.objectID), device.uid == route.uid else { return nil }
        return device.level
    }
    @discardableResult static func set(_ value:Float, on route:BluetoothAudioRoute,
                                       resolve:(AudioObjectID) -> VolumeEndpoint? = endpoint) -> Level? {
        guard value.isFinite, (0...1).contains(value), let device=resolve(route.objectID), device.uid == route.uid else { return nil }
        guard device.level.writable else { return device.level }
        device.write(value)
        guard let result=resolve(route.objectID), result.uid == route.uid else { return nil }
        return result.level
    }
    private static func observe(_ object:AudioObjectID,_ address:AudioObjectPropertyAddress,_ changed:@escaping () -> Void) -> () -> Void {
        var property=address
        let listener:AudioObjectPropertyListenerBlock={ _,_ in changed() }
        guard AudioObjectAddPropertyListenerBlock(object,&property,.main,listener) == noErr else { return {} }
        return { var p=address; AudioObjectRemovePropertyListenerBlock(object,&p,.main,listener) }
    }
    static func observeOutputs(_ changed:@escaping () -> Void) -> () -> Void {
        let devices=observe(system,property(kAudioHardwarePropertyDevices),changed)
        let output=observe(system,property(kAudioHardwarePropertyDefaultOutputDevice),changed)
        return { devices(); output() }
    }
    static func volumeChanges(_ route:BluetoothAudioRoute) -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy:.bufferingNewest(1)) { continuation in
            continuation.yield(())
            let changes = [kAudioHardwareServiceDeviceProperty_VirtualMainVolume,kAudioDevicePropertyVolumeScalar].map { selector in
                observe(route.objectID,property(selector,output:true)) { continuation.yield(()) }
            }
            let controls=observe(route.objectID,property(kAudioObjectPropertyControlList)) { continuation.yield(()) }
            continuation.onTermination={ _ in changes.forEach { $0() }; controls() }
        }
    }
}
