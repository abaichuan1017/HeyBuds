// JBL Protocol 3 and Tune 770NC RACE facts from MIT references in Licenses/JBL-MIT.txt.
import Foundation

public enum JBLProfile:String,CaseIterable,Sendable {
    case tune230="JBL TUNE230NC TWS",waveBuds2="JBL Wave Buds 2",tune770="JBL Tune 770NC"
    public static let service="65786365-6C70-6F69-6E74-2E636F6D0000"
    public static let notify="65786365-6C70-6F69-6E74-2E636F6D0001"
    public static let write="65786365-6C70-6F69-6E74-2E636F6D0002"
    public var modelID:String { switch self { case .tune230:return "jbl:tune230nc";case .waveBuds2:return "jbl:wave-buds-2";case .tune770:return "jbl:tune770nc" } }
    public var usesBLE:Bool { self != .tune770 }
    public static func named(_ name:String) -> Self? {
        var n=name.trimmingCharacters(in:.whitespacesAndNewlines)
        if n.uppercased().hasSuffix("-LE") { n=String(n.dropLast(3)) }
        return allCases.first { EarbudFamily.normalize($0.rawValue) == EarbudFamily.normalize(n) }
    }
    public var noiseRead:JBLFrame { usesBLE ? JBLFrame(0x91,[0x11]) : JBLFrame(0x0901,[5,0]) }
    public func noiseWrite(_ mode:NoiseMode) -> JBLFrame? {
        guard [NoiseMode.off,.anc,.transparency].contains(mode) else { return nil }
        if usesBLE { return JBLFrame(0x91,[0x10,1,mode == .anc ? 1 : 0,2,mode == .transparency ? 1 : 0,3,0]) }
        return JBLFrame(0x0E06,mode == .off ? [0,0x0B] : [0,0x0A,mode == .anc ? 1 : 0x0A])
    }
    public func noise(_ frame:JBLFrame) -> NoiseMode? {
        let p=frame.payload
        if !usesBLE {
            guard frame.command == 0x0901,[UInt8(0x5B),0x5D].contains(frame.kind),p.count >= 4,p.count <= 64 else { return nil }
            return [UInt8(0):NoiseMode.off,1:.anc,0x0A:.transparency][p[3]]
        }
        guard frame.command == 0x91,p.count == 7,p[0] == 0x12,p[1] == 1,p[3] == 2,p[5] == 3,[p[2],p[4],p[6]].allSatisfy({ $0 <= 1 }),Int(p[2])+Int(p[4])+Int(p[6]) <= 1 else { return nil }
        // TalkThru is distinct from Ambient Aware; do not silently relabel it.
        if p[6] == 1 { return nil };return p[2] == 1 ? .anc : p[4] == 1 ? .transparency : .off
    }
    public static let informationRead=JBLFrame(0x06,[1,0,1,0,5,0,0x1A,0,0x1B,0,0x1C])
    public func information(_ p:[UInt8]) -> DeviceState? {
        guard self == .waveBuds2,p.first == 2 else { return nil }
        var i=1,fields:[UInt16:[UInt8]]=[:]
        while i < p.count {
            guard i+3 <= p.count else { return nil }
            let id=UInt16(p[i]) << 8 | UInt16(p[i+1]),count=Int(p[i+2]);i += 3
            guard i+count <= p.count,fields[id] == nil else { return nil };fields[id]=Array(p[i..<i+count]);i += count
        }
        var state=DeviceState()
        if let nameBytes=fields[1] {
            guard !nameBytes.isEmpty,nameBytes.count <= 128,let name=String(bytes:nameBytes.prefix(while:{ $0 != 0 }),encoding:.utf8),Self.named(name) == self else { return nil }
        }
        if let v=fields[5],v.count == 3 { state.firmware=v.map(String.init).joined(separator:".");state.observedQueries.insert(Command.firmware) }
        for (id,slot):(UInt16,BatterySlot) in [(0x1A,.left),(0x1B,.right),(0x1C,.enclosure)] {
            if let v=fields[id],v.count == 2,v[0] <= 1,v[1] <= 100 { state.batteries[slot]=BatteryReading(percent:Int(v[1]),charging:v[0] == 1) }
        }
        if !state.batteries.isEmpty { state.observedQueries.insert(Command.battery) };return state
    }
}
public struct JBLFrame:Equatable,Sendable {
    public let command:UInt16,payload:[UInt8],kind:UInt8
    public init(_ command:UInt16,_ payload:[UInt8]=[],kind:UInt8=0x5A) { self.command=command;self.payload=payload;self.kind=kind }
}
public struct JBLFrameCodec {
    private var buffer:[UInt8]=[]
    private let profile:JBLProfile
    public init(profile:JBLProfile) { self.profile=profile }
    public mutating func reset() { buffer=[] }
    public static func encode(_ frame:JBLFrame,profile:JBLProfile) throws -> Data {
        guard frame.payload.count <= 4096 else { throw ProtocolError.invalidPayload }
        if profile.usesBLE {
            guard let cmd=UInt8(exactly:frame.command),[UInt8(6),0x91,0x9B].contains(cmd) else { throw ProtocolError.unsupported }
            guard cmd == 6 || frame.payload.count <= 255 else { throw ProtocolError.invalidPayload }
            let n=frame.payload.count
            return Data([0xAA,cmd,UInt8(truncatingIfNeeded:n)]+(cmd == 6 ? [UInt8(n >> 8)] : [])+frame.payload)
        }
        guard [UInt16(0x0901),0x0E06].contains(frame.command) else { throw ProtocolError.unsupported }
        let n=frame.payload.count+2
        return Data([5,frame.kind,UInt8(truncatingIfNeeded:n),UInt8(n >> 8),UInt8(truncatingIfNeeded:frame.command),UInt8(frame.command >> 8)]+frame.payload)
    }
    public mutating func feed(_ data:Data) -> [JBLFrame] {
        var out:[JBLFrame]=[]
        for byte in data {
            buffer.append(byte)
            while !buffer.isEmpty {
                guard buffer[0] == (profile.usesBLE ? 0xAA : 5) else { buffer.removeFirst();continue }
                guard buffer.count >= 4 else { break }
                let header=profile.usesBLE ? ([UInt8(6),0xA2].contains(buffer[1]) ? 4 : 3) : 6
                let n=header == 3 ? Int(buffer[2]) : Int(buffer[2]) | Int(buffer[3]) << 8
                guard n <= 4096,profile.usesBLE || n >= 2 else { buffer.removeFirst();continue }
                let total=profile.usesBLE ? header+n : 4+n
                guard buffer.count >= total else { break }
                if profile.usesBLE { out.append(JBLFrame(UInt16(buffer[1]),Array(buffer[header..<total]),kind:0)) }
                else if [UInt8(0x5B),0x5D].contains(buffer[1]) { out.append(JBLFrame(UInt16(buffer[4]) | UInt16(buffer[5]) << 8,Array(buffer[6..<total]),kind:buffer[1])) }
                buffer.removeFirst(total)
            }
        }
        return out
    }
}
