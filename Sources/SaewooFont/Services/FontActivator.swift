import Foundation
import CoreText

/// Activates/deactivates fonts in the user's login session via CTFontManager.
/// `.session` scope survives relaunches within a login session and is auto-cleared on logout
/// — safe for experimentation and does not require admin auth.
actor FontActivator {

    enum ActivationError: Error {
        case registrationFailed([URL: String])
    }

    private(set) var activeURLs: Set<URL> = []

    func syncActiveSet(with items: [FontItem], desiredActiveIDs: Set<String>) async throws {
        let desiredURLs = Set(items.filter { desiredActiveIDs.contains($0.id) }.map { $0.fileURL })
        let toRegister = desiredURLs.subtracting(activeURLs)
        let toUnregister = activeURLs.subtracting(desiredURLs)
        if !toUnregister.isEmpty { try await unregister(Array(toUnregister)) }
        if !toRegister.isEmpty { try await register(Array(toRegister)) }
    }

    func activate(_ items: [FontItem]) async throws {
        let urls = Set(items.map { $0.fileURL }).subtracting(activeURLs)
        guard !urls.isEmpty else { return }
        try await register(Array(urls))
    }

    func deactivate(_ items: [FontItem]) async throws {
        let urls = Set(items.map { $0.fileURL }).intersection(activeURLs)
        guard !urls.isEmpty else { return }
        try await unregister(Array(urls))
    }

    private func register(_ urls: [URL]) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            CTFontManagerRegisterFontURLs(urls as CFArray, .session, true) { [weak self] errors, done in
                let errs = (errors as? [CFError]) ?? []
                if errs.isEmpty {
                    Task { await self?.markRegistered(urls) }
                    cont.resume()
                } else {
                    let mapped = Dictionary(uniqueKeysWithValues: zip(urls.prefix(errs.count), errs.map { CFErrorCopyDescription($0) as String? ?? "unknown" }))
                    // Non-fatal — still mark successfully-registered ones. CTFontManager will have
                    // registered the good ones; mark all-except-failed optimistically.
                    Task { await self?.markRegistered(urls) }
                    cont.resume(throwing: ActivationError.registrationFailed(mapped))
                }
                _ = done
                return true
            }
        }
    }

    private func unregister(_ urls: [URL]) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            CTFontManagerUnregisterFontURLs(urls as CFArray, .session) { [weak self] errors, done in
                let errs = (errors as? [CFError]) ?? []
                Task { await self?.markUnregistered(urls) }
                if errs.isEmpty {
                    cont.resume()
                } else {
                    let mapped = Dictionary(uniqueKeysWithValues: zip(urls.prefix(errs.count), errs.map { CFErrorCopyDescription($0) as String? ?? "unknown" }))
                    cont.resume(throwing: ActivationError.registrationFailed(mapped))
                }
                _ = done
                return true
            }
        }
    }

    private func markRegistered(_ urls: [URL]) { activeURLs.formUnion(urls) }
    private func markUnregistered(_ urls: [URL]) { activeURLs.subtract(urls) }
}
