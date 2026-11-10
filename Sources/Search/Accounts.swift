import SwiftUI

/// The accounts kept for a site, hanging from the sign-in box the caret is
/// in. The same white and hairline as everything else that floats over a
/// page; one line per account, the name in ink and the site under it in
/// grey; a click puts both into the form. The Mac's passkeys for a page
/// waiting for one come first, as in Safari; a click on one brings up the
/// Mac's sheet for it. Under a box for your name, email, phone or address,
/// your card in Contacts, and a click fills the form. It follows the box
/// when the page scrolls, and goes when the caret does.
struct AccountList: View {
    @ObservedObject var browser: Browser
    let asked: Browser.Suggesting
    /// Where the card came out in its host, for a host that has to know
    /// where it is to keep a click on it (see PaneStage's AccountHost).
    var onFrame: ((CGRect) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(asked.passkeys) { passkey in
                Row(mark: .symbol("person.badge.key"), name: passkey.name,
                    detail: "Passkey" + (passkey.provider.map { " · \($0)" } ?? "")) { browser.choose(passkey) }
            }
            // The page's own host first, from both places; the rest of its
            // site under a line, so a login saved for example.com is still
            // there on admin.example.com without passing for admin's.
            ForEach(ownLogins) { loginRow($0) }
            ForEach(ownApple) { appleRow($0) }
            ForEach(ownPass) { passRow($0) }
            if !(ownLogins.isEmpty && ownApple.isEmpty && ownPass.isEmpty) && !(siteLogins.isEmpty && siteApple.isEmpty && sitePass.isEmpty) {
                Text("Other accounts on \(Vault.registrable(asked.host))")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.faint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 1) }
            }
            ForEach(siteLogins) { loginRow($0) }
            ForEach(siteApple) { appleRow($0) }
            ForEach(sitePass) { passRow($0) }
            ForEach(asked.codes) { code in
                Row(mark: .symbol("number"), name: code.user.isEmpty ? "Verification code" : code.user,
                    detail: code.user.isEmpty ? "Apple Passwords" : "Verification code · Apple Passwords") { browser.choose(code) }
            }
            ForEach(asked.passCodes) { entry in
                Row(mark: .symbol("number"), name: entry.name, detail: "Verification code · pass") { browser.chooseCode(entry) }
            }
            if asked.appleConnect {
                Row(mark: .symbol("key.icloud"), name: "Connect Apple Passwords…",
                    detail: "Pair once with a code from your Mac") { browser.connectApplePasswords() }
            }
            if asked.appleOffer != nil {
                OfferRow(use: browser.useApplePasswords, never: browser.neverOfferApplePasswords)
            }
            // A click fills the form; a shift-click, the box alone.
            ForEach(asked.contacts) { contact in
                Row(mark: .symbol("person.crop.circle"), name: contact.title, detail: contact.detail) {
                    browser.choose(contact, alone: NSEvent.modifierFlags.contains(.shift))
                }
                .help("Fills the form. Shift-click fills only this box.")
            }
            if !offerOnly {
            HStack(spacing: 6) {
                Image(systemName: contactsOnly ? "person.crop.rectangle" : "key")
                    .font(.system(size: 9, weight: .medium))
                Text(footer)
                    .font(.system(size: 10.5))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Palette.faint)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Palette.wash.opacity(0.5))
            }
        }
        .frame(width: max(240, min(360, asked.spot.width)), alignment: .leading)
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.14), radius: 22, y: 8)
        // Measured inside the offset, so where it is drawn, not laid out.
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(FromTopLeft<AccountList>.space)) }) { onFrame?($0) }
        // Just under the box, left edges lined up. The offset is from the
        // stage's top-left, which is also the web view's.
        .offset(x: asked.spot.minX, y: asked.spot.maxY + 6)
    }

    private var ownLogins: [Kept] { asked.logins.filter { Vault.belongs($0.host, to: asked.host, wide: false) } }
    private var siteLogins: [Kept] { asked.logins.filter { !Vault.belongs($0.host, to: asked.host, wide: false) } }
    private var ownApple: [AppleLogin] { asked.apple.filter { owns($0) } }
    private var siteApple: [AppleLogin] { asked.apple.filter { !owns($0) } }

    private var ownPass: [PassStore.Entry] { asked.pass.filter { ownsPass($0) } }
    private var sitePass: [PassStore.Entry] { asked.pass.filter { !ownsPass($0) } }

    private func ownsPass(_ entry: PassStore.Entry) -> Bool {
        asked.passHost.map { PassStore.fits(entry.folder, $0) == 0 } ?? false
    }

    private func owns(_ login: AppleLogin) -> Bool {
        asked.appleHost.map { ApplePasswords.belongs(login.sites, to: $0, wide: false) } ?? false
    }

    private func loginRow(_ login: Kept) -> some View {
        Row(mark: .letter(login.user.first.map { String($0).uppercased() } ?? "•"),
            name: login.user.isEmpty ? "No name" : login.user, detail: login.host) { browser.choose(login) }
    }

    /// The Mac's Passwords app, when turned on (ApplePasswords.swift):
    /// marked as Apple's.
    private func appleRow(_ login: AppleLogin) -> some View {
        Row(mark: .letter(login.user.first.map { String($0).uppercased() } ?? "•"),
            name: login.user.isEmpty ? "No name" : login.user, detail: "Apple Passwords") { browser.choose(login) }
    }

    /// pass, when turned on (PassStore.swift): its name in the store, marked
    /// as pass's.
    private func passRow(_ entry: PassStore.Entry) -> some View {
        Row(mark: .letter(entry.name.first.map { String($0).uppercased() } ?? "•"), name: entry.name, detail: "pass") {
            browser.choose(entry)
        }
    }

    /// Nothing from a place that keeps passwords: Search's, Apple's or pass.
    private var noAccounts: Bool {
        asked.logins.isEmpty && asked.apple.isEmpty && asked.codes.isEmpty && !asked.appleConnect
            && asked.pass.isEmpty && asked.passCodes.isEmpty
    }

    /// Nothing but the offer: no footer under it, the row says it all.
    private var offerOnly: Bool {
        asked.appleOffer != nil && asked.passkeys.isEmpty && noAccounts && asked.contacts.isEmpty
    }

    /// Nothing but your card's rows.
    private var contactsOnly: Bool {
        !asked.contacts.isEmpty && asked.passkeys.isEmpty && noAccounts
    }

    private var footer: String {
        if contactsOnly { return "From your card in Contacts" }
        if noAccounts { return "Passkeys on this Mac" }
        var places: [String] = []
        if !asked.logins.isEmpty { places.append("your keychain") }
        if !asked.apple.isEmpty || !asked.codes.isEmpty || asked.appleConnect { places.append("Apple Passwords") }
        if !asked.pass.isEmpty || !asked.passCodes.isEmpty { places.append("pass") }
        return "From " + (places.count > 2 ? places.dropLast().joined(separator: ", ") + " and " + (places.last ?? "")
                                            : places.joined(separator: " and "))
    }

    private enum Mark { case letter(String), symbol(String) }

    /// "Use your Apple passwords?", at the bottom: smaller and greyer than
    /// an account, so it never reads as one. A click turns Apple Passwords
    /// on and pairs; the ✕ says don't offer again.
    struct OfferRow: View {
        let use: () -> Void
        let never: () -> Void
        @State private var hovering = false
        @State private var onCross = false

        var body: some View {
            HStack(spacing: 8) {
                Button(action: use) {
                    HStack(spacing: 8) {
                        Image(systemName: "key")
                            .font(.system(size: 9, weight: .medium))
                            .frame(width: 22)
                        Text("Use your Apple passwords?")
                            .font(.system(size: 11.5))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(hovering && !onCross ? Palette.ink : Palette.muted)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Turns on Apple Passwords and pairs with a code from your Mac. Settings › Passwords turns it off.")
                Button(action: never) {
                    Image(systemName: "xmark")
                        .font(.system(size: 7.5, weight: .semibold))
                        .foregroundStyle(Palette.faint)
                        .frame(width: 16, height: 16)
                        .background(Palette.ink.opacity(onCross ? 0.07 : 0), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .onHover { onCross = $0 }
                .help("Don't offer again")
                .accessibilityLabel("Don't offer again")
            }
            .padding(.leading, 10)
            .padding(.trailing, 8)
            .padding(.vertical, 6)
            .background(hovering ? Palette.hover : .clear)
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
            .animation(Motion.quick, value: onCross)
        }
    }

    private struct Row: View {
        let mark: Mark
        let name: String
        let detail: String
        let pick: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: pick) {
                HStack(spacing: 10) {
                    Group {
                        switch mark {
                        case .letter(let letter): Text(letter).font(.system(size: 11, weight: .medium))
                        case .symbol(let name): Image(systemName: name).font(.system(size: 10, weight: .medium))
                        }
                    }
                    .foregroundStyle(Palette.ink)
                    .frame(width: 22, height: 22)
                    .background(Palette.wash, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Palette.ink)
                            .lineLimit(1)
                        Text(detail)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Palette.muted)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(hovering ? Palette.hover : .clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
        }
    }
}
