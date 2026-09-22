import Darwin
import Foundation

/// Copies one file from the card to every drive at once, then proves it.
///
/// The card is read once, in 8 MB chunks, and each chunk is hashed and written
/// to every drive in parallel while the next one is read. Each drive's copy is
/// then read back and hashed again. Both reads and writes bypass the Mac's
/// cache (`F_NOCACHE`): a check that reads back what is still in memory proves
/// nothing about the drive.
///
/// A copy is written under a hidden name beside its final one and named only
/// once it matches, and only if that name is free (see `name(_:_:)`): a file
/// that exists is never replaced, and a copy cut off by a pulled cable never
/// looks finished. The card is only ever read.
enum Copier {
    static let chunkSize = 8 << 20

    struct Failure: LocalizedError, Sendable {
        let message: String
        /// Stops the whole backup, not just this file: the drive is full or gone.
        var fatal = false
        var errorDescription: String? { message }
    }

    /// Hidden name for a copy in progress, beside the final name.
    static func partialURL(for final: URL) -> URL {
        final.deletingLastPathComponent().appendingPathComponent(".\(final.lastPathComponent).rushes-partial")
    }

    /// Copies `source` to each of `targets` and checks every copy.
    /// `advance` is called with bytes read from the card, then with bytes read
    /// back from the drives (`true`). Returns the XXH64 of the file.
    static func copy(
        _ source: URL,
        to targets: [URL],
        modified: Date,
        created: Date,
        isCancelled: @escaping () -> Bool,
        advance: (Int64, Bool) -> Void
    ) throws -> String {
        let partials = targets.map(partialURL(for:))
        var succeeded = false
        defer {
            if !succeeded { for partial in partials { unlink(partial.path) } }
        }

        for target in targets {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: target.path) {
                throw Failure(message: "« \(target.lastPathComponent) » existe déjà sur \(volumeName(of: target)). Rien n'a été remplacé.")
            }
        }

        let input = open(source.path, O_RDONLY)
        guard input >= 0 else { throw posix(errno, "Lecture impossible de « \(source.lastPathComponent) »", at: source) }
        defer { close(input) }
        _ = fcntl(input, F_NOCACHE, 1)

        var outputs: [Int32] = []
        defer { for fd in outputs { close(fd) } }
        for partial in partials {
            unlink(partial.path) // A leftover from a backup that was cut off.
            let fd = open(partial.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
            guard fd >= 0 else { throw posix(errno, "Écriture impossible sur \(volumeName(of: partial))") }
            _ = fcntl(fd, F_NOCACHE, 1)
            outputs.append(fd)
        }

        let hash = try stream(from: input, to: outputs, source: source, targets: targets, isCancelled: isCancelled) { advance($0, false) }

        for (fd, partial) in zip(outputs, partials) {
            guard fsync(fd) == 0 else { throw posix(errno, "Écriture incomplète sur \(volumeName(of: partial))") }
        }
        for fd in outputs { close(fd) }
        outputs.removeAll()

        for (partial, target) in zip(partials, targets) {
            let check = try readHash(of: partial, isCancelled: isCancelled) { advance($0, true) }
            guard check == hash else {
                throw Failure(message: "La copie de « \(target.lastPathComponent) » sur \(volumeName(of: target)) ne correspond pas à la carte (xxh64 \(hex(check)) au lieu de \(hex(hash))).")
            }
        }

        for (partial, target) in zip(partials, targets) {
            try? FileManager.default.setAttributes([.modificationDate: modified, .creationDate: created], ofItemAtPath: partial.path)
            try name(partial, target)
        }
        succeeded = true
        return hex(hash)
    }

    /// Gives a checked copy its final name without ever replacing a file.
    ///
    /// `renamex_np(RENAME_EXCL)` does it in one atomic step, but only on a file
    /// system that supports it: exFAT and FAT32, the format the drives of a
    /// shoot are sold in, answer `ENOTSUP` and would leave every copy nameless.
    /// There, the name is reserved first with an exclusive create, which is
    /// atomic too, and the copy is renamed over that reservation of ours. Cut
    /// off in between, it leaves an empty file, which the planner reads as a
    /// name already taken: a conflict, never a file that looks finished.
    private static func name(_ partial: URL, _ target: URL) throws {
        if renamex_np(partial.path, target.path, UInt32(RENAME_EXCL)) == 0 { return }
        let code = errno
        if code == EEXIST { throw appeared(target) }
        guard code == ENOTSUP else { throw posix(code, "Impossible de nommer « \(target.lastPathComponent) »") }

        let reserved = open(target.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard reserved >= 0 else {
            let code = errno
            if code == EEXIST { throw appeared(target) }
            throw posix(code, "Impossible de nommer « \(target.lastPathComponent) »")
        }
        close(reserved)
        guard rename(partial.path, target.path) == 0 else {
            let code = errno
            unlink(target.path)
            throw posix(code, "Impossible de nommer « \(target.lastPathComponent) »")
        }
    }

    private static func appeared(_ target: URL) -> Failure {
        Failure(message: "« \(target.lastPathComponent) » est apparu sur \(volumeName(of: target)) pendant la copie. Rien n'a été remplacé.")
    }

    /// Reads the card and writes every drive, the next chunk read while the
    /// last one is written.
    private static func stream(
        from input: Int32,
        to outputs: [Int32],
        source: URL,
        targets: [URL],
        isCancelled: () -> Bool,
        advance: (Int64) -> Void
    ) throws -> UInt64 {
        let front = UnsafeMutableRawPointer.allocate(byteCount: chunkSize, alignment: 16384)
        let back = UnsafeMutableRawPointer.allocate(byteCount: chunkSize, alignment: 16384)
        defer {
            front.deallocate()
            back.deallocate()
        }

        var hasher = XXHash64()
        var current = front
        var next = back
        var count = try readFully(input, into: current, from: source)
        let queue = DispatchQueue.global(qos: .userInitiated)
        let errors = ErrorBox()

        while count > 0 {
            if isCancelled() { throw CancellationError() }
            let group = DispatchGroup()
            let chunk = UnsafeRawBufferPointer(start: current, count: count)
            for (fd, target) in zip(outputs, targets) {
                queue.async(group: group) {
                    if !writeFully(fd, chunk) {
                        errors.set(posix(errno, "Écriture impossible sur \(volumeName(of: target))", alwaysFatal: true))
                    }
                }
            }
            hasher.update(chunk)
            let nextCount = Result { try readFully(input, into: next, from: source) }
            group.wait()
            if let error = errors.value { throw error }
            advance(Int64(count))
            count = try nextCount.get()
            swap(&current, &next)
        }
        return hasher.digest()
    }

    /// Reads a copy back from the drive, around its cache, and hashes it.
    private static func readHash(of url: URL, isCancelled: () -> Bool, advance: (Int64) -> Void) throws -> UInt64 {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw posix(errno, "Relecture impossible sur \(volumeName(of: url))", at: url) }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunkSize, alignment: 16384)
        defer { buffer.deallocate() }
        var hasher = XXHash64()
        while true {
            if isCancelled() { throw CancellationError() }
            let count = try readFully(fd, into: buffer, from: url)
            if count == 0 { break }
            hasher.update(UnsafeRawBufferPointer(start: buffer, count: count))
            advance(Int64(count))
        }
        return hasher.digest()
    }

    /// Hashes a file on its own, for tests and for checking a drive later.
    static func hash(of url: URL) throws -> String {
        hex(try readHash(of: url, isCancelled: { false }, advance: { _ in }))
    }

    private static func readFully(_ fd: Int32, into buffer: UnsafeMutableRawPointer, from url: URL) throws -> Int {
        var filled = 0
        while filled < chunkSize {
            let n = read(fd, buffer + filled, chunkSize - filled)
            if n == 0 { break }
            if n < 0 {
                if errno == EINTR { continue }
                throw posix(errno, "La lecture de « \(url.lastPathComponent) » s’est interrompue", at: url)
            }
            filled += n
        }
        return filled
    }

    private static func writeFully(_ fd: Int32, _ chunk: UnsafeRawBufferPointer) -> Bool {
        var written = 0
        while written < chunk.count {
            let n = write(fd, chunk.baseAddress! + written, chunk.count - written)
            if n < 0 {
                if errno == EINTR { continue }
                return false
            }
            written += n
        }
        return true
    }

    static func hex(_ value: UInt64) -> String { String(format: "%016llx", value) }

    static func volumeName(of url: URL) -> String {
        (try? url.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? url.deletingLastPathComponent().lastPathComponent
    }

    /// A failure from a system call, whose `errno` the caller reads first: the
    /// message itself asks the file system for a volume name, which would
    /// overwrite it and report a full disk as "No such file or directory".
    ///
    /// A full disk, a card or a drive that is gone stops the whole backup. A
    /// bad sector (`EIO`) costs this file only, as long as the card is still
    /// there: one unreadable shot must not cost the two other cards.
    private static func posix(_ code: Int32, _ message: String, at url: URL? = nil, alwaysFatal: Bool = false) -> Failure {
        if code == ENOSPC {
            return Failure(message: message + " : le disque est plein.", fatal: true)
        }
        var gone = [ENXIO, EIO, ENODEV, ENOENT].contains(code)
        // The card answers for itself: its folder still readable means the
        // reader is there and this one file is the one at fault.
        if gone, let url { gone = access(url.deletingLastPathComponent().path, R_OK) != 0 }
        return Failure(message: "\(message) (\(String(cString: strerror(code)))).", fatal: alwaysFatal || gone)
    }
}

/// The first error of the parallel writes.
private final class ErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Error?
    var value: Error? { lock.withLock { stored } }
    func set(_ error: Error) { lock.withLock { if stored == nil { stored = error } } }
}
