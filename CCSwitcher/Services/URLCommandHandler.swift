import Foundation

private let log = FileLog("URLCommand")

/// Handles `ccswitcher://` URLs so an account switch can be driven by a single
/// command instead of a menu click.
///
///     ccswitcher://use?account=<label|org|email>[&nonce=<n>]
///     ccswitcher://use?id=<account-uuid>[&nonce=<n>]
///     ccswitcher://current[?nonce=<n>]
///     ccswitcher://list[?nonce=<n>]
///
/// The switch itself runs through `AppState.switchTo`, the same path the menu
/// uses: the caller gets the backup-before-swap, the post-swap verification and
/// the in-app state update for free, and the keychain sees the app it already
/// trusts — a separate binary poking at the same items would prompt for
/// authorization on every machine.
///
/// Every command writes its outcome to `~/.ccswitcher/cli-result.json`, tagged
/// with the caller's `nonce`. `open` returns as soon as the URL is delivered, so
/// a wrapper that wants an exit code polls that file for its own nonce; without
/// the tag two concurrent callers would read each other's answer.
@MainActor
enum URLCommandHandler {
    static let scheme = "ccswitcher"
    static var resultPath: String { NSHomeDirectory() + "/.ccswitcher/cli-result.json" }

    static func handle(_ url: URL, appState: AppState) {
        guard url.scheme?.lowercased() == scheme else { return }

        // Both ccswitcher://use?... and ccswitcher:///use?... reach here; take
        // whichever of host/path carries the verb.
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let action = (components?.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
            .lowercased()
        let items = components?.queryItems ?? []
        func param(_ name: String) -> String? {
            items.first { $0.name == name }?.value?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let nonce = param("nonce")

        log.info("[handle] action=\(action)")

        switch action {
        case "use", "switch":
            let query = param("account") ?? param("id") ?? param("name")
            guard let query, !query.isEmpty else {
                write(nonce: nonce, action: action, ok: false,
                      error: String(localized: "Missing parameter: account=<label|org|email> or id=<uuid>.", bundle: L10n.bundle))
                return
            }
            Task { await performSwitch(query: query, nonce: nonce, action: action, appState: appState) }

        case "current":
            let active = appState.activeAccount
            write(nonce: nonce, action: action, ok: active != nil,
                  account: active,
                  error: active == nil ? String(localized: "No account is currently identified.", bundle: L10n.bundle) : nil)

        case "list":
            write(nonce: nonce, action: action, ok: true,
                  account: appState.activeAccount,
                  accounts: appState.accounts)

        default:
            write(nonce: nonce, action: action, ok: false,
                  error: String(localized: "Unknown command \(action). Available: use / current / list.", bundle: L10n.bundle))
        }
    }

    // MARK: - Switch

    private static func performSwitch(query: String, nonce: String?, action: String, appState: AppState) async {
        switch resolve(query, in: appState.accounts) {
        case .failure(let reason):
            write(nonce: nonce, action: action, ok: false, accounts: appState.accounts, error: reason)
        case .matched(let target):
            // Cleared first so a message left over from an earlier failure is
            // never reported as this switch's outcome.
            appState.errorMessage = nil
            await appState.switchTo(target)

            let landed = appState.activeAccount?.id == target.id
            let message = appState.errorMessage
            if landed {
                // `switchTo` succeeds but still sets errorMessage when the CLI
                // resolves credentials from something that outranks the stored
                // login (env token, apiKeyHelper, …). The swap did happen, so
                // report ok with the caveat attached rather than a bare failure.
                write(nonce: nonce, action: action, ok: true, account: target, warning: message)
            } else {
                write(nonce: nonce, action: action, ok: false, account: target,
                      error: message ?? String(localized: "The switch did not take effect. Another switch or login may be in progress; try again shortly.", bundle: L10n.bundle))
            }
        }
    }

    /// id → exact name → substring. Anything ambiguous is refused rather than
    /// guessed: this command swaps credentials, so picking "probably this one"
    /// is the wrong failure mode.
    enum Resolution {
        case matched(Account)
        case failure(String)
    }

    static func resolve(_ query: String, in accounts: [Account]) -> Resolution {
        guard !accounts.isEmpty else {
            return .failure(String(localized: "No accounts saved in CCSwitcher yet.", bundle: L10n.bundle))
        }
        let q = query.lowercased()

        if let byId = accounts.first(where: { $0.id.uuidString.lowercased() == q }) {
            return .matched(byId)
        }

        let exact = accounts.filter { account in
            [account.customLabel, account.orgName, account.displayName, account.email]
                .compactMap { $0?.lowercased() }
                .contains(q)
        }
        if exact.count == 1 { return .matched(exact[0]) }

        let hits = exact.isEmpty ? accounts.filter { account in
            [account.customLabel, account.orgName, account.displayName, account.email]
                .compactMap { $0?.lowercased() }
                .contains { $0.contains(q) }
        } : exact

        switch hits.count {
        case 1: return .matched(hits[0])
        case 0: return .failure(String(localized: "No account matches \(query). Available: \(accounts.map(label).joined(separator: ", "))", bundle: L10n.bundle))
        default: return .failure(String(localized: "\(query) matches several accounts: \(hits.map(label).joined(separator: ", ")). Be more specific.", bundle: L10n.bundle))
        }
    }

    static func label(_ account: Account) -> String {
        if let custom = account.customLabel, !custom.isEmpty { return custom }
        if let org = account.orgName, !org.isEmpty { return org }
        return account.displayName
    }

    // MARK: - Result file

    private static func write(
        nonce: String?,
        action: String,
        ok: Bool,
        account: Account? = nil,
        accounts: [Account]? = nil,
        warning: String? = nil,
        error: String? = nil
    ) {
        var payload: [String: Any] = [
            "nonce": nonce ?? "",
            "action": action,
            "ok": ok,
            "finishedAt": ISO8601DateFormatter().string(from: Date()),
        ]
        if let account { payload["account"] = describe(account, isActive: true) }
        if let accounts {
            let activeId = accounts.first(where: \.isActive)?.id
            payload["accounts"] = accounts.map { describe($0, isActive: $0.id == activeId) }
        }
        if let warning { payload["warning"] = warning }
        if let error { payload["error"] = error }

        let dir = NSHomeDirectory() + "/.ccswitcher"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(withJSONObject: payload,
                                                     options: [.prettyPrinted, .sortedKeys]) else {
            log.error("[write] Could not serialize result")
            return
        }
        do {
            try data.write(to: URL(fileURLWithPath: resultPath), options: .atomic)
            // Readable by this user only: it names the accounts on this machine.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: resultPath)
            log.info("[write] action=\(action) ok=\(ok)")
        } catch {
            log.error("[write] Failed: \(error.localizedDescription)")
        }
    }

    private static func describe(_ account: Account, isActive: Bool) -> [String: Any] {
        var dict: [String: Any] = [
            "id": account.id.uuidString,
            "label": label(account),
            "email": account.email,
            "active": isActive,
        ]
        if let org = account.orgName { dict["orgName"] = org }
        if let orgId = account.orgId { dict["orgId"] = orgId }
        if let sub = account.subscriptionType { dict["subscription"] = sub }
        return dict
    }
}
