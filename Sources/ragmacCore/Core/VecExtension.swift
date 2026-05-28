import Foundation

// sqlite3_enable_load_extension and sqlite3_load_extension are not in Apple's system
// sqlite3.h headers, but ARE available when SQLite.swift is built with the
// SQLiteSwiftCSQLite trait (bundled sqlite3 compiled with SQLITE_ENABLE_LOAD_EXTENSION).
// @_silgen_name maps Swift names to the underlying C symbols at link time.
@_silgen_name("sqlite3_enable_load_extension")
private func _sqlite3EnableLoadExtension(_ db: OpaquePointer, _ onoff: Int32) -> Int32

@_silgen_name("sqlite3_load_extension")
private func _sqlite3LoadExtension(
    _ db: OpaquePointer,
    _ zFile: UnsafePointer<CChar>,
    _ zProc: UnsafePointer<CChar>?,
    _ pzErrMsg: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32

@_silgen_name("sqlite3_free")
private func _sqlite3Free(_ ptr: UnsafeMutableRawPointer?)

/// Downloads and loads the sqlite-vec runtime extension.
public enum VecExtension {
    static let version = "0.1.6"

    /// Ensures vec0.dylib exists at destDir/vec0.dylib, downloading if needed.
    public static func ensureAvailable(in destDir: URL) async throws -> URL {
        let dylibURL = destDir.appendingPathComponent("vec0.dylib")
        if FileManager.default.fileExists(atPath: dylibURL.path) {
            return dylibURL
        }
        fputs("→ Downloading sqlite-vec v\(version)...\n", stderr)
        try await download(to: destDir)
        guard FileManager.default.fileExists(atPath: dylibURL.path) else {
            throw RagmacError.systemError(
                "sqlite-vec download succeeded but vec0.dylib not found at \(dylibURL.path)"
            )
        }
        return dylibURL
    }

    /// Loads the extension onto a connection handle.
    public static func load(on handle: OpaquePointer, dylibPath: String) throws {
        _ = _sqlite3EnableLoadExtension(handle, 1)
        var errmsg: UnsafeMutablePointer<CChar>? = nil
        let rc = dylibPath.withCString { pathPtr in
            "sqlite3_vec_init".withCString { procPtr in
                _sqlite3LoadExtension(handle, pathPtr, procPtr, &errmsg)
            }
        }
        _ = _sqlite3EnableLoadExtension(handle, 0)
        if rc != 0 {  // SQLITE_OK = 0
            let msg = errmsg.map { String(cString: $0) } ?? "unknown error"
            _sqlite3Free(errmsg)
            throw RagmacError.systemError("Failed to load sqlite-vec: \(msg)")
        }
    }

    // MARK: - Private

    private static func download(to destDir: URL) async throws {
        let arch: String
        #if arch(arm64)
        arch = "aarch64"
        #else
        arch = "x86_64"
        #endif

        let archiveName = "sqlite-vec-\(version)-loadable-macos-\(arch).tar.gz"
        let urlStr = "https://github.com/asg017/sqlite-vec/releases/download/v\(version)/\(archiveName)"
        guard let url = URL(string: urlStr) else {
            throw RagmacError.downloadFailed(url: urlStr, reason: "Invalid URL")
        }

        let (tmpURL, response) = try await URLSession.shared.download(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw RagmacError.downloadFailed(url: urlStr, reason: "HTTP \(code)")
        }

        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        proc.arguments = ["-xzf", tmpURL.path, "-C", destDir.path]
        try proc.run()
        proc.waitUntilExit()

        if proc.terminationStatus != 0 {
            throw RagmacError.systemError(
                "Failed to extract sqlite-vec archive (exit \(proc.terminationStatus))"
            )
        }
    }
}
