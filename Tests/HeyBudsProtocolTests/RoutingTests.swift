import Testing
import HeyBudsProtocol

@Test func indexedModelsAndManualChoicesMatchTheCatalog() throws {
    let catalog=try ModelCatalog()
    for model in catalog.models {
        #expect(catalog.model(id:model.id)?.raw == model.raw)
    }
    #expect(catalog.model(id:"unknown") == nil)
    let automaticXiaomiIDs=Set(XiaomiProfile.allCases.map(\.modelID))
    for family in EarbudFamily.allCases {
        let expected=catalog.models.filter {
            family.allowsModelOverride && $0.family == family && !automaticXiaomiIDs.contains($0.id)
        }.sorted { $0.name < $1.name }.map(\.id)
        #expect(catalog.overrideModels(for:family).map(\.id) == expected)
    }
}

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

@Test func samsungShortNamesRequireTheMatchingServiceAndAnExactModel() throws {
    let catalog = try ModelCatalog()
    for name in ["Buds4 Pro", "テストの Buds4 Pro", "测试的Buds4 Pro (A1b2)", "Test’s Buds4 Pro",
                 "Test's Buds 4 Pro", "테스트의 Buds4 Pro"] {
        #expect(SamsungProfile.named(name) == nil)
        #expect(catalog.routingFamily(name:name,services:[]) != .samsung)
        #expect(SamsungProfile.named(name,on:SamsungProfile.service.lowercased()) == .buds4Pro)
        #expect(EarbudFamily.samsung.serviceUUID(for:name) == nil)
    }
    for name in ["Test’s Redmi Buds 4 Pro", "テストの Pixel Buds Pro", "Buds4 Pro Max", "Buds5 Pro",
                 "Buds2 FE", "Buds4 Pro (test)", "Personal headphones", "Galaxy Buds"] {
        #expect(SamsungProfile.named(name,on:SamsungProfile.service) == nil)
    }
    #expect(SamsungProfile.named("Test’s Galaxy Buds4 Pro",on:SamsungProfile.service) == .buds4Pro)
    #expect(SamsungProfile.named("Samsung Galaxy Buds+ (A1B2)") == .budsPlus)
    #expect(SamsungProfile.named("Galaxy Buds",on:SamsungProfile.legacyService) == .buds)
    #expect(SamsungProfile.named("Galaxy Buds4 Pro",on:SamsungProfile.legacyService) == nil)
    let bothServices = [SamsungProfile.service, SamsungProfile.legacyService]
    #expect(EarbudFamily.samsung.serviceUUID(for:"Galaxy Buds",among:bothServices) == SamsungProfile.legacyService)
    #expect(EarbudFamily.samsung.serviceUUID(for:"Personal headphones",among:bothServices) == nil)
}

@Test func expansionUsesOnlyModelSpecificControlRoutes() throws {
    let catalog=try ModelCatalog()
    #expect(catalog.models.count == 283)
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
    #expect(added.count == 31)
    for model in added {
        #expect(catalog.validOverride(model.id,family:model.family) == nil)
        for name in [model.name]+model.aliases {
            #expect(catalog.family(name:name) == model.family)
            if model.family == .bose { #expect(BoseProfile.named(name)?.modelID == model.id) }
            if model.family == .nothing { #expect(NothingProfile.named(name)?.modelID == model.id) }
            if model.family == .samsung { #expect(SamsungProfile.named(name)?.modelID == model.id) }
        }
    }
    for name in ["Galaxy Buds2 FE","Pixel Buds A-Series","Bose QuietComfort Ultra Earbuds","CMF Buds 2 Plus"] {
        #expect(catalog.model(productID:nil,name:name) == nil)
        #expect(catalog.family(name:name) == nil)
    }
}
