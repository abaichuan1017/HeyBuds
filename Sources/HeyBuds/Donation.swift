import Foundation

struct DonationOption:Identifiable,Hashable {
    let amount:Int
    let codeURL:URL
    var id:Int { amount }
    // Each amount has its own Alipay-generated fixed-amount collection link.
    static let options:[Self]=[
        .init(amount:5,codeURL:URL(string:"https://qr.alipay.com/fkx12198ywuha6el3aklu78")!),
        .init(amount:10,codeURL:URL(string:"https://qr.alipay.com/fkx13898qxyomsojrmobnb3")!),
        .init(amount:20,codeURL:URL(string:"https://qr.alipay.com/fkx149421bwhmb000onrb75")!),
        .init(amount:50,codeURL:URL(string:"https://qr.alipay.com/fkx10550n4a40obpw0pzhfa")!),
    ]
    var appURL:URL {
        var url=URLComponents(string:"alipays://platformapi/startapp")!
        url.queryItems=[URLQueryItem(name:"saId",value:"10000007"),URLQueryItem(name:"qrcode",value:codeURL.absoluteString)]
        return url.url!
    }
}
