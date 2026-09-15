import Foundation

/// Lets a user point Wine at a folder outside the app's own container -- an
/// external drive attached through the Files app, an SD card reader, a
/// network share, or any other document-provider location -- and exposes it
/// inside the guest as a drive letter.
///
/// iOS has no notion of "mounting" a drive the way desktop Wine does. What it
/// has is the security-scoped bookmark: `UIDocumentPickerViewController`
/// (see `ExternalDrivePicker`) grants the app a sandbox extension for
/// whatever folder the user picks, and a bookmark lets that grant be
/// re-derived on a later launch without asking again. This store owns that
/// bookmark and is the only thing that calls
/// `startAccessingSecurityScopedResource()` / `stopAccessingSecurityScopedResource()`,
/// so the two stay paired across a run.
///
/// The engine side of this is the same no-rebuild file channel every other
/// setting uses (see `SettingsStore`): `prepareForLaunch()` writes the
/// resolved POSIX path to `Documents/madeira-external-drive.txt`, and
/// `madeira_link_external_drive()` (WineProcessBridge.m) turns that into a
/// `dosdevices/d:` symlink before wineserver starts reading the registry.
final class ExternalDriveStore: ObservableObject {
    static let shared = ExternalDriveStore()

    /// The drive letter the engine side links to. Kept in one place, as text,
    /// purely for display -- WineProcessBridge.m's `kMadeiraExternalDriveLetter`
    /// is the actual source of truth and has to be changed separately if this
    /// ever does.
    static let driveLetter = "D:"

    private static let bookmarkKey = "madeira.externalDrive.bookmark"
    private static let displayNameKey = "madeira.externalDrive.displayName"
    private static let overrideFileName = "madeira-external-drive.txt"

    /// The folder's last-known display name, or nil if none has ever been
    /// connected. Kept separately from the bookmark so Settings has
    /// something to show even before a launch has resolved it.
    @Published private(set) var displayName: String?
    /// Set by `prepareForLaunch()`, cleared on the next successful one. Shown
    /// in Settings so a stale or revoked bookmark reads as a problem to fix
    /// rather than a drive that silently stopped appearing.
    @Published private(set) var lastError: String?

    /// Held only while a run has security-scoped access open, so it can be
    /// released exactly once when that run ends.
    private var activeURL: URL?

    private init() {
        displayName = UserDefaults.standard.string(forKey: Self.displayNameKey)
    }

    private var bookmark: Data? {
        get { UserDefaults.standard.data(forKey: Self.bookmarkKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.bookmarkKey) }
    }

    var isConnected: Bool { bookmark != nil }

    /// Called from `ExternalDrivePicker` once the user has chosen a folder.
    func connect(to url: URL) {
        do {
            let data = try url.bookmarkData()
            bookmark = data
            displayName = url.lastPathComponent
            UserDefaults.standard.set(displayName, forKey: Self.displayNameKey)
            lastError = nil
        } catch {
            lastError = "Could not save access to that folder: \(error.localizedDescription)"
        }
    }

    /// Drops the bookmark and the override file, so the next launch links no
    /// drive at all rather than reusing a stale target.
    func disconnect() {
        if let url = activeURL {
            url.stopAccessingSecurityScopedResource()
            activeURL = nil
        }
        bookmark = nil
        displayName = nil
        lastError = nil
        UserDefaults.standard.removeObject(forKey: Self.displayNameKey)
        removeOverrideFile()
    }

    /// Resolves the bookmark, opens security-scoped access for the run, and
    /// writes the override file the native seeding step reads. Call once per
    /// launch, before `wineserver_start()` -- same "before anything reads it"
    /// ordering every other override file already needs (ml588).
    ///
    /// Safe to call with nothing connected: it just makes sure no stale
    /// override file is left over from an earlier run. Returns a line for the
    /// on-screen log, or nil when there was nothing to do.
    @discardableResult
    func prepareForLaunch() -> String? {
        // A previous run's access should already have been released by
        // `finishAfterRun()`, but a forced quit or a crash can skip that --
        // release defensively before opening a new one.
        if let stale = activeURL {
            stale.stopAccessingSecurityScopedResource()
            activeURL = nil
        }

        guard let bookmark else {
            removeOverrideFile()
            return nil
        }

        var isStale = false
        let url: URL
        do {
            url = try URL(resolvingBookmarkData: bookmark, options: [],
                           relativeTo: nil, bookmarkDataIsStale: &isStale)
        } catch {
            lastError = "Saved folder is no longer accessible: \(error.localizedDescription)"
            removeOverrideFile()
            return "External drive: \(lastError!)"
        }

        guard url.startAccessingSecurityScopedResource() else {
            lastError = "Could not get access to \(url.lastPathComponent) -- reconnect it from Settings."
            removeOverrideFile()
            return "External drive: \(lastError!)"
        }
        activeURL = url

        // A stale bookmark still resolved this once (the OS keeps the old
        // path working through the transition), but won't next time -- save
        // a fresh one now while access is open.
        if isStale, let refreshed = try? url.bookmarkData() {
            self.bookmark = refreshed
        }

        writeOverrideFile(path: url.path)
        lastError = nil
        displayName = url.lastPathComponent
        return "External drive: \(Self.driveLetter) -> \(url.path)"
    }

    /// Releases the access opened by `prepareForLaunch()`. Call once the Wine
    /// session has actually ended, not merely paused -- RunStatus's watcher
    /// is the source of truth for that (see `RunStatus.end()`).
    func finishAfterRun() {
        guard let url = activeURL else { return }
        url.stopAccessingSecurityScopedResource()
        activeURL = nil
    }

    private func overrideFileURL() -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent(Self.overrideFileName)
    }

    private func writeOverrideFile(path: String) {
        guard let url = overrideFileURL() else { return }
        try? path.write(to: url, atomically: true, encoding: .utf8)
    }

    private func removeOverrideFile() {
        guard let url = overrideFileURL() else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
