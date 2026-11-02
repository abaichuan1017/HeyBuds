// GAIA v3 subset from momentum4-control (MIT), 17aeea90.
// Copyright (c) 2026 Ariazonaa. See Licenses/Momentum-MIT.txt.
import Foundation

public struct SennheiserFrame:Equatable,Sendable {
    public let vendor:UInt16,command:UInt16
    public let payload:[UInt8]
    public init(_ command:UInt16,_ payload:[UInt8]=[],vendor:UInt16=0x0495) { self.command=command;self.payload=payload;self.vendor=vendor }
}
public struct SennheiserFrameCodec {
    private var buffer:[UInt8]=[]
    public init() {}
    public mutating func reset() { buffer=[] }
    public static func encode(_ frame:SennheiserFrame) throws -> Data {
        guard frame.payload.count <= 255 else { throw ProtocolError.invalidPayload }
        return Data([255,3,0,UInt8(frame.payload.count),UInt8(frame.vendor >> 8),UInt8(truncatingIfNeeded:frame.vendor),UInt8(frame.command >> 8),UInt8(truncatingIfNeeded:frame.command)]+frame.payload)
    }
    public mutating func feed(_ data:Data) -> [SennheiserFrame] {
        var frames:[SennheiserFrame]=[]
        for byte in data {
            buffer.append(byte)
            while !buffer.isEmpty {
                guard buffer[0] == 255 else { buffer.removeFirst();continue }
                guard buffer.count >= 4 else { break }
                guard [UInt8(1),3,4].contains(buffer[1]),buffer[2] <= 3 else { buffer.removeFirst();continue }
                let long=buffer[2] & 2 != 0,h=long ? 5 : 4
                guard buffer.count >= h else { break }
                let count=long ? Int(buffer[3]) << 8 | Int(buffer[4]) : Int(buffer[3]),crc=buffer[2] & 1 != 0
                guard count <= 4096 else { buffer.removeFirst();continue }
                let total=h+4+count+(crc ? 1 : 0)
                guard buffer.count >= total else { break }
                guard !crc || buffer.prefix(total).reduce(0,^) == 0 else { buffer.removeFirst();continue }
                frames.append(SennheiserFrame(UInt16(buffer[h+2]) << 8 | UInt16(buffer[h+3]),Array(buffer[h+4..<h+4+count]),vendor:UInt16(buffer[h]) << 8 | UInt16(buffer[h+1])))
                buffer.removeFirst(total)
            }
        }
        return frames
    }
}
public enum SennheiserProfile:String,CaseIterable,Sendable {
    case momentum4="M4AEBT",momentum5="M5AEBT"
    public static let service="A2129FF3-081B-4C45-8AFE-469D9C4842EC"
    public var modelID:String { self == .momentum4 ? "sennheiser:momentum4" : "sennheiser:momentum5" }
    public static func named(_ name:String) -> Self? {
        let n=EarbudFamily.normalize(name)
        return allCases.first { p in
            let digit=p == .momentum4 ? "4" : "5"
            return ["MOMENTUM "+digit,"MOMENTUM "+digit+" Wireless","Sennheiser MOMENTUM "+digit,"Sennheiser MOMENTUM "+digit+" Wireless",p.rawValue].contains { EarbudFamily.normalize($0) == n }
        }
    }
    public func matchesIdentity(_ payload:[UInt8]) -> Bool {
        guard let text=Self.text(payload,limit:128) else { return false }
        return text == rawValue || (text.hasPrefix(rawValue+" ") && text.dropFirst(rawValue.count+1).allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == " " || $0 == "-") })
    }
    public func allowsWrite(firmware:String?) -> Bool {
        guard let firmware,Self.version(firmware) != nil else { return false }
        return self == .momentum4 || firmware == "6.21.5"
    }
    public static func version(_ string:String) -> [Int]? {
        let parts=string.split(separator:".",omittingEmptySubsequences:false)
        guard parts.count == 3 else { return nil }
        let values=parts.compactMap { part -> Int? in guard !part.isEmpty,part.allSatisfy({ $0.isASCII && $0.isNumber }),let n=Int(part),(0...65535).contains(n) else { return nil };return n }
        return values.count == 3 ? values : nil
    }
    public static func firmware(_ p:[UInt8]) -> String? {
        guard p.count == 6 else { return nil }
        return stride(from:0,to:6,by:2).map { String(Int(p[$0]) << 8 | Int(p[$0+1])) }.joined(separator:".")
    }
    public static func boolean(_ p:[UInt8]) -> Bool? { p.count == 1 && p[0] <= 1 ? p[0] == 1 : nil }
    public static func text(_ p:[UInt8],limit:Int) -> String? {
        guard !p.isEmpty,p.count <= limit else { return nil }
        let b=p.prefix { $0 != 0 }
        guard p.dropFirst(b.count).allSatisfy({ $0 == 0 }),let s=String(bytes:b,encoding:.utf8),!s.isEmpty,s.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil };return s
    }
    /// A protocol index is a session-local identity, never a fabricated MAC.
    public static func peer(_ p:[UInt8],index:UInt8,current:UInt8) -> RemoteHost? {
        guard p.count >= 4,p[0] == index,p[2] <= 1,let name=text(Array(p.dropFirst(3)),limit:128) else { return nil }
        return RemoteHost(address:[],name:name,type:0,connection:p[2] == 1 ? 2 : 0,flags:index == current ? 1 : 0,protocolIndex:index)
    }
}
