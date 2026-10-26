import Testing
import HeyBudsProtocol

@Test func modelOverrideNeverChangesDetectedWireFamily() throws {
    let catalog=try ModelCatalog()
    #expect(catalog.family(name:"FreeBuds Pro 3",override:"06EC10") == .huawei)
    #expect(catalog.validOverride("06EC10",family:.huawei) == nil)
    #expect(catalog.validOverride("06EC10",family:.oppo) == "06EC10")
    #expect(catalog.validOverride("06EC10",family:nil) == nil)
}

@Test func routingUsesServiceEvidenceWithoutGuessingUnknownDevices() throws {
    let catalog=try ModelCatalog()
    #expect(catalog.routingFamily(name:"Personal headphones",services:[.oppo]) == .oppo)
    #expect(catalog.routingFamily(name:"Personal headphones",services:[.huawei]) == nil)
    #expect(catalog.routingFamily(name:"FreeBuds Pro 3",services:[.huawei]) == .huawei)
    #expect(catalog.routingFamily(name:"FreeBuds Pro 3",services:[.vivo]) == .vivo)
    #expect(catalog.routingFamily(name:"Personal headphones",services:[.oppo,.vivo]) == nil)
}

@Test func expansionUsesOnlyModelSpecificControlRoutes() throws {
    let catalog=try ModelCatalog()
    #expect(catalog.models.count == 228)
    #expect(EarbudFamily.oppo.transportKinds(for:"OPPO Enco X4") == ["RFCOMM","BLE"])
    #expect(EarbudFamily.bose.transportKinds(for:"Bose QuietComfort Ultra Earbuds (2nd Gen)") == ["BLE"])
    #expect(EarbudFamily.bose.transportKinds(for:"Bose QuietComfort 45") == ["RFCOMM"])
    for name in ["WH-1000XM3","Sony WH-1000XM4"] {
        #expect(EarbudFamily.sony.serviceUUID(for:name) == SonyProtocol.serviceV1)
    }
    for name in ["WH-1000XM5","WH-XB910N","ULT WEAR","WH-ULT900N"] {
        #expect(EarbudFamily.sony.serviceUUID(for:name) == SonyProtocol.serviceV2)
    }
    let added=catalog.models.filter { [.samsung,.google,.bose,.nothing].contains($0.family) }
    #expect(added.count == 12)
    for model in added {
        #expect(catalog.validOverride(model.id,family:model.family) == nil)
        for name in [model.name]+model.aliases {
            #expect(catalog.family(name:name) == model.family)
            if model.family == .bose { #expect(BoseProfile.named(name)?.modelID == model.id) }
            if model.family == .nothing { #expect(NothingProfile.named(name)?.modelID == model.id) }
            if model.family == .samsung { #expect(SamsungProfile.named(name)?.modelID == model.id) }
        }
    }
    for name in ["Galaxy Buds2 FE","Pixel Buds A-Series","Bose QuietComfort Ultra Earbuds","Nothing Ear (2)","CMF Buds 2 Plus"] {
        #expect(catalog.model(productID:nil,name:name) == nil)
        #expect(catalog.family(name:name) == nil)
    }
}
