import Foundation

private let log = FileLog("Prewarm")

/// Pre-warming: deliberately open an account's 5-hour quota window at a time
/// that suits the user's day.
///
/// The window is not a fixed wall-clock slot - it is created by the account's
/// first request and expires five hours later. Whoever sends that first request
/// therefore decides where every boundary for the day falls:
///
///     first request at 09:00 -> window 09:00-14:00. The lunch break at 12:00
///     burns the tail of it, and 13:00 is spent waiting for 14:00.
///
///     first request at 08:00 -> window 08:00-13:00 expires exactly during
///     lunch, and the first request after lunch opens 13:00-18:00.
///
/// So we send one deliberately tiny request per account in the morning. The
/// request costs 8 input / 1 output tokens - the content is irrelevant, only
/// the fact that a request happened matters.
///
/// Note this runs per access token and never touches the keychain's active
/// credentials: every account is warmed where it stands, with no switching.
extension ClaudeService {

    /// The smallest useful request: cheapest model, one token of output.
    private static let prewarmModel = "claude-haiku-4-5-20251001"

    /// Send the one request that opens the 5-hour window for this token.
    ///
    /// Throws the same `UsageError` cases as `getUsageLimits`, so callers can
    /// reuse their expiry/rate-limit handling verbatim.
    func ignite(accessToken: String) async throws {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw UsageError.network("invalid url")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": Self.prewarmModel,
            "max_tokens": 1,
            "messages": [["role": "user", "content": "hi"]],
        ])

        let (responseData, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as? HTTPURLResponse
        guard httpResponse?.statusCode == 200 else {
            let responseString = String(data: responseData, encoding: .utf8) ?? ""
            log.error("[ignite] HTTP \(httpResponse?.statusCode ?? 0)")

            if httpResponse?.statusCode == 401 || responseString.contains("token_expired") {
                throw UsageError.expired
            }
            if httpResponse?.statusCode == 429 {
                let retryAfter = httpResponse?.value(forHTTPHeaderField: "Retry-After")
                    .flatMap(TimeInterval.init)
                throw UsageError.rateLimited(retryAfter: retryAfter)
            }
            if httpResponse?.statusCode == 403 {
                throw UsageError.forbidden(responseString)
            }
            throw UsageError.network("HTTP \(httpResponse?.statusCode ?? 0)")
        }
        log.info("[ignite] window opened")
    }
}
