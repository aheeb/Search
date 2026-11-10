import XCTest
@testable import Search

/// pass under the sign-in box (PassStore.swift): which of a store's folders
/// a page is offered, read from names alone, and what a picked account's
/// file is read as. Every name and file here is made up; no store is read
/// but a folder made for the test, and pass is never run (that is left to
/// Tests/pass_store.py, with a throwaway store and key).
final class PassStoreTests: XCTestCase {
    /// A public suffix list small enough to read: what the tests need.
    private let suffix: (String) -> Bool = { ["com", "net", "uk", "co.uk", "io", "github.io", "ch"].contains($0) }

    private func entries(_ paths: [String]) -> [PassStore.Entry] { paths.map(PassStore.Entry.init(path:)) }

    func testAFolderNamedForTheHostIsOffered() {
        XCTAssertEqual(PassStore.fits("gmx.net", "gmx.net", isSuffix: suffix), 0)
        XCTAssertEqual(PassStore.fits("GMX.net", "www.gmx.net", isSuffix: suffix), 0, "case and www. aside")
        XCTAssertNil(PassStore.fits("gmx.net", "gmx.de", isSuffix: suffix))
        XCTAssertNil(PassStore.fits("mail.gmx.net", "gmx.net", isSuffix: suffix), "a host below the page's is another site's")
    }

    func testAFolderAboveTheHostIsOfferedWhenItIsASiteOfItsOwn() {
        XCTAssertEqual(PassStore.fits("microsoftonline.com", "login.microsoftonline.com", isSuffix: suffix), 1)
        XCTAssertEqual(PassStore.fits("bbc.co.uk", "account.bbc.co.uk", isSuffix: suffix), 1)
        XCTAssertNil(PassStore.fits("com", "login.microsoftonline.com", isSuffix: suffix), "a public suffix is nobody's site")
        XCTAssertNil(PassStore.fits("co.uk", "account.bbc.co.uk", isSuffix: suffix))
        XCTAssertNil(PassStore.fits("github.io", "someone.github.io", isSuffix: suffix))
        XCTAssertNil(PassStore.fits("soft.com", "microsoft.com", isSuffix: suffix), "a name that only ends the same")
        // With no list to tell a suffix by, only the host's own folder.
        XCTAssertNil(PassStore.fits("microsoftonline.com", "login.microsoftonline.com", isSuffix: nil))
        // A box that only might be a sign-in's: the host's own folder alone.
        XCTAssertNil(PassStore.fits("microsoftonline.com", "login.microsoftonline.com", wide: false, isSuffix: suffix))
        XCTAssertEqual(PassStore.fits("login.microsoftonline.com", "login.microsoftonline.com", wide: false, isSuffix: suffix), 0)
    }

    func testFoldersThatAreNotDomainsNeverMatch() {
        for folder in ["discord", "cloudflare", "hslu"] {
            XCTAssertNil(PassStore.fits(folder, "\(folder).com", isSuffix: suffix), folder)
            XCTAssertNil(PassStore.fits(folder, "www.\(folder).ch", isSuffix: suffix), folder)
        }
        XCTAssertNil(PassStore.fits("0.1", "127.0.0.1", isSuffix: suffix), "an address is only ever itself")
        XCTAssertEqual(PassStore.fits("127.0.0.1", "127.0.0.1", isSuffix: suffix), 0)
    }

    func testTheHostsOwnFolderComesFirstThenTheSites() {
        let all = entries([
            "microsoftonline.com/uni@example.ch", "discord/me", "login.microsoftonline.com/work@example.com",
            "com/nobody", "login.microsoftonline.com/deeper/admin@example.com", "gmx.net/me@example.net",
        ])
        let found = PassStore.matching(all, host: "login.microsoftonline.com", isSuffix: suffix)
        XCTAssertEqual(found.map(\.path), [
            "login.microsoftonline.com/work@example.com", "login.microsoftonline.com/deeper/admin@example.com",
            "microsoftonline.com/uni@example.ch",
        ])
        // The name shown is the path under the folder.
        XCTAssertEqual(found.map(\.name), ["work@example.com", "deeper/admin@example.com", "uni@example.ch"])
        XCTAssertEqual(found.first?.folder, "login.microsoftonline.com")
        XCTAssertEqual(PassStore.matching(all, host: "login.microsoftonline.com", wide: false, isSuffix: suffix).count, 2)
    }

    func testAnEntrysTextIsReadForItsPasswordAndName() {
        let full = PassStore.parse("s3cret-one\nlogin: me@example.com\nurl: https://example.com/login\notpauth://totp/x?secret=ABC\n",
                                   name: "file-name")
        XCTAssertEqual(full.password, "s3cret-one")
        XCTAssertEqual(full.login, "me@example.com")
        // No login line: the file's name stands in.
        let bare = PassStore.parse("only-a-password\n", name: "me@example.net")
        XCTAssertEqual(bare.password, "only-a-password")
        XCTAssertEqual(bare.login, "me@example.net")
        // An API key: a key and an env line, filled as it is.
        let key = PassStore.parse("sk-made-up\nenv: MADE_UP_KEY\n", name: "api")
        XCTAssertEqual(key.password, "sk-made-up")
        XCTAssertEqual(key.login, "api")
        // A password with colons and spaces is the whole first line; a
        // login line with an empty value is no login.
        let odd = PassStore.parse("a: b c\r\nlogin:   \nLogin: Second@Example.com\n", name: "n")
        XCTAssertEqual(odd.password, "a: b c")
        XCTAssertEqual(odd.login, "Second@Example.com")
        XCTAssertEqual(PassStore.parse("", name: "n").password, "")
    }

    func testAStoreIsListedByItsFileNamesAlone() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pass-names-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = ["gmx.net/me@example.net.gpg", "microsoftonline.com/sub/uni.gpg", ".gpg-id", "gmx.net/.gpg-id",
                     ".git/objects/aa.gpg", "toplevel.gpg", "notes.txt", "gmx.net/-option.gpg"]
        for file in files {
            let url = root.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Not gpg at all: listing never opens a file.
            try Data("not read".utf8).write(to: url)
        }
        let found = PassStore.entries(in: root)
        XCTAssertEqual(found.map(\.path), ["gmx.net/me@example.net", "microsoftonline.com/sub/uni"],
                       "pass's own files, a name pass would take for an option and one in no folder are left out")
        XCTAssertEqual(found.last?.name, "sub/uni")
    }
}
