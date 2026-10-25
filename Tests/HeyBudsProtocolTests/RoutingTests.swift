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
