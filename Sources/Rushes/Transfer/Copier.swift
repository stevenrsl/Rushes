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

    /// A file written to every drive and synced there, under its hidden
    /// name: not yet read back, not yet named. `verify` finishes it,
    /// `discard` takes it back.
    struct Written: Sendable {
        let source: URL
        let partials: [URL]
        let targets: [URL]
        /// The volume of each copy, so drives that are separate disks are read
        /// back at the same time, and a volume known to refuse `RENAME_EXCL`
        /// is not asked again.
        let devices: [dev_t]
        let hash: UInt64
    }

    /// Copies `source` to each of `targets` and checks every copy.
    /// `advance` is called with bytes read from the card, then with bytes read
    /// back from the drives (`true`). `size` is what the scan saw: a
    /// card that hands back fewer bytes, or more, is not believed. Returns the
    /// XXH64 of the file.
    static func copy(
        _ source: URL,
        to targets: [URL],
        size: Int64? = nil,
        modified: Date,
        created: Date,
        isCancelled: @escaping @Sendable () -> Bool,
        advance: (Int64, Bool) -> Void
    ) throws -> String {
        let buffers = Buffers()
        let written = try write(source, to: targets, size: size, modified: modified, created: created,
                                buffers: buffers, isCancelled: isCancelled) { advance($0, false) }
        return try verify(written, buffers: buffers, isCancelled: isCancelled) { advance($0, true) }
    }

    /// The first half of `copy`: the card read once, every drive written and
    /// synced. A backup reads the next file from the card while this one is
    /// read back, so the card never waits for the drives.
    static func write(
        _ source: URL,
        to targets: [URL],
        size: Int64? = nil,
        modified: Date,
        created: Date,
        buffers: Buffers,
        isCancelled: () -> Bool,
        advance: (Int64) -> Void
    ) throws -> Written {
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
        var devices: [dev_t] = []
        defer { for fd in outputs { close(fd) } }
        for partial in partials {
            unlink(partial.path) // A leftover from a backup that was cut off.
            let fd = open(partial.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
            guard fd >= 0 else { throw posix(errno, "Écriture impossible sur \(volumeName(of: partial))") }
            _ = fcntl(fd, F_NOCACHE, 1)
            outputs.append(fd)
            var info = stat()
            devices.append(fstat(fd, &info) == 0 ? info.st_dev : -1)
        }

        var read: Int64 = 0
        let hash = try stream(from: input, to: outputs, source: source, targets: targets, buffers: buffers, isCancelled: isCancelled) {
            read += $0
            advance($0)
        }
        // A reader that gives up early says "end of file", and a copy of what
        // it did give would check out perfectly against itself.
        if let size, read != size {
            throw Failure(message: "La carte a rendu \(read) octets de « \(source.lastPathComponent) » au lieu de \(size) : le lecteur ou la carte a peut-être un problème.")
        }

        // The camera's dates go on through the open file, before the sync
        // that makes them last with the bytes. Separate disks sync at once;
        // two copies on one disk wait for each other, which is faster there.
        let fds = outputs
        let synced = Results(count: fds.count)
        func sync(_ i: Int) {
            setDates(fds[i], modified: modified, created: created)
            synced.set(i, fsync(fds[i]) == 0 ? 0 : errno)
        }
        if separateDisks(devices) {
            DispatchQueue.concurrentPerform(iterations: fds.count, execute: sync)
        } else {
            fds.indices.forEach(sync)
        }
        for (code, partial) in zip(synced.values, partials) where code != 0 {
            throw posix(Int32(code), "Écriture incomplète sur \(volumeName(of: partial))")
        }
        for fd in outputs { close(fd) }
        outputs.removeAll()

        succeeded = true
        return Written(source: source, partials: partials, targets: targets, devices: devices, hash: hash)
    }

    /// The second half of `copy`: every drive's copy read back around the
    /// cache and compared with the card, then named on every drive or on
    /// none. Whatever goes wrong, the hidden copies go.
    static func verify(
        _ written: Written,
        buffers: Buffers,
        isCancelled: @escaping @Sendable () -> Bool,
        advance: (Int64) -> Void
    ) throws -> String {
        let (partials, targets, hash) = (written.partials, written.targets, written.hash)
        var succeeded = false
        defer {
            if !succeeded { discard(written) }
        }

        // Separate disks are read back at once, each at its own pace. Two
        // copies on one disk are read one after the other: reading both at
        // once was two to three times slower on one SSD (2026-09-29).
        let parallel = separateDisks(written.devices)
        let checks = Results(count: partials.count)
        let errors = ErrorBox()
        let lock = NSLock()
        func readBack(_ i: Int) {
            do {
                let check = try readHash(of: partials[i], buffers: buffers, isCancelled: isCancelled) { bytes in
                    lock.withLock { advance(bytes) }
                }
                checks.set(i, Int64(bitPattern: check))
            } catch {
                errors.set(error)
            }
        }
        if parallel {
            DispatchQueue.concurrentPerform(iterations: partials.count, execute: readBack)
        } else {
            for i in partials.indices {
                readBack(i)
                if errors.value != nil { break }
            }
        }
        if let error = errors.value { throw error }
        for (i, target) in targets.enumerated() {
            let check = UInt64(bitPattern: checks.values[i])
            guard check == hash else {
                throw Failure(message: "La copie de « \(target.lastPathComponent) » sur \(volumeName(of: target)) ne correspond pas à la carte (xxh64 \(hex(check)) au lieu de \(hex(hash))).")
            }
        }

        // Named on every drive, or on none: a name given on the first drive
        // and refused on the second would leave a finished file outside any
        // record, and the shot copied again under another number tomorrow.
        var named: [URL] = []
        do {
            for (i, (partial, target)) in zip(partials, targets).enumerated() {
                try name(partial, target, device: written.devices[i])
                named.append(target)
            }
        } catch {
            for target in named { unlink(target.path) }
            throw error
        }
        succeeded = true
        return hex(hash)
    }

    /// Whether each copy lies on a volume of its own, so working on all of
    /// them at once is working on several disks at once.
    private static func separateDisks(_ devices: [dev_t]) -> Bool {
        devices.count > 1 && Set(devices).count == devices.count && !devices.contains(-1)
    }

    /// Takes back a file written but never named.
    static func discard(_ written: Written) {
        for partial in written.partials { unlink(partial.path) }
    }

    /// The camera's dates, set on the open copy.
    private static func setDates(_ fd: Int32, modified: Date, created: Date) {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(ATTR_CMN_CRTIME | ATTR_CMN_MODTIME)
        // In the order of their bits: creation, then modification.
        var times = (timespec(created), timespec(modified))
        _ = fsetattrlist(fd, &list, &times, MemoryLayout.size(ofValue: times), 0)
    }

    /// Volumes that answered `ENOTSUP` to `RENAME_EXCL`, so the next copy goes
    /// straight to the reservation. Only ever a shortcut to the slower of two
    /// safe ways: a device number given again to another volume costs time,
    /// never a file.
    private static let noExclusiveRename = Locked(Set<dev_t>())

    /// Gives a checked copy its final name without ever replacing a file.
    ///
    /// `renamex_np(RENAME_EXCL)` does it in one atomic step, but only on a file
    /// system that supports it: exFAT and FAT32, the format the drives of a
    /// shoot are sold in, answer `ENOTSUP` and would leave every copy nameless.
    /// There, the name is reserved first with an exclusive create, which is
    /// atomic too, and the copy is renamed over that reservation of ours. Cut
    /// off in between, it leaves an empty file, which the planner reads as a
    /// name already taken: a conflict, never a file that looks finished.
    static func name(_ partial: URL, _ target: URL) throws {
        try name(partial, target, device: -1)
    }

    private static func name(_ partial: URL, _ target: URL, device: dev_t) throws {
        if device == -1 || !noExclusiveRename.read({ $0.contains(device) }) {
            if renamex_np(partial.path, target.path, UInt32(RENAME_EXCL)) == 0 { return }
            let code = errno
            if code == EEXIST { throw appeared(target) }
            // Some network and FUSE file systems say EINVAL or ENOSYS for the
            // flag they do not know.
            guard [ENOTSUP, EINVAL, ENOSYS].contains(code) else { throw posix(code, "Impossible de nommer « \(target.lastPathComponent) »") }
            if device != -1 { noExclusiveRename.write { _ = $0.insert(device) } }
        }

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
    /// last one is written and hashed.
    private static func stream(
        from input: Int32,
        to outputs: [Int32],
        source: URL,
        targets: [URL],
        buffers: Buffers,
        isCancelled: () -> Bool,
        advance: (Int64) -> Void
    ) throws -> UInt64 {
        let front = buffers.take()
        let back = buffers.take()
        defer {
            buffers.give(front)
            buffers.give(back)
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
            // Shared with the writers and the reader for as long as
            // `group.wait()` below: neither buffer is touched again until
            // every one of them has returned.
            nonisolated(unsafe) let chunk = UnsafeRawBufferPointer(start: current, count: count)
            nonisolated(unsafe) let ahead = next
            for (fd, target) in zip(outputs, targets) {
                queue.async(group: group) {
                    if !writeFully(fd, chunk) {
                        errors.set(posix(errno, "Écriture impossible sur \(volumeName(of: target))", alwaysFatal: true))
                    }
                }
            }
            let nextCount = ReadResult()
            queue.async(group: group) {
                nextCount.value = Result { try readFully(input, into: ahead, from: source) }
            }
            hasher.update(chunk)
            group.wait()
            if let error = errors.value { throw error }
            advance(Int64(count))
            count = try nextCount.value!.get()
            swap(&current, &next)
        }
        return hasher.digest()
    }

    /// Reads a copy back from the drive, around its cache, and hashes it.
    private static func readHash(of url: URL, buffers: Buffers = Buffers(), isCancelled: () -> Bool, advance: (Int64) -> Void) throws -> UInt64 {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw posix(errno, "Relecture impossible sur \(volumeName(of: url))", at: url) }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)
        let buffer = buffers.take()
        defer { buffers.give(buffer) }
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

    /// The same, around the Mac's cache, with progress and a way to stop.
    static func hash(of url: URL, isCancelled: () -> Bool, advance: (Int64) -> Void) throws -> String {
        hex(try readHash(of: url, isCancelled: isCancelled, advance: advance))
    }

    /// The 8 MB buffers a backup reads and writes through, kept from one file
    /// to the next rather than asked of the system twice per file, and given
    /// back when the backup ends.
    final class Buffers: @unchecked Sendable {
        private let lock = NSLock()
        private var free: [UnsafeMutableRawPointer] = []

        func take() -> UnsafeMutableRawPointer {
            lock.withLock { free.popLast() } ?? .allocate(byteCount: chunkSize, alignment: 16384)
        }

        func give(_ buffer: UnsafeMutableRawPointer) {
            lock.withLock { free.append(buffer) }
        }

        deinit {
            for buffer in free { buffer.deallocate() }
        }
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
            let n = Darwin.write(fd, chunk.baseAddress! + written, chunk.count - written)
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

/// What the parallel reads and syncs found, one slot each.
private final class Results: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Int64]
    init(count: Int) { stored = Array(repeating: 0, count: count) }
    var values: [Int64] { lock.withLock { stored } }
    func set(_ index: Int, _ value: Int64) { lock.withLock { stored[index] = value } }
    func set(_ index: Int, _ value: Int32) { set(index, Int64(value)) }
}

/// The next chunk read while the last is written, handed over by `group.wait()`.
private final class ReadResult: @unchecked Sendable {
    var value: Result<Int, Error>?
}

/// A value shared across threads.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func read<T>(_ body: (Value) -> T) -> T { lock.withLock { body(value) } }
    func write<T>(_ body: (inout Value) -> T) -> T { lock.withLock { body(&value) } }
}

private extension timespec {
    init(_ date: Date) {
        let seconds = date.timeIntervalSince1970.rounded(.down)
        self.init(tv_sec: Int(seconds), tv_nsec: Int((date.timeIntervalSince1970 - seconds) * 1_000_000_000))
    }
}

/// The first error of the parallel writes.
private final class ErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Error?
    var value: Error? { lock.withLock { stored } }
    func set(_ error: Error) { lock.withLock { if stored == nil { stored = error } } }
}
