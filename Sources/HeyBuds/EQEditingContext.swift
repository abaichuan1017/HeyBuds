import Foundation
import HeyBudsProtocol

struct EQEditingContext:Identifiable {
    let id=UUID()
    let sessionID:UUID
    let deviceID:String?
    let entry:CustomEQEntry
    @MainActor init(app:AppModel,entry:CustomEQEntry) {
        sessionID=app.sessionID;deviceID=app.selectedID;self.entry=entry
    }
    @MainActor func isCurrent(in app:AppModel) -> Bool {
        app.ready && app.sessionID == sessionID && app.selectedID == deviceID
    }
}
