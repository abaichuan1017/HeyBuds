import Foundation
import Testing
import HeyBudsProtocol
@testable import HeyBuds

private func releasePayload(tag:String="v0.4.0",url:String?=nil,draft:Bool=false,prerelease:Bool=false) throws -> Data {
    try JSONSerialization.data(withJSONObject:["tag_name":tag,"html_url":url ?? "https://github.com/abaichuan1017/HeyBuds/releases/tag/"+tag,
        "draft":draft,"prerelease":prerelease])
}

@Test func releaseVersionsCompareNumericallyAndRejectMalformedTags() throws {
    #expect(try #require(ReleaseVersion("v0.3.10")) > #require(ReleaseVersion("0.3.9")))
    #expect(try #require(ReleaseVersion("v1.0.0")) > #require(ReleaseVersion("0.99.99")))
    #expect(ReleaseVersion("v0.3.3") == ReleaseVersion("0.3.3"))
    for tag in ["", "v", "1.2", "1..3", "1.2.3.4", "1.2.-3", "1.2.3-beta", " 1.2.3", "version1.2.3"] {
        #expect(ReleaseVersion(tag) == nil)
    }
}

@Test func updateResponsesRequireStableReleaseAndExactProjectURL() throws {
    let release=try LatestRelease.decode(releasePayload())
    #expect(release.tag == "v0.4.0" && release.version == ReleaseVersion("0.4.0"))
    #expect(throws:UpdateCheckError.invalidResponse) { try LatestRelease.decode(releasePayload(draft:true)) }
    #expect(throws:UpdateCheckError.invalidResponse) { try LatestRelease.decode(releasePayload(prerelease:true)) }
    for url in ["http://github.com/abaichuan1017/HeyBuds/releases/tag/v0.4.0",
                "https://example.com/abaichuan1017/HeyBuds/releases/tag/v0.4.0",
                "https://github.com/another/project/releases/tag/v0.4.0",
                "https://github.com/abaichuan1017/HeyBuds/releases/tag/v9.0.0",
                "https://github.com/abaichuan1017/HeyBuds/releases/tag/v0.4.0?redirect=elsewhere"] {
        #expect(throws:UpdateCheckError.invalidResponse) { try LatestRelease.decode(releasePayload(url:url)) }
    }
}

private final class ReleaseFixtureProtocol:URLProtocol {
    override class func canInit(with request:URLRequest) -> Bool { request.url == AppIdentity.latestReleaseAPIURL }
    override class func canonicalRequest(for request:URLRequest) -> URLRequest { request }
    override func startLoading() {
        let status=Int(request.value(forHTTPHeaderField:"X-Fixture-Status") ?? "200")!
        let tag=request.value(forHTTPHeaderField:"X-Fixture-Tag") ?? "v0.4.0"
        let response=HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:nil)!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:try! releasePayload(tag:tag))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func fixtureSession(status:Int=200,tag:String="v0.4.0") -> URLSession {
    let config=URLSessionConfiguration.ephemeral
    config.protocolClasses=[ReleaseFixtureProtocol.self]
    config.httpAdditionalHeaders=["X-Fixture-Status":String(status),"X-Fixture-Tag":tag]
    return URLSession(configuration:config)
}

@Test func updateCheckHandlesHTTPFailuresWithoutOfferingResponseContent() async throws {
    let session=fixtureSession();defer { session.invalidateAndCancel() }
    #expect(try await UpdateChecker.latest(session:session).tag == "v0.4.0")
    for status in [403,429,500] {
        let failing=fixtureSession(status:status);defer { failing.invalidateAndCancel() }
        do { _ = try await UpdateChecker.latest(session:failing);Issue.record("An HTTP failure was accepted as a release") }
        catch { #expect(error as? UpdateCheckError == (status == 500 ? .unavailable : .rateLimited)) }
    }
}

@Test @MainActor func updateActionReportsNewCurrentAndUnavailableVersions() async throws {
    let model=AppModel(catalog:try HeyBudsProtocol.ModelCatalog())
    let newer=fixtureSession();defer { newer.invalidateAndCancel() }
    await model.checkForUpdates(session:newer)
    #expect(!model.checkingForUpdates && model.showUpdateAlert)
    #expect(model.updateMessage.contains("v0.4.0"))
    #expect(model.updateReleaseURL?.lastPathComponent == "v0.4.0")
    let current=fixtureSession(tag:"v"+AppIdentity.version);defer { current.invalidateAndCancel() }
    await model.checkForUpdates(session:current)
    #expect(model.updateReleaseURL == nil && model.updateMessage.contains(AppIdentity.version))
    let unavailable=fixtureSession(status:500);defer { unavailable.invalidateAndCancel() }
    await model.checkForUpdates(session:unavailable)
    #expect(model.updateReleaseURL == AppIdentity.releasesURL && !model.checkingForUpdates)
}
