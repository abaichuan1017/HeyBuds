import Foundation
import HeyBudsProtocol

/// MDR V2 Table 1 only. V1, OTA, power-off and arbitrary commands are not exposed.
@MainActor final class SonySession {
    private(set) var state=DeviceState()
    private(set) var model:DeviceModel?
    private(set) var ready=false
    var interactive=false
    var onChange:(() -> Void)?
    var onClose:((String?) -> Void)?
    var onDiagnostic:((String) -> Void)?
    private let transport:EarbudTransport
    private let catalog:ModelCatalog
    private let timeout:Double
    private var generation=UUID()
    private var active=false
    private var verifiedV2=false
    private var functions:Set<UInt8>=[]
    private var noiseAvailable=true
    private var codec=SonyFrameCodec()
    private let requests=RequestGate()
    private let writes=RequestGate()
    private var sequence:UInt8=0
    private var lastReceived:SonyFrame?
    private var acknowledgements:[SonyFrame]=[]
    private var ackTask:Task<Void,Never>?
    private var poll:Task<Void,Never>?
    private var lastBattery=Date.distantPast
    private var lastNoise=Date.distantPast

    @MainActor private final class Pending {
        let exchange=AsyncExchange<SonyFrame?>()
        let sequence:UInt8
        let opcode:UInt8?
        let subtype:UInt8?
        var started=false
        var acknowledged=false
        var response:SonyFrame?
        init(sequence:UInt8,opcode:UInt8?,subtype:UInt8?) {
            self.sequence=sequence;self.opcode=opcode;self.subtype=subtype
        }
        func completeIfReady() {
            if acknowledged && (opcode == nil || response != nil) { exchange.receive(.success(response)) }
        }
    }
    private var pending:Pending?

    init(transport:EarbudTransport,name:String,catalog:ModelCatalog,timeout:Double=3) {
        self.transport=transport;self.catalog=catalog;self.timeout=timeout
        let named=catalog.model(productID:nil,name:name)
        model=SonyProtocol.supportsModel(named) ? named : nil
    }
    func open() async throws {
        let token=generation;active=true
        transport.onEvent={ [weak self] event in
            guard let self,self.generation == token,self.active else { return }
            switch event { case .data(let data):self.receive(data);case .closed(let reason):self.fail(reason) }
        }
        do {
            try await transport.open()
            guard generation == token else { throw ProtocolError.disconnected }
            let handshake=try await read([0,0],reply:1)
            guard SonyProtocol.validHandshake(handshake.payload) else { throw ProtocolError.unsupported }
            verifiedV2=true
            let identity=try await read([4,1],reply:5)
            guard let name=SonyProtocol.deviceText(identity.payload,type:1),
                  let identified=catalog.model(productID:nil,name:name),SonyProtocol.supportsModel(identified) else { throw ProtocolError.unsupported }
            // Device-reported identity wins over names and all manual overrides.
            model=identified;state.productID=identified.id
            let firmware=try await read([4,2],reply:5)
            guard let version=SonyProtocol.deviceText(firmware.payload,type:2) else { throw ProtocolError.invalidPayload }
            state.firmware=version;state.observedQueries.insert(Command.firmware)
            let supported=try await read([6,0],reply:7)
            guard let functions=SonyProtocol.functions(supported.payload) else { throw ProtocolError.invalidPayload }
            self.functions=functions
            try Task.checkCancellation()
            guard generation == token else { throw ProtocolError.disconnected }
            ready=true;onChange?();onDiagnostic?("Sony MDR V2 identity and functions verified")
        } catch { if generation == token { close() };throw error }
    }
    func initialize() async {
        let token=generation
        await refresh()
        guard ready,generation == token,!Task.isCancelled else { return }
        poll?.cancel()
        poll=Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for:.seconds(1)) } catch { return }
                guard let self,self.ready,self.generation == token else { return }
                if Date().timeIntervalSince(self.lastBattery) >= (self.interactive ? 10 : 40) { try? await self.readBatteries() }
                guard self.ready,self.generation == token,!Task.isCancelled else { return }
                if Date().timeIntervalSince(self.lastNoise) >= (self.interactive ? 5 : 40),self.canQuery(Command.noise) { _ = try? await self.read([0x66,0x17],reply:0x67) }
                guard self.ready,self.generation == token,!Task.isCancelled else { return }
                let stale=self.state.batteries.filter { Date().timeIntervalSince($0.value.updatedAt) >= 120 }.map(\.key)
                for slot in stale { self.state.batteries.removeValue(forKey:slot) }
                if !stale.isEmpty { self.onChange?() }
            }
        }
    }
    func refresh() async {
        guard ready,!Task.isCancelled else { return }
        let token=generation
        try? await readBatteries()
        if ready,generation == token,canQuery(Command.noise),!Task.isCancelled { _ = try? await read([0x66,0x17],reply:0x67) }
    }
    private func readBatteries() async throws {
        guard ready,let model else { return }
        let token=generation
        for subtype in SonyProtocol.batteryQueries(functions:functions,single:model.singleBattery) {
            guard generation == token,!Task.isCancelled else { throw ProtocolError.disconnected }
            _ = try await read([0x22,subtype],reply:0x23)
        }
        guard generation == token,!Task.isCancelled else { throw ProtocolError.disconnected }
        lastBattery=Date()
    }
    func canQuery(_ command:UInt16) -> Bool {
        guard verifiedV2,model != nil else { return false }
        switch command {
        case Command.battery:return !SonyProtocol.batteryQueries(functions:functions,single:model!.singleBattery).isEmpty
        case Command.noise:return functions.contains(0x6B)
        case Command.firmware:return true
        default:return false
        }
    }
    func canWrite(_ command:UInt16,reading:UInt16?=nil) -> Bool {
        ready && command == Command.setNoise && (reading == nil || reading == Command.noise)
            && functions.contains(0x6B) && noiseAvailable && state.sonyNoise?.settled == true
    }
    func setNoise(_ mode:NoiseMode) async throws -> WriteOutcome {
        guard let current=state.sonyNoise else { throw ProtocolError.unsupported }
        return try await writeNoise(mode:mode,level:current.ambientLevel,voice:current.focusOnVoice)
    }
    func setAmbient(level:Int,focusOnVoice:Bool) async throws -> WriteOutcome {
        guard state.noise == .transparency else { throw ProtocolError.unsupported }
        return try await writeNoise(mode:.transparency,level:level,voice:focusOnVoice)
    }
    private func writeNoise(mode:NoiseMode,level:Int,voice:Bool) async throws -> WriteOutcome {
        guard canWrite(Command.setNoise) else { throw ProtocolError.unsupported }
        let payload=try SonyProtocol.noiseWrite(mode:mode,level:level,voice:voice),token=generation
        _ = try await request(payload,reply:nil)
        guard ready,generation == token else { throw ProtocolError.disconnected }
        for attempt in 0..<6 {
            let reply=try await read([0x66,0x17],reply:0x67)
            try Task.checkCancellation()
            guard ready,generation == token else { throw ProtocolError.disconnected }
            guard let fresh=SonyProtocol.noise(reply.payload) else { throw ProtocolError.invalidPayload }
            if fresh.settled,fresh.mode == mode,fresh.ambientLevel == level,fresh.focusOnVoice == voice { return .confirmed }
            // The ACK can precede the physical mode transition. Only another
            // complete GET response may confirm it; notifications/cache cannot.
            if attempt < 5 { try await Task.sleep(for:.milliseconds(200)) }
            guard ready,generation == token else { throw ProtocolError.disconnected }
        }
        throw ProtocolError.readbackMismatch
    }
    private func read(_ payload:[UInt8],reply:UInt8) async throws -> SonyFrame {
        guard let frame=try await request(payload,reply:reply) else { throw ProtocolError.invalidPayload }
        return frame
    }
    private func request(_ payload:[UInt8],reply:UInt8?) async throws -> SonyFrame? {
        let token=generation
        try await requests.acquire();defer { requests.release() }
        try Task.checkCancellation()
        guard active,generation == token else { throw ProtocolError.disconnected }
        guard verifiedV2 || payload == [0,0] else { throw ProtocolError.unsupported }
        let p=Pending(sequence:sequence,opcode:reply,subtype:payload.count > 1 ? payload[1] : nil)
        pending=p;defer { if pending === p { pending=nil } }
        do {
            return try await p.exchange.run(timeout:timeout,timeoutError:ProtocolError.timeout(UInt16(payload[0])),
                abortSend:{ [weak self] in self?.fail("Sony Bluetooth write did not complete") },send:{ [weak self] in
                    guard let self else { throw ProtocolError.disconnected }
                    try await self.send(SonyFrame(sequence:p.sequence,payload:payload),token:token,beforeSend:{ p.started=true })
                })
        } catch {
            // MDR has only one sequence bit. After a timeout/cancellation a late
            // response cannot safely be reused by another request on this channel.
            if generation == token { fail(error is CancellationError ? nil : error.localizedDescription) }
            throw error
        }
    }
    private func send(_ frame:SonyFrame?,token:UUID,beforeSend:(() -> Void)?=nil) async throws {
        try await writes.acquire();defer { writes.release() }
        try Task.checkCancellation()
        guard active,generation == token else { throw ProtocolError.disconnected }
        try await drainAcknowledgements(token:token)
        if let frame {
            beforeSend?();try await transport.send(SonyFrameCodec.encode(frame))
        }
        // ACK replies/notifications as soon as the current SDK write completes,
        // without waiting for the request queue or racing an RFCOMM write.
        try await drainAcknowledgements(token:token)
    }
    private func drainAcknowledgements(token:UUID) async throws {
        while !acknowledgements.isEmpty {
            try Task.checkCancellation()
            guard active,generation == token else { throw ProtocolError.disconnected }
            let frame=acknowledgements.removeFirst()
            try await transport.send(SonyFrameCodec.encode(frame))
        }
    }
    private func receive(_ bytes:Data) {
        for frame in codec.feed(bytes) {
            guard active else { return }
            if frame.type == 1 {
                guard frame.payload.isEmpty,let p=pending,p.started,!p.acknowledged,frame.sequence == p.sequence ^ 1 else { continue }
                sequence=frame.sequence;p.acknowledged=true;p.completeIfReady();continue
            }
            guard frame.type == 0x0C || frame.type == 0x0E else { continue }
            guard acknowledgements.count < 128 else { fail("Sony notification queue overflow");return }
            acknowledgements.append(SonyFrame(type:1,sequence:frame.sequence ^ 1))
            if ackTask == nil {
                let token=generation
                ackTask=Task { [weak self] in
                    guard let self else { return }
                    defer { if self.generation == token { self.ackTask=nil } }
                    do { try await self.send(nil,token:token) }
                    catch { if self.generation == token { self.fail(error.localizedDescription) } }
                }
            }
            // A retransmission still needs an ACK, but must not refresh state or
            // satisfy a later command. The receive sequence is independent of TX.
            guard frame != lastReceived else { continue }
            lastReceived=frame
            guard frame.type == 0x0C else { continue }
            let p=pending
            let matched=p?.started == true && frame.payload.first == p?.opcode &&
                frame.payload.count >= 2 && frame.payload[1] == p?.subtype
            if matched || [UInt8(0x25),0x65,0x69].contains(frame.payload.first ?? 0xFF) { apply(frame.payload) }
            if matched,p?.response == nil { p?.response=frame;p?.completeIfReady() }
        }
    }
    private func apply(_ payload:[UInt8]) {
        guard verifiedV2,model != nil else { return }
        if payload.count >= 2,[UInt8(0x23),0x25].contains(payload[0]),
           SonyProtocol.batteryQueries(functions:functions,single:model!.singleBattery).contains(payload[1]) {
            if SonyProtocol.applyBattery(payload,to:&state) { onChange?() }
        }
        if functions.contains(0x6B),let noise=SonyProtocol.noise(payload) {
            state.sonyNoise=noise;state.noise=noise.mode;state.observedQueries.insert(Command.noise)
            lastNoise=Date();onChange?()
        }
        if payload.count == 3,payload[0] == 0x65,payload[1] == 0x17,payload[2] <= 1 {
            noiseAvailable=payload[2] == 0;onChange?()
        }
    }
    private func fail(_ reason:String?) {
        guard active else { return }
        close();onClose?(reason)
    }
    func close() {
        ready=false;active=false;generation=UUID();verifiedV2=false
        poll?.cancel();poll=nil;ackTask?.cancel();ackTask=nil
        pending?.exchange.cancel();pending=nil
        transport.onEvent=nil;transport.close();codec.reset()
        acknowledgements.removeAll();lastReceived=nil;sequence=0
        functions.removeAll();noiseAvailable=true;state=DeviceState();onChange?()
        lastBattery = .distantPast;lastNoise = .distantPast
    }
}
