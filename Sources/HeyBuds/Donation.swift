import Foundation
import CoreImage.CIFilterBuiltins

struct DonationOption:Identifiable,Hashable {
    let amount:Int?
    let codeURL:URL
    var id:URL { codeURL }
    var label:String { amount.map { "¥\($0)" } ?? L("任意金额","Any amount") }
    // Each amount has its own Alipay-generated fixed-amount collection link.
    static let options:[Self]=[
        .init(amount:5,codeURL:URL(string:"https://qr.alipay.com/fkx12198ywuha6el3aklu78")!),
        .init(amount:10,codeURL:URL(string:"https://qr.alipay.com/fkx13898qxyomsojrmobnb3")!),
        .init(amount:20,codeURL:URL(string:"https://qr.alipay.com/fkx149421bwhmb000onrb75")!),
        .init(amount:50,codeURL:URL(string:"https://qr.alipay.com/fkx10550n4a40obpw0pzhfa")!),
        .init(amount:nil,codeURL:URL(string:"https://qr.alipay.com/tsx11273jnkqrfo5occo9c1")!),
    ]

    /// Encode the original collection URL without adding or changing amount parameters.
    func makeQRCode() -> CGImage? {
        let filter=CIFilter.qrCodeGenerator()
        filter.message=Data(codeURL.absoluteString.utf8)
        filter.correctionLevel="M"
        guard let code=filter.outputImage else { return nil }
        // Four white modules on every side keep the code readable in either appearance.
        let bounds=code.extent.insetBy(dx:-4,dy:-4)
        let background=CIImage(color:.white).cropped(to:bounds)
        let image=code.composited(over:background).transformed(by:CGAffineTransform(scaleX:6,y:6))
        return CIContext(options:[.useSoftwareRenderer:true]).createCGImage(image,from:image.extent)
    }
}
