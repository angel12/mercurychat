import Foundation
import Testing

@testable import ChatCore

/// #107: an avatar load belongs to the pick that started it. A late load
/// must not overwrite a newer pick or resurrect a removed avatar, Save must
/// wait for the current pick, and a stale failure must not surface.
@Suite("AvatarSelection")
struct AvatarSelectionTests {
    let jpegA = Data("A".utf8)
    let jpegB = Data("B".utf8)

    @Test func startsUntouchedAndSavable() {
        let avatar = AvatarSelection()
        #expect(avatar.change == nil)
        #expect(avatar.canSave)
        #expect(!avatar.loadFailed)
    }

    @Test func finishedLoadReplacesTheAvatar() {
        var avatar = AvatarSelection()
        let a = avatar.pick()
        avatar.loadFinished(a, jpeg: jpegA)
        #expect(avatar.change == .some(jpegA))
        #expect(avatar.canSave)
    }

    @Test func laterPickWinsWhenLoadsFinishInReverseOrder() {
        var avatar = AvatarSelection()
        let a = avatar.pick()
        let b = avatar.pick()
        avatar.loadFinished(b, jpeg: jpegB)
        avatar.loadFinished(a, jpeg: jpegA)
        #expect(avatar.change == .some(jpegB))
        #expect(avatar.canSave)
    }

    @Test func removeWinsOverAPendingLoad() {
        var avatar = AvatarSelection()
        let a = avatar.pick()
        avatar.remove()
        avatar.loadFinished(a, jpeg: jpegA)
        #expect(avatar.change == .some(nil))
        #expect(avatar.canSave)
    }

    @Test func saveWaitsForThePendingLoad() {
        var avatar = AvatarSelection()
        let a = avatar.pick()
        #expect(!avatar.canSave)
        avatar.loadFinished(a, jpeg: jpegA)
        #expect(avatar.canSave)
    }

    @Test func staleLoadDoesNotReleaseSaveForTheCurrentPick() {
        var avatar = AvatarSelection()
        let a = avatar.pick()
        _ = avatar.pick()
        avatar.loadFinished(a, jpeg: jpegA)
        #expect(!avatar.canSave)
        #expect(avatar.change == nil)
    }

    @Test func staleFailureAfterALaterSuccessIsIgnored() {
        var avatar = AvatarSelection()
        let a = avatar.pick()
        let b = avatar.pick()
        avatar.loadFinished(b, jpeg: jpegB)
        avatar.loadFinished(a, jpeg: nil)
        #expect(!avatar.loadFailed)
        #expect(avatar.change == .some(jpegB))
    }

    @Test func newPickClearsAnEarlierFailure() {
        var avatar = AvatarSelection()
        let a = avatar.pick()
        avatar.loadFinished(a, jpeg: nil)
        #expect(avatar.loadFailed)
        #expect(avatar.canSave)
        _ = avatar.pick()
        #expect(!avatar.loadFailed)
    }

    @Test func removeClearsAnEarlierFailure() {
        var avatar = AvatarSelection()
        let a = avatar.pick()
        avatar.loadFinished(a, jpeg: nil)
        avatar.remove()
        #expect(!avatar.loadFailed)
    }

    @Test func failedLoadKeepsThePreviousChange() {
        var avatar = AvatarSelection()
        let a = avatar.pick()
        avatar.loadFinished(a, jpeg: jpegA)
        let b = avatar.pick()
        avatar.loadFinished(b, jpeg: nil)
        #expect(avatar.change == .some(jpegA))
        #expect(avatar.loadFailed)
    }

    @Test func cancelDropsThePendingLoadAndKeepsTheChange() {
        // The picker cleared its selection: nothing is pending any more.
        var avatar = AvatarSelection()
        let a = avatar.pick()
        avatar.cancelPending()
        #expect(avatar.canSave)
        avatar.loadFinished(a, jpeg: jpegA)
        #expect(avatar.change == nil)
    }
}
