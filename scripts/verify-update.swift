import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import CryptoKit

// Verify without accessing signing credentials, including on CI machines.
func require(_ condition:Bool,_ message:String) throws {
    if !condition { throw NSError(domain:"HeyBudsUpdateAudit",code:1,userInfo:[NSLocalizedDescriptionKey:message]) }
}
do {
let arguments=CommandLine.arguments
guard arguments.count == 4 else { fatalError("Usage: swift scripts/verify-update.swift appcast.xml archive-or-dash public-key") }
let data=try Data(contentsOf:URL(fileURLWithPath:arguments[1]))
let marker=Data("<!-- sparkle-signatures:\n".utf8)
let range=data.range(of:marker,options:.backwards)
try require(range != nil,"Unsigned feed")
let content=data.prefix(range!.lowerBound)
let trailer=String(decoding:data.suffix(from:range!.lowerBound),as:UTF8.self)
let lines=trailer.split(separator:"\n").map(String.init)
try require(lines.count == 4 && lines[0] == "<!-- sparkle-signatures:" && lines[3] == "-->","Invalid signing block")
try require(lines[1].hasPrefix("edSignature: ") && lines[2].hasPrefix("length: "),"Missing feed signature")
try require(Int(lines[2].dropFirst("length: ".count)) == content.count,"Incorrect signed feed length")
let key=try Curve25519.Signing.PublicKey(rawRepresentation:Data(base64Encoded:arguments[3]) ?? Data())
let feedSignature=Data(base64Encoded:String(lines[1].dropFirst("edSignature: ".count))) ?? Data()
try require(key.isValidSignature(feedSignature,for:content),"Feed signature mismatch")
let document=try XMLDocument(data:Data(content))
let enclosures=try document.nodes(forXPath:"/rss/channel/item/enclosure")
try require(enclosures.count == 1,"Expected one application archive")
let enclosure=enclosures[0] as! XMLElement
let download=URLComponents(string:enclosure.attribute(forName:"url")?.stringValue ?? "")
try require(download?.scheme == "https" && download?.host == "github.com" && download?.user == nil && download?.password == nil && download?.query == nil && download?.fragment == nil && download?.port == nil,"Unexpected download URL")
try require(download?.path.hasPrefix("/abaichuan1017/HeyBuds/releases/download/v") == true && download?.path.hasSuffix("/HeyBuds-arm64.zip") == true,"Unexpected download project")
if arguments[2] != "-" {
    let archive=try Data(contentsOf:URL(fileURLWithPath:arguments[2]))
    try require(Int(enclosure.attribute(forName:"length")?.stringValue ?? "") == archive.count,"Archive size mismatch")
    let signature=Data(base64Encoded:enclosure.attribute(forName:"sparkle:edSignature")?.stringValue ?? "") ?? Data()
    try require(key.isValidSignature(signature,for:archive),"Archive signature mismatch")
}
print("Signed update feed" + (arguments[2] == "-" ? "" : " and archive") + " verified.")

} catch {
    fputs("Update verification failed: \(error.localizedDescription)\n",stderr)
    exit(1)
}
