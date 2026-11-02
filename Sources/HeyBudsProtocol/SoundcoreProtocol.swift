// GPL-3.0-or-later. Layouts and EQ encoding adapted from OpenSCQ30
// 200d9e1657dff67d516ed1b6347f312d7a1b01a7. See Licenses/OpenSCQ30.txt.
import Foundation

public struct SoundcoreFrame:Equatable,Sendable {
    /// First wire byte in the high half (01 01 -> 0x0101).
    public let command:UInt16
    public let payload:[UInt8]
    public init(_ command:UInt16,_ payload:[UInt8]=[]) { self.command=command;self.payload=payload }
}
public struct SoundcoreFrameCodec {
    private var buffer:[UInt8]=[]
    public init() {}
    public mutating func reset() { buffer=[] }
    public static func encode(_ frame:SoundcoreFrame,inbound:Bool=false) throws -> Data {
        guard frame.payload.count <= 4096 else { throw ProtocolError.invalidPayload }
        let length=frame.payload.count+10
        var b:[UInt8]=inbound ? [9,255,0,0,1] : [8,238,0,0,0]
        b += [UInt8(frame.command >> 8),UInt8(truncatingIfNeeded:frame.command),UInt8(truncatingIfNeeded:length),UInt8(length >> 8)]
        b += frame.payload;b.append(b.reduce(0,&+));return Data(b)
    }
    public mutating func feed(_ data:Data) -> [SoundcoreFrame] {
        var out:[SoundcoreFrame]=[]
        for byte in data {
            buffer.append(byte)
            while !buffer.isEmpty {
                guard buffer[0] == 9 else { buffer.removeFirst();continue }
                guard buffer.count >= 9 else { break }
                let n=Int(buffer[7]) | Int(buffer[8]) << 8
                guard buffer.prefix(5).elementsEqual([9,255,0,0,1]),(10...4106).contains(n) else { buffer.removeFirst();continue }
                guard buffer.count >= n else { break }
                guard buffer.prefix(n-1).reduce(0,&+) == buffer[n-1] else { buffer.removeFirst();continue }
                out.append(SoundcoreFrame(UInt16(buffer[5]) << 8 | UInt16(buffer[6]),Array(buffer[9..<n-1])))
                buffer.removeFirst(n)
            }
        }
        return out
    }
}

public enum SoundcoreProfile:String,CaseIterable,Sendable {
    case q30="A3028",q35="A3027",q45="A3040",spaceOnePro="A3062",liberty4NC="A3947",liberty4Pro="A3954",liberty5="A3957"
    public static let service="00001101-0000-1000-8000-00805F9B34FB"
    public static func isVendorService(_ bytes:Data) -> Bool {
        let prefix:[UInt8]=[0x0C,0xF1,0x2D,0x31,0xFA,0xC3,0x45,0x53,0xBD,0x80,0xD6,0x83,0x2E]
        return bytes.count == 16 && bytes.prefix(13).elementsEqual(prefix) && bytes[bytes.startIndex+13] & 0xF0 == 0x70
    }
    public var modelID:String { "soundcore:"+rawValue.lowercased() }
    public var displayName:String {
        switch self { case .q30:return "Soundcore Life Q30";case .q35:return "Soundcore Life Q35";case .q45:return "Soundcore Space Q45";case .spaceOnePro:return "Soundcore Space One Pro";case .liberty4NC:return "Soundcore Liberty 4 NC";case .liberty4Pro:return "Soundcore Liberty 4 Pro";case .liberty5:return "Soundcore Liberty 5" }
    }
    public static func named(_ name:String) -> Self? {
        let n=EarbudFamily.normalize(name)
        return allCases.first { p in
            let bare=p.displayName.replacingOccurrences(of:"Soundcore ",with:"")
            return [p.displayName,"Anker "+p.displayName,bare,"Soundcore "+bare.replacingOccurrences(of:"Life ",with:""),p.rawValue].contains { EarbudFamily.normalize($0) == n }
        }
    }
    public var singleBattery:Bool { [.q30,.q35,.q45,.spaceOnePro].contains(self) }
    public var oldEQ:Bool { self == .q30 || self == .q35 }
    public var minimumStatusLength:Int {
        switch self { case .q30:return 60;case .q35:return 61;case .q45:return 135;case .spaceOnePro:return 87;case .liberty4NC:return 150;case .liberty4Pro:return 165;case .liberty5:return 154 }
    }
    public var noiseRange:Range<Int> {
        switch self { case .q30,.q35:return 35..<39;case .q45:return 49..<55;case .spaceOnePro:return 69..<75;case .liberty4NC:return 118..<125;case .liberty4Pro:return 125..<129;case .liberty5:return 119..<126 }
    }
    private var eqOffset:Int { switch self { case .q30,.q35:return 2;case .q45,.spaceOnePro:return 23;case .liberty4NC:return 37;case .liberty4Pro:return 44;case .liberty5:return 38 } }
    private var hearRange:Range<Int> { switch self { case .q30,.q35:return 14..<35;case .q45:return 77..<135;case .spaceOnePro:return 37..<65;case .liberty4NC:return 60..<108;case .liberty4Pro:return 67..<115;case .liberty5:return 61..<109 } }
    public var dualOffset:Int? { switch self { case .q30,.q35:return nil;case .q45:return 62;case .spaceOnePro:return 79;case .liberty4NC:return 139;case .liberty4Pro:return 142;case .liberty5:return 130 } }
    public static let frequencies:[UInt16]=[100,200,400,800,1600,3200,6400,12800]
    public func snapshot(_ p:[UInt8]) -> SoundcoreSnapshot? {
        guard p.count >= minimumStatusLength,p.count <= 512 else { return nil }
        let firmwareOffset=oldEQ ? 39 : singleBattery ? 2 : 6
        let fw=Array(p[firmwareOffset..<firmwareOffset+5])
        guard fw[2] == 46,[0,1,3,4].allSatisfy({ (48...57).contains(fw[$0]) }) else { return nil }
        let rawNoise=Array(p[noiseRange]);guard rawNoise[0] <= (self == .liberty4Pro ? 3 : 2) else { return nil }
        var state=DeviceState();state.productID=modelID;state.firmware=String(bytes:fw,encoding:.ascii)
        func battery(_ value:UInt8,_ slot:BatterySlot,_ max:Int,_ offset:Int=0,_ charge:UInt8=0) {
            guard Int(value)+offset <= max else { return }
            state.batteries[slot]=BatteryReading(percent:(Int(value)+offset)*100/max,charging:charge == 1)
        }
        if singleBattery { battery(p[0],.left,self == .spaceOnePro ? 10 : 5,self == .spaceOnePro ? 1 : 0,self == .q45 ? 0 : p[1]) }
        else {
            let max=self == .liberty4Pro ? 100 : self == .liberty5 ? 10 : 5
            battery(p[2],.left,max,self == .liberty5 ? 1 : 0,p[4]);battery(p[3],.right,max,self == .liberty5 ? 1 : 0,p[5])
            battery(p[self == .liberty4NC ? 131 : 37],.enclosure,self == .liberty4NC ? 5 : 10,self == .liberty4NC ? 0 : 1)
        }
        state.noise=[NoiseMode.anc,.transparency,.off,.anc][Int(rawNoise[0])]
        state.observedQueries.formUnion([Command.battery,Command.noise,Command.firmware])
        let bands=oldEQ ? 8 : 10,channels=singleBattery ? 1 : 2
        let id=UInt16(p[eqOffset]) | UInt16(p[eqOffset+1]) << 8
        let curves=Array(p[eqOffset+2..<eqOffset+2+bands*channels]),hear=Array(p[hearRange])
        // Preserve fractional gains internally; the existing editor displays whole dB.
        let valid=curves.prefix(8).allSatisfy { (60...180).contains($0) }
        if valid {
            state.eq=id == 0xFEFE ? 254 : UInt8(exactly:id)
            state.customEQ=[CustomEQEntry(id:254,name:"Custom",selected:id == 0xFEFE,frequencies:Self.frequencies,gains:curves.prefix(8).map { Int8((Double(Int($0)-120)/10).rounded()) })]
            state.observedQueries.formUnion([Command.equalizer,Command.customEQ])
        }
        if let offset=dualOffset,p[offset] <= 1 { state.switches[0x11]=p[offset] == 1;state.observedQueries.insert(Command.switches) }
        let spatialActive=self == .liberty4Pro && p[148] != 0
        return SoundcoreSnapshot(state:state,noise:rawNoise,equalizerID:id,curves:curves,hear:hear,eqWritable:valid && hear.first == 0 && !spatialActive)
    }
    public func noiseWrite(_ mode:NoiseMode,snapshot:SoundcoreSnapshot) throws -> SoundcoreFrame {
        guard let byte:UInt8=[NoiseMode.anc:0,.transparency:1,.off:2][mode],snapshot.noise.count == noiseRange.count else { throw ProtocolError.unsupported }
        var b=snapshot.noise;b[0]=byte
        return SoundcoreFrame(0x0681,b)
    }
    public func equalizerWrite(id:UInt16,curve:[UInt8],snapshot:SoundcoreSnapshot) throws -> SoundcoreFrame {
        let bands=oldEQ ? 8 : 10,channels=singleBattery ? 1 : 2
        guard snapshot.eqWritable,curve.count == bands,curve.prefix(8).allSatisfy({ (60...180).contains($0) }) else { throw ProtocolError.unsupported }
        let identifier=[UInt8(truncatingIfNeeded:id),UInt8(id >> 8)]
        if oldEQ { return SoundcoreFrame(0x0281,identifier+curve) }
        let h=snapshot.hear,hearChannels=self == .q45 ? 2 : channels,n=hearChannels*10
        guard h.count == hearRange.count,h[0] == 0 else { throw ProtocolError.invalidPayload }
        let genre=Array(h.suffix(2)),base=Array(h.prefix(6+2*n))
        let eq=Array(repeating:curve,count:channels).flatMap { $0 }
        var b=identifier+genre
        if self == .q45 {
            b += curve+curve+[0,1]+Array(base.prefix(26))+Array(base[26..<36])+Array(base[26..<36])
            b += Self.drc(curve)+Self.drc(curve)+[0]
        } else {
            b += eq+[0,0]+base
            if self == .liberty4Pro || self == .liberty5 { b += eq.flatMap { [$0,0] }+[0,0] }
            else if self == .liberty4NC { b += Self.drc(curve)+Self.drc(curve)+[0] }
            else { b += eq+[0] }
        }
        return SoundcoreFrame(0x0387,b)
    }
    /// OpenSCQ30's eight-band DRC matrix; final two bands are internal placeholders.
    private static func drc(_ bytes:[UInt8]) -> [UInt8] {
        let s=0.85,l=0.95
        let m:[[Double]]=[
            [1.26,-0.71*s,0.177,-0.0494,0.0345,-0.0197,0.0075,-0.00217],
            [-0.71*s,1.73*l,-0.81*s,0.204,-0.068,0.045,-0.0235,0.0075],
            [0.177,-0.81*s,1.73*l,-0.81*s,0.208,-0.07,0.045,-0.0197],
            [-0.0494,0.204,-0.81*s,1.73*l,-0.82*s,0.208,-0.068,0.0345],
            [0.0345,-0.068,0.208,-0.82*s,1.73*l,-0.81*s,0.204,-0.0494],
            [-0.0197,0.045,-0.07,0.208,-0.81*s,1.73*l,-0.81*s,0.177],
            [0.0075,-0.0235,0.045,-0.068,0.204,-0.81*s,1.83*l,-0.71*s],
            [-0.00217,0.0075,-0.0197,0.0345,-0.0494,0.177,-0.71*s,1.5]]
        return m.map { row in UInt8(clamping:Int(zip(row,bytes.prefix(8)).reduce(0.0) { $0+$1.0*Double(Int($1.1)-120)/10 }.rounded())+120) }+[120,0]
    }
}
public struct SoundcoreSnapshot:Sendable {
    public var state:DeviceState
    public let noise:[UInt8],equalizerID:UInt16,curves:[UInt8],hear:[UInt8]
    public let eqWritable:Bool
}
