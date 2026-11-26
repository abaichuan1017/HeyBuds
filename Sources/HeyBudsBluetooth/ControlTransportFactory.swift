import HeyBudsProtocol

@MainActor public enum ControlTransportFactory {
    public static func make(device:DeviceCandidate,family:EarbudFamily,kind:String) throws -> any EarbudTransport {
        guard !device.systemAudioOnly, family.transportKinds(for:device.protocolName).contains(kind) else { throw ProtocolError.unsupported }
        if family == .xiaomi,let profile=XiaomiProfile.named(device.protocolName) {
            if kind == "System",profile.systemBatteryOnly,let address=device.classicAddress {
                return XiaomiSystemBatteryTransport(address:address)
            }
            if kind == "BLE" { return BLETransport(name:device.name,profile:.xiaomi) }
            if kind == "RFCOMM",let address=device.classicAddress { return try RFCOMMTransport(address:address,xiaomi:profile) }
            throw ProtocolError.unsupported
        }
        if kind == "BLE" {
            if family == .oppo { return BLETransport(name:device.name) }
            if family == .bose,BoseProfile.named(device.protocolName)?.prefersBLE == true { return BLETransport(name:device.name,profile:.bose) }
            if family == .jbl,JBLProfile.named(device.protocolName)?.usesBLE == true { return BLETransport(name:device.name,profile:.jbl) }
            throw ProtocolError.unsupported
        }
        guard kind == "RFCOMM",let address=device.classicAddress else { throw ProtocolError.unsupported }
        if family == .soundcore,let profile=SoundcoreProfile.named(device.protocolName) { return try RFCOMMTransport(address:address,soundcore:profile) }
        if family == .jbl,let profile=JBLProfile.named(device.protocolName) { return try RFCOMMTransport(address:address,jbl:profile) }
        if family == .bose,let profile=BoseProfile.named(device.protocolName),profile.legacyNoise { return try RFCOMMTransport(address:address,bose:profile) }
        if family == .nothing,let profile=NothingProfile.named(device.protocolName),!profile.fastPairIDs.isEmpty {
            return try NothingVerifiedTransport(identity:RFCOMMTransport(address:address,serviceUUID:NothingProfile.identityService),
                                                control:RFCOMMTransport(address:address,serviceUUID:profile.serviceUUID),profile:profile)
        }
        guard let service=device.controlServiceUUID ?? family.serviceUUID(for:device.protocolName) else { throw ProtocolError.unsupported }
        return try RFCOMMTransport(address:address,serviceUUID:service)
    }
}
