import Foundation
import Testing
@testable import HeyBuds

@Test func donationAmountsKeepSeparateCollectionLinksWhenOpeningAlipay() throws {
    let options=DonationOption.options
    #expect(options.map(\.amount) == [5,10,20,50])
    #expect(Set(options.map(\.codeURL)).count == options.count)
    for option in options {
        #expect(option.codeURL.host == "qr.alipay.com" && option.codeURL.path.hasPrefix("/fkx"))
        let app=try #require(URLComponents(url:option.appURL,resolvingAgainstBaseURL:false))
        #expect(app.scheme == "alipays" && app.host == "platformapi" && app.path == "/startapp")
        #expect(app.queryItems?.first(where:{$0.name == "saId"})?.value == "10000007")
        #expect(app.queryItems?.first(where:{$0.name == "qrcode"})?.value == option.codeURL.absoluteString)
    }
}
