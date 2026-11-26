import Testing
import HeyBudsBluetooth
@testable import HeyBuds

private func soundDevice(_ id:String, _ name:String="Earbuds") -> DeviceCandidate {
    DeviceCandidate(id:id,name:name,audioConnected:true,classicAddress:nil,systemAudioOnly:true)
}
@Test func connectionRefreshesAndControlRetriesDoNotRepeatAnnouncements() {
    var presence=ConnectionPresence()
    let a=soundDevice("earbuds-a")
    #expect(presence.update([]).added.isEmpty)
    #expect(presence.update([a]).added == [a])
    for _ in 0..<10 { #expect(presence.update([a]).added.isEmpty) }
    #expect(presence.update([]).removed == [a])
    #expect(presence.update([a]).added == [a])
}
@Test func secondDeviceAndDisconnectHaveSeparatePresence() {
    var presence=ConnectionPresence()
    let a=soundDevice("a","Desk"), b=soundDevice("b","Desk"), renamed=soundDevice("a","Evening")
    _=presence.update([a])
    #expect(presence.update([a,b]).added == [b])
    let rename=presence.update([renamed,b])
    #expect(rename.added.isEmpty && rename.removed.isEmpty)
    #expect(presence.update([b]).removed == [renamed])
    #expect(presence.update([b]).removed.isEmpty)
}
@Test func hiddenMenuItemCanAlwaysBeRevealedByExplicitAccess() {
    #expect(!ConnectionPresence.showsStatusItem(background:true,hasConnection:false,explicitAccess:false))
    #expect(ConnectionPresence.showsStatusItem(background:true,hasConnection:false,explicitAccess:true))
    #expect(ConnectionPresence.showsStatusItem(background:true,hasConnection:true,explicitAccess:false))
    #expect(ConnectionPresence.showsStatusItem(background:false,hasConnection:false,explicitAccess:false))
}
@Test func systemVolumeMatchesTheBluetoothEndpointAcrossRenamesAndDuplicateNames() throws {
    // Synthetic address components stay separate from real device identifiers.
    let a=["02","00","00","00","00","01"], b=["02","00","00","00","00","02"]
    func device(_ parts:[String], name:String,connected:Bool=true) -> DeviceCandidate {
        let address=parts.joined(separator:"-")
        return DeviceCandidate(id:address,name:name,audioConnected:connected,classicAddress:address,systemAudioOnly:true)
    }
    func output(_ parts:[String],_ suffix:String,_ id:UInt32) -> SystemAudio.Output {
        let uid=parts.joined(separator:":")+suffix
        return .init(route:.init(uid:uid,objectID:id),name:"Headphones",address:SystemAudio.bluetoothAddress(in:uid))
    }
    let first=output(a,":output",11), alternate=output(a,":handsfree",12), second=output(b,"",21)
    let paired=[device(a,name:"My train"),device(b,name:"My train")]
    let devices=SystemAudio.merge(paired:paired,outputs:[second,alternate,first],defaultOutput:11)
    #expect(devices.map(\.audioRoute) == [first.route,second.route])
    #expect(devices.map(\.name) == ["My train","My train"])
    #expect(SystemAudio.merge(paired:paired,outputs:[second,alternate,first],defaultOutput:21)[0].audioRoute == nil)
    #expect(SystemAudio.merge(paired:[device(a,name:"Renamed",connected:false)],outputs:[first],defaultOutput:11)[0].audioRoute == nil)
    let le=SystemAudio.Output(route:.init(uid:"opaque-fixture",objectID:42),name:"Headphones",address:nil)
    let standalone=try #require(SystemAudio.merge(paired:[],outputs:[le],defaultOutput:nil).first)
    #expect(standalone.systemAudioOnly && standalone.audioConnected && standalone.name == "Headphones" && standalone.audioRoute == le.route)
    #expect(SystemAudio.bluetoothAddress(in:"prefix"+a.joined()) == nil)
}

@Test func systemVolumeWritesOnlyToTheRequestedLiveOutputAndReturnsItsReadback() {
    let target=BluetoothAudioRoute(uid:"audio-a",objectID:4)
    var uid=target.uid, writable=true, volume:Float=0.25, writes=0
    func endpoint(_ id:UInt32) -> SystemAudio.VolumeEndpoint? {
        guard id == target.objectID else { return nil }
        return .init(uid:uid,level:.init(value:volume,writable:writable)) { request in
            writes += 1; volume=(request*10).rounded()/10
        }
    }
    #expect(SystemAudio.set(0.64,on:target,resolve:endpoint)?.value == 0.6 && writes == 1)
    writable=false
    #expect(SystemAudio.set(1,on:target,resolve:endpoint)?.value == 0.6 && writes == 1)
    writable=true; uid="replacement-output"
    #expect(SystemAudio.set(1,on:target,resolve:endpoint) == nil)
    uid=target.uid
    #expect(SystemAudio.set(.nan,on:target,resolve:endpoint) == nil && writes == 1)
}
