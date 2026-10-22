import Foundation

struct ReleaseVersion:Comparable,Equatable,Sendable {
    let major:Int, minor:Int, patch:Int
    init?(_ tag:String) {
        let value=tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let parts=value.split(separator:".",omittingEmptySubsequences:false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0 >= "0" && $0 <= "9" } }),
              let major=Int(parts[0]),let minor=Int(parts[1]),let patch=Int(parts[2]) else { return nil }
        self.major=major;self.minor=minor;self.patch=patch
    }
    static func < (lhs:Self,rhs:Self) -> Bool {
        (lhs.major,lhs.minor,lhs.patch) < (rhs.major,rhs.minor,rhs.patch)
    }
}

enum UpdateCheckError:Error,Equatable { case invalidResponse, rateLimited, unavailable }

struct LatestRelease:Equatable,Sendable {
    let tag:String
    let version:ReleaseVersion
    let url:URL

    static func decode(_ data:Data) throws -> Self {
        struct Payload:Decodable {
            let tag_name:String, html_url:String
            let draft:Bool, prerelease:Bool
        }
        let payload=try JSONDecoder().decode(Payload.self,from:data)
        guard !payload.draft,!payload.prerelease,let version=ReleaseVersion(payload.tag_name),
              let url=URL(string:payload.html_url),url.scheme == "https",url.host == "github.com",
              url.user == nil,url.password == nil,url.port == nil,url.query == nil,url.fragment == nil,
              url.path == AppIdentity.projectURL.path + "/releases/tag/" + payload.tag_name else {
            throw UpdateCheckError.invalidResponse
        }
        return Self(tag:payload.tag_name,version:version,url:url)
    }
}

enum UpdateChecker {
    // Called only from the user's Check for updates action. No polling, account
    // credentials, downloads or installation are performed by this request.
    static func latest(session:URLSession = .shared) async throws -> LatestRelease {
        var request=URLRequest(url:AppIdentity.latestReleaseAPIURL,cachePolicy:.reloadIgnoringLocalCacheData,timeoutInterval:12)
        request.setValue("application/vnd.github+json",forHTTPHeaderField:"Accept")
        request.setValue("HeyBuds/"+AppIdentity.version,forHTTPHeaderField:"User-Agent")
        let (data,response)=try await session.data(for:request)
        guard let response=response as? HTTPURLResponse else { throw UpdateCheckError.invalidResponse }
        if response.statusCode == 403 || response.statusCode == 429 { throw UpdateCheckError.rateLimited }
        guard response.statusCode == 200 else { throw UpdateCheckError.unavailable }
        guard data.count <= 1_048_576 else { throw UpdateCheckError.invalidResponse }
        return try LatestRelease.decode(data)
    }
}
