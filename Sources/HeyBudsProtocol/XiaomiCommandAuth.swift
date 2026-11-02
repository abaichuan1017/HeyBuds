// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Mutual 50/51 command authentication. A generic ACK or a correct answer to
/// our challenge alone is insufficient: the peer must finish its challenge too.
public struct XiaomiCommandAuth:Sendable {
    public private(set) var ready=false
    private let type:UInt8,sequence:UInt8,challenge:[UInt8]
    private var validated=false,answeredPeer=false,started=false
    public init(type:UInt8=0xC4,sequence:UInt8,challenge:[UInt8]) throws {
        guard challenge.count == 16,type & 0xC0 == 0xC0 else { throw ProtocolError.invalidPayload }
        self.type=type;self.sequence=sequence;self.challenge=challenge
    }
    public mutating func start() throws -> XiaomiFrame {
        guard !started else { throw ProtocolError.invalidPayload };started=true
        return XiaomiFrame(type:type,opcode:0x50,sequence:sequence,payload:[1]+challenge)
    }
    public mutating func receive(_ frame:XiaomiFrame) throws -> XiaomiFrame? {
        guard started,!ready,[UInt8(0),4,7].contains(frame.type & 7) else { return nil }
        let role=type & 7
        if !frame.isRequest {
            guard frame.type & 7 == role || frame.type & 7 == 7 else { return nil }
            if frame.opcode == 0x50,frame.sequence == sequence {
                guard frame.status == 0,frame.payload.count == 17,frame.payload[0] == 1,
                      XiaomiMMAAuth.matches(Array(frame.payload.dropFirst()),challenge:challenge) else { throw ProtocolError.invalidPayload }
                validated=true
                return XiaomiFrame(type:type,opcode:0x51,sequence:sequence &+ 1,payload:[1,0])
            }
            if frame.opcode == 0x51,frame.sequence == sequence &+ 1 {
                guard validated,frame.status == 0,frame.payload == [1] else { throw ProtocolError.invalidPayload }
            }
            return nil
        }
        if frame.opcode == 0x50 {
            guard validated,frame.payload.count == 17,frame.payload[0] == 1,!answeredPeer else { throw ProtocolError.invalidPayload }
            answeredPeer=true
            return frame.reply([1]+(try XiaomiMMAAuth.response(Array(frame.payload.dropFirst()))),type:role)
        }
        if frame.opcode == 0x51 {
            guard validated,answeredPeer,frame.payload == [1,0] else { throw ProtocolError.invalidPayload }
            ready=true;return frame.reply([1],type:role)
        }
        return nil
    }
}
