import Foundation

/// Runs an async closure synchronously from a ParsableCommand.run() context.
/// Uses Task + DispatchSemaphore so the CLI doesn't need @available(macOS 10.15).
public func runAsync(_ body: @Sendable @escaping () async throws -> Void) throws {
    var thrownError: Error?
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        do { try await body() } catch { thrownError = error }
        semaphore.signal()
    }
    semaphore.wait()
    if let error = thrownError { throw error }
}
