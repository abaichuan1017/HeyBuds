import Foundation
import Testing
import Vision
@testable import HeyBuds

@Test func donationAmountsKeepTheirOriginalCollectionLinks() throws {
    let options=DonationOption.options
    #expect(options.map(\.amount) == [5,10,20,50,nil])
    #expect(Set(options.map(\.codeURL)).count == options.count)
    #expect(options.map(\.codeURL.absoluteString) == [
        "https://qr.alipay.com/fkx12198ywuha6el3aklu78",
        "https://qr.alipay.com/fkx13898qxyomsojrmobnb3",
        "https://qr.alipay.com/fkx149421bwhmb000onrb75",
        "https://qr.alipay.com/fkx10550n4a40obpw0pzhfa",
        "https://qr.alipay.com/tsx11273jnkqrfo5occo9c1",
    ])
}

@Test(arguments:DonationOption.options)
func donationQRCodesDecodeToTheSelectedPaymentURL(option:DonationOption) throws {
    let image=try #require(option.makeQRCode())
    #expect(image.width == image.height && image.width >= 222)
    let request=VNDetectBarcodesRequest()
    request.symbologies=[.qr]
    try VNImageRequestHandler(cgImage:image).perform([request])
    #expect(request.results?.map(\.payloadStringValue) == [option.codeURL.absoluteString])
}
