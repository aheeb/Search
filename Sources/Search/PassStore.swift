import Foundation

// Passwords from pass (passwordstore.org) under the sign-in box, beside
// Search's own and Apple Passwords, for someone who keeps theirs there.
//
// pass keeps one gpg-encrypted file per account, in a folder named for its
// site: gmx.net/me@example.com.gpg. Which accounts a site has is read from
// those names alone, with nothing decrypted; an account's file is decrypted
// by `pass show` only once you pick it, and what it holds goes straight into
// the page's boxes and is kept nowhere. Its first line is the password, a
// `login:` line the name (the file's name when there is none). A box for a
// verification code offers the site's accounts too, and a pick runs `pass
// otp`; an account with no code says so.
//
// - A folder is offered on its own host, and on any host under it when it
//   is a site of its own: microsoftonline.com on login.microsoftonline.com,
//   but never com or co.uk, and never a folder that isn't a domain at all
//   (discord, hslu).
// - The same rules as Apple Passwords (ApplePasswords.swift): never in a
//   private tab, never over plain http, the main frame's form only, and only
//   for the site the page's committed address is on.
// - Off unless turned on in Settings › Passwords, where the switch shows
//   only on a Mac with pass and a store. Nothing is ever written to the
//   store: new passwords are kept in Search's keychain, as always.
// - pass is run as you would run it, off the main thread and stopped after
//   15 seconds (gpg may be waiting on its own passphrase window), with
//   Homebrew's folders on its PATH, which an app started from the Finder
//   doesn't have. Only its output is read, into memory; its errors are not.

enum PassStore {
    /// One account in the store, by name: nothing in it is read until it is
    /// picked.
    struct Entry: Identifiable, Equatable, Hashable {
        /// Its name in the store, as pass takes it: gmx.net/me@example.com.
        let path: String
        /// The folder it is in, lowercased: the site it is for.
        let folder: String
        /// The account's name as shown: the path under the folder.
        let name: String
        var id: String { "pass\u{1}" + path }

        init(path: String) {
            self.path = path
            let parts = path.split(separator: "/", maxSplits: 1).map(String.init)
            folder = parts.first?.lowercased() ?? ""
            name = parts.count > 1 ? parts[1] : path
        }
    }

    /// What a picked account's file says, for the page's boxes.
    struct Secret {
        let password: String
        /// Its `login:` line, or the account's own name without one.
        let login: String
    }

    // MARK: - where

    /// A test run's own store and keyring (bench `passstore`). Never set
    /// otherwise: a real run uses yours.
    @MainActor static var testFolder: URL?
    @MainActor static var testKeyring: URL?

    /// PASSWORD_STORE_DIR, as pass reads it, or ~/.password-store.
    @MainActor static var folder: URL {
        if Store.testing, let testFolder { return testFolder }
        if let set = ProcessInfo.processInfo.environment["PASSWORD_STORE_DIR"], !set.isEmpty {
            return URL(fileURLWithPath: (set as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".password-store", isDirectory: true)
    }

    /// Where pass is: Homebrew's folder on Apple silicon, then on Intel.
    static let folders = ["/opt/homebrew/bin", "/usr/local/bin"]
    static var program: URL? {
        folders.map { URL(fileURLWithPath: $0).appendingPathComponent("pass") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// pass and a store on this Mac: only then does its switch show.
    @MainActor static var here: Bool {
        var folder: ObjCBool = false
        return program != nil && FileManager.default.fileExists(atPath: Self.folder.path, isDirectory: &folder) && folder.boolValue
    }

    // MARK: - which, without decrypting

    /// The page a tab may be offered pass's accounts on: its committed
    /// address, https, an ordinary tab. A test run's local page over http
    /// too, which a test's server can only be.
    @MainActor static func offers(on tab: Tab) -> String? {
        guard !tab.shy, !(tab.bench && !Store.testing), let url = tab.committed,
              let host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        let scheme = url.scheme?.lowercased()
        guard scheme == "https" || (Store.testing && scheme == "http" && ["127.0.0.1", "localhost"].contains(host))
        else { return nil }
        return host
    }

    /// Every account's name in a store: its .gpg files, minus the ending,
    /// leaving out pass's own (.gpg-id, .git, .extensions). Names alone; not
    /// one file is opened.
    nonisolated static func entries(in folder: URL) -> [Entry] {
        let root = folder.standardizedFileURL.resolvingSymlinksInPath().path
        guard let walk = FileManager.default.enumerator(
            at: URL(fileURLWithPath: root, isDirectory: true), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        var found: [Entry] = []
        for case let file as URL in walk where file.pathExtension == "gpg" {
            let full = file.standardizedFileURL.resolvingSymlinksInPath().path
            guard full.hasPrefix(root + "/") else { continue }
            let path = String(full.dropFirst(root.count + 1).dropLast(4))
            // A name pass would take for an option is never handed to it.
            guard path.contains("/"), !path.split(separator: "/").contains(where: { $0.hasPrefix("-") }) else { continue }
            found.append(Entry(path: path))
        }
        return found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// How a folder stands to a page's host: 0, the host itself; 1, a site
    /// above it; nil, not the page's. `wide` false: the host itself alone,
    /// for a box that only might be a sign-in's. A folder above the host
    /// has to be a site of its own, never a public suffix (com, co.uk,
    /// github.io), and an address is only ever itself.
    nonisolated static func fits(_ folder: String, _ host: String, wide: Bool = true,
                                 isSuffix: ((String) -> Bool)? = PassStore.publicSuffix) -> Int? {
        let folder = bare(folder), host = bare(host)
        guard !folder.isEmpty else { return nil }
        if folder == host { return 0 }
        let address = host.contains(":") || host.allSatisfy { $0.isNumber || $0 == "." }
        guard wide, !address, folder.contains("."), host.hasSuffix("." + folder),
              let isSuffix, !isSuffix(folder) else { return nil }
        return 1
    }

    /// A store's accounts for a page: its own host's first, then the
    /// site's above it, each in the store's order.
    nonisolated static func matching(_ entries: [Entry], host: String, wide: Bool = true,
                                     isSuffix: ((String) -> Bool)? = PassStore.publicSuffix) -> [Entry] {
        let ranked = entries.compactMap { entry in fits(entry.folder, host, wide: wide, isSuffix: isSuffix).map { (entry, $0) } }
        return ranked.filter { $0.1 == 0 }.map(\.0) + ranked.filter { $0.1 == 1 }.map(\.0)
    }

    /// The accounts this Mac's store keeps for a page.
    @MainActor static func accounts(for host: String, wide: Bool) -> [Entry] {
        matching(entries(in: folder), host: host, wide: wide)
    }

    nonisolated static let publicSuffix: ((String) -> Bool)? = Passkeys.publicSuffix.map { test in { test($0 as CFString) } }

    nonisolated private static func bare(_ host: String) -> String {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    // MARK: - what a file says

    /// A decrypted file, read: the first line the password, `login:` the
    /// name, or `name` without one. Nothing but those two is taken.
    nonisolated static func parse(_ text: String, name: String) -> Secret {
        let lines = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        let login = lines.dropFirst().lazy.compactMap { line -> String? in
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, ["login", "user", "username"].contains(parts[0].trimmingCharacters(in: .whitespaces).lowercased())
            else { return nil }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }.first
        return Secret(password: lines.first ?? "", login: login ?? name)
    }

    // MARK: - asking pass

    /// An account's file, decrypted by `pass show`: nil if pass failed or
    /// took too long.
    @MainActor static func show(_ entry: Entry) async -> Secret? {
        guard let text = await run(["show", entry.path]) else { return nil }
        return parse(text, name: entry.name)
    }

    /// An account's verification code now, by `pass otp`: nil when it has
    /// none, or pass failed.
    @MainActor static func otp(_ entry: Entry) async -> String? {
        guard let text = await run(["otp", entry.path]) else { return nil }
        let code = text.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return code.isEmpty ? nil : code
    }

    /// pass, with these arguments, off the main thread: its output if it
    /// ended well within 15 seconds, else nil. Its errors go nowhere.
    @MainActor private static func run(_ arguments: [String]) async -> String? {
        guard let program else { return nil }
        var environment = ProcessInfo.processInfo.environment
        let path = environment["PATH"].map { $0.split(separator: ":").map(String.init) } ?? []
        environment["PATH"] = (folders + path.filter { !folders.contains($0) }
            + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"].filter { !path.contains($0) }).joined(separator: ":")
        environment["PASSWORD_STORE_DIR"] = folder.path
        if Store.testing, let testKeyring { environment["GNUPGHOME"] = testKeyring.path }
        // Never onto the clipboard, whatever the store's settings say.
        environment.removeValue(forKey: "PASSWORD_STORE_CLIP_TIME")
        return await Task.detached(priority: .userInitiated) {
            runNow(program, arguments, environment: environment, timeout: 15)
        }.value
    }

    nonisolated private static func runNow(_ program: URL, _ arguments: [String], environment: [String: String],
                                           timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = program
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        // Read to its end on a thread of its own, so a full pipe never
        // stalls pass, and pass's end is waited for, both within the time.
        let read = Collected()
        let finished = DispatchGroup()
        finished.enter()
        process.terminationHandler = { _ in finished.leave() }
        do { try process.run() } catch { return nil }
        finished.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            read.add(output.fileHandleForReading.readDataToEndOfFile())
            finished.leave()
        }
        // Stopped if it takes too long: gpg asking for a passphrase nobody
        // is there to type.
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            if process.isRunning { process.terminate() }
            return nil
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { return nil }
        return String(data: read.data, encoding: .utf8)
    }

    /// What pass wrote, handed over from the thread that read it.
    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()
        func add(_ more: Data) { lock.lock(); bytes.append(more); lock.unlock() }
        var data: Data { lock.lock(); defer { lock.unlock() }; return bytes }
    }
}
