import Foundation
import Glibc

enum PrivateAtomicFileWriter {
    struct Syscalls {
        let close: (Int32) -> Int32
        let fsync: (Int32) -> Int32

        init(
            close: @escaping (Int32) -> Int32 = { Glibc.close($0) },
            fsync: @escaping (Int32) -> Int32 = { Glibc.fsync($0) }
        ) {
            self.close = close
            self.fsync = fsync
        }
    }

    static func write(
        _ data: Data,
        to destination: URL,
        fileManager: FileManager = .default,
        syscalls: Syscalls = Syscalls()
    ) throws {
        let directory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let temporary = directory.appendingPathComponent(
            ".\(destination.lastPathComponent).openusage-\(UUID().uuidString)"
        )
        let descriptor = temporary.path.withCString {
            Glibc.open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
        }
        guard descriptor >= 0 else { throw posixError(path: temporary.path) }

        var openDescriptor = descriptor
        defer {
            if openDescriptor >= 0 {
                _ = syscalls.close(openDescriptor)
            }
            try? fileManager.removeItem(at: temporary)
        }

        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Glibc.write(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    bytes.count - offset
                )
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw posixError(path: temporary.path) }
                offset += written
            }
        }
        guard syscalls.fsync(descriptor) == 0 else { throw posixError(path: temporary.path) }
        openDescriptor = -1
        guard syscalls.close(descriptor) == 0 else { throw posixError(path: temporary.path) }
        let renameResult = temporary.path.withCString { source in
            destination.path.withCString { target in
                Glibc.rename(source, target)
            }
        }
        guard renameResult == 0 else { throw posixError(path: destination.path) }

        let directoryDescriptor = directory.path.withCString {
            Glibc.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        guard directoryDescriptor >= 0 else { throw posixError(path: directory.path) }
        var openDirectoryDescriptor = directoryDescriptor
        defer {
            if openDirectoryDescriptor >= 0 {
                _ = syscalls.close(openDirectoryDescriptor)
            }
        }

        guard syscalls.fsync(directoryDescriptor) == 0 else {
            throw posixError(path: directory.path)
        }
        openDirectoryDescriptor = -1
        guard syscalls.close(directoryDescriptor) == 0 else {
            throw posixError(path: directory.path)
        }
    }

    static func isPrivateFile(
        _ path: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: path.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o777 == 0o600,
              let owner = attributes[.ownerAccountID] as? NSNumber,
              owner.uint32Value == getuid()
        else {
            return false
        }
        return true
    }

    private static func posixError(path: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSFilePathErrorKey: path]
        )
    }
}
