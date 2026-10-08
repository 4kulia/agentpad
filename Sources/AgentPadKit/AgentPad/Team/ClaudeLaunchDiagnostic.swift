import Foundation

/// Only allowlisted summaries leave the executor. Raw stderr / error results
/// can contain credentials, prompts, URLs and local paths; redacting a handful
/// of token patterns would not make an arbitrary diagnostic safe to persist.
struct ClaudeLaunchDiagnostic {
    enum Failure: String, Codable, Sendable {
        case authentication = "требуется вход"
        case permission = "доступ запрещён"
        case network = "ошибка соединения"
        case timeout = "время ожидания истекло"
        case version = "Не удалось определить версию Claude Code"
        case spawn = "процесс не создан"
        case unavailable = "выбранный файл недоступен"
        case noAnswer = "ответ не получен"
        case execution = "ошибка выполнения"
    }

    let version: String?
    let exitCode: Int32?
    let failure: Failure

    init(version: String?, exitCode: Int32?, output: String = "", fallback: Failure) {
        // --version is validated separately; retain that boundary for injected
        // checkers too. No arbitrary executable output becomes a version label.
        self.version = version.flatMap {
            $0.utf8.count <= 128 && $0.range(of: #"\A[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?\z"#,
                                            options: .regularExpression) != nil ? $0 : nil
        }
        self.exitCode = exitCode
        let text = output.lowercased()
        if ["not logged in", "not authenticated", "unauthorized", "authentication_error", "authentication failed",
            "authentication required", "invalid api key", "invalid_api_key", "invalid bearer token", "please log in",
            "please login", "oauth token has expired", "token expired", "failed to authenticate"].contains(where: text.contains) {
            failure = .authentication
        } else if text.contains("permission denied") || text.contains("operation not permitted") {
            failure = .permission
        } else if ["connection refused", "connection error", "econnrefused", "enotfound", "network error"].contains(where: text.contains) {
            failure = .network
        } else {
            failure = fallback
        }
    }

    var message: String {
        let action = failure == .authentication
            ? "claude не авторизован — откройте claude и войдите."
            : "claude не запускается."
        return "\(action) Версия: \(version ?? "не определена"); код возврата: \(exitCode.map(String.init) ?? "нет"); ошибка: \(failure.rawValue)."
    }
}
