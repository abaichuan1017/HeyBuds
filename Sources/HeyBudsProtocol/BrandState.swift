// Shared presentation state, brand-specific decoding. GPL-3.0-or-later.
import Foundation

public enum BrandState {
    @discardableResult public static func apply(_ frame:BrandFrame,model:DeviceModel,to state:inout DeviceState) -> Bool {
        let p=frame.payload,c=frame.command
        var observed:UInt16?
        switch model.family {
        case .vivo:
            switch c {
            case 0x8207:
                guard p.count >= 5,p[0] == 0 else { return false }
                for (i,slot) in BatterySlot.allCases.enumerated() { setBattery(p[i+1],slot:slot,charging:p[4] & (1<<i) != 0,state:&state) }
                observed=Command.battery
            case 0x8230:
                guard p.count >= 2,p[0] == 0,let noise=([0:NoiseMode.anc,1:.off,2:.transparency])[Int(p[1])] else { return false }
                state.noise=noise;observed=Command.noise
            case 0x8218:
                guard p.count >= 2,p[0] == 0 else { return false }
                let eq=(6...10).contains(p[1]) ? 4 : p[1]
                state.eq=model.presets.contains(where:{$0.id == eq}) ? eq : nil;observed=Command.equalizer
            case 0x8239:
                guard p.count >= 2,p[0] == 0,p[1] <= 2 else { return false }
                state.spatial=p[1];observed=Command.spatial
            case 0x8203,0x8251,0x8252:
                guard p.count >= 2,p[0] == 0,p[1] <= 1 else { return false }
                let key:UInt8=c == 0x8203 ? 4 : c == 0x8251 ? 6 : 0x70
                state.switches[key]=p[1] == 1;observed=Command.switches
            case 0x820D:
                guard p.count >= 2,p[0] == 0 else { return false }
                state.placement[.left]=p[1] & 4 != 0 ? 3 : p[1] & 1 != 0 ? 4 : 1
                state.placement[.right]=p[1] & 8 != 0 ? 3 : p[1] & 2 != 0 ? 4 : 1;observed=Command.wear
            case 0x8249:
                guard let hosts=vivoHosts(p) else { return false };state.hosts=hosts;observed=Command.hosts
                // GAIA has no automatic-priority setting. Do not synthesize one.
            case 0x821C:
                guard p.count >= 2,p[0] == 0 else { return false }
                let value=String(bytes:p.dropFirst().prefix(while:{$0 != 0}),encoding:.utf8)
                if let value,!value.isEmpty,value.unicodeScalars.allSatisfy({!CharacterSet.controlCharacters.contains($0)}) { state.firmware=value.components(separatedBy:"_").first }
                else { state.firmware=p.dropFirst().map(String.init).joined(separator:".") };observed=Command.firmware
            default:return false
            }
        case .huawei:
            guard let fields=BrandFrameCodec.tlv(p) else { return false }
            switch c {
            case 0x0108,0x0127:
                guard let levels=fields[2],!levels.isEmpty else { return false }
                for (i,slot) in BatterySlot.allCases.enumerated() {
                    if model.singleBattery && i > 0 { state.batteries[slot]=nil;continue }
                    if i < levels.count { setBattery(levels[i],slot:slot,charging:(fields[3].flatMap { i < $0.count ? $0[i] : nil } ?? 0) != 0,state:&state) }
                };observed=Command.battery
            case 0x2B2A:
                guard let value=fields[1],value.count == 2 else { return false }
                switch value[1] {
                case 0:state.noise = .off
                case 1:state.noise=model.noiseOptions.first { $0.mode != .anc && $0.writeBytes == [1,value[0]] }?.mode ?? .anc
                case 2:state.noise = .transparency
                default:return false
                };observed=Command.noise
            case 0x2B11,0x2B6C,0x2B2F:
                let type:UInt8=c == 0x2B6C ? 2 : 1
                guard let byte=fields[type]?.first,byte <= 1 else { return false }
                state.switches[c == 0x2B11 ? 4 : c == 0x2B6C ? 6 : 0x11]=byte == 1;observed=Command.switches
            case 0x2B4A:
                guard fields[1]?.first == 1,let selected=fields[2]?.first else { return false }
                state.eq=selected;observed=Command.equalizer
                // An ordinary EQ response does not establish that custom slots
                // were read. Missing/corrupt slot data must preserve the last list.
                if let custom=fields[8],let entries=huaweiCustomEntries(custom,selected:selected,model:model) {
                    state.customEQ=entries
                    state.observedQueries.insert(Command.customEQ)
                }
            case 0x2B03:
                for (type,slot):(UInt8,BatterySlot) in [(8,.left),(9,.right)] {
                    if let value=fields[type]?.first,value <= 1 { state.placement[slot]=value == 1 ? 3 : 1 }
                };observed=Command.wear
            // Host enumeration is collected atomically in the session, never incrementally published.
            default:return false
            }
        case .edifier:
            if c == 0xD0,let level=p.first,level <= 100 { setBattery(level,slot:.left,charging:false,state:&state);observed=Command.battery }
            else if c == 0xCC,let mode=p.first,let value=([1:NoiseMode.off,2:.anc,3:.transparency])[Int(mode)] { state.noise=value;observed=Command.noise }
            else { return false }
        case .xiaomi:
            if p.starts(with:[2,2,4,7]),p.count >= 5 {
                for (i,slot) in BatterySlot.allCases.enumerated() where p.count > i+4 { setBattery(p[i+4],slot:slot,charging:false,state:&state) }
                observed=Command.battery
            } else if [UInt16(0xF3),0xF4].contains(c),p.count >= 4,p[0] == 3,p[1] == 0,p[2] == 47,p[3] <= 1 {
                state.switches[6]=p[3] == 1;observed=Command.switches
            } else { return false }
        default:return false
        }
        if let observed { state.observedQueries.insert(observed) }
        return observed != nil
    }
    private static func huaweiCustomEntries(_ bytes:[UInt8],selected:UInt8,model:DeviceModel) -> [CustomEQEntry]? {
        guard bytes.count % 36 == 0, model.customEQFrequencies.count == 10 else { return nil }
        var entries:[CustomEQEntry]=[]
        for offset in stride(from:0,to:bytes.count,by:36) {
            guard (0x64...0x66).contains(bytes[offset]),bytes[offset+1] == 10,
                  !entries.contains(where:{$0.id == bytes[offset]}),
                  let name=String(bytes:bytes[offset+12..<offset+36].prefix(while:{$0 != 0}),encoding:.utf8) else { return nil }
            let gains=bytes[offset+2..<offset+12].map { Int8(bitPattern:$0) }
            guard gains.allSatisfy({(-60...60).contains($0)}) else { return nil }
            entries.append(CustomEQEntry(id:bytes[offset],name:name,selected:selected == bytes[offset],minimum:-60,maximum:60,frequencies:model.customEQFrequencies,gains:gains))
        }
        return entries
    }
    private static func setBattery(_ value:UInt8,slot:BatterySlot,charging:Bool,state:inout DeviceState) {
        state.batteries[slot]=value <= 100 ? BatteryReading(percent:Int(value),charging:charging) : nil
    }
    public static func vivoHosts(_ bytes:[UInt8]) -> [RemoteHost]? {
        guard bytes.count >= 2,bytes[0] == 0,bytes[1] <= 32 else { return nil }
        var offset=2,result:[RemoteHost]=[]
        for _ in 0..<Int(bytes[1]) {
            guard offset+11 <= bytes.count else { return nil }
            let address=Array(bytes[offset..<offset+6].reversed()),state=bytes[offset+9],count=Int(bytes[offset+10])
            guard state <= 2,offset+11+count <= bytes.count else { return nil }
            let name=String(bytes:bytes[offset+11..<offset+11+count],encoding:.utf8) ?? ""
            result.append(RemoteHost(address:address,name:name,type:0,connection:state,flags:state == 2 ? 4 : 0));offset += 11+count
        }
        guard offset == bytes.count,Set(result.map(\.id)).count == result.count else { return nil };return result
    }
    public static func huaweiHost(_ bytes:[UInt8]) -> (count:Int,index:Int,host:RemoteHost?)? {
        guard let f=BrandFrameCodec.tlv(bytes),let count=f[2]?.first,count <= 32 else { return nil }
        if count == 0 { return (0,0,nil) }
        guard let index=f[3]?.first,let address=f[4],address.count == 6,let connection=f[5]?.first else { return nil }
        let name=String(bytes:f[9] ?? [],encoding:.utf8)?.trimmingCharacters(in:.controlCharacters) ?? ""
        let flags:UInt8=(f[7]?.first == 1 ? 2 : 0) | (connection == 9 ? 4 : 0)
        return (Int(count),Int(index),RemoteHost(address:address,name:name,type:0,connection:connection > 0 ? 2 : 0,flags:flags))
    }
}
