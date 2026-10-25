import Darwin
import Foundation
import ProcessControl

public final class Limiter {
    public let identity: ProcessIdentity
    public let percent: Double
    public let includesHelpers: Bool
    public private(set) var memberIDs: Set<ProcessIdentity>
    private let process = Process()
    private let input = Pipe()
    private let errors = Pipe()
    private var inputClosed = false

    public var isRunning: Bool { process.isRunning }
    var controllerPID: Int32 { process.processIdentifier }

    public init(
        target: ProcessSnapshot, percent: Double, executable: URL,
        includesHelpers: Bool = false, members: [ProcessSnapshot] = []
    ) throws {
        try Self.validate(target: target, percent: percent)
        identity = target.id
        self.percent = percent
        self.includesHelpers = includesHelpers
        memberIDs = [target.id]
        for member in members { try Self.validate(target: member, percent: percent) }
        process.executableURL = executable
        process.arguments = [
            String(identity.pid), String(identity.seconds), String(identity.microseconds),
            String(percent),
        ]
        if includesHelpers { process.arguments?.append("--group") }
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw ProcessFailure(
                operation: String(localized: "Protect controller pipe against disconnects"),
                code: errno)
        }
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        try process.run()
        input.fileHandleForReading.closeFile()
        errors.fileHandleForWriting.closeFile()
        do {
            if includesHelpers { try updateMembers([target] + members) }
        } catch {
            stop()
            throw error
        }
    }

    /// Membership changes do not restart the shared budget or leave old helpers suspended.
    public func updateMembers(_ members: [ProcessSnapshot]) throws {
        guard includesHelpers, !inputClosed, process.isRunning else {
            throw ProcessFailure(
                operation: failure() ?? String(localized: "The group controller is not running"),
                code: EPIPE)
        }
        let desired = Set(members.map(\.id)).union([identity])
        for id in memberIDs.subtracting(desired) {
            try send(operation: AP_MEMBER_REMOVE, id: id)
            memberIDs.remove(id)
        }
        for member in members where !memberIDs.contains(member.id) {
            try Self.validate(target: member, percent: percent)
            try send(operation: AP_MEMBER_ADD, id: member.id, uid: member.uid)
            memberIDs.insert(member.id)
        }
    }

    private func send(
        operation: APControlOperation, id: ProcessIdentity, uid: UInt32 = getuid()
    ) throws {
        var message = APControlMessage()
        message.operation = operation
        message.identity.pid = id.pid
        message.identity.uid = uid
        message.identity.start_seconds = id.seconds
        message.identity.start_microseconds = id.microseconds
        try withUnsafeBytes(of: &message) {
            try input.fileHandleForWriting.write(contentsOf: Data($0))
        }
    }

    public static func validate(target: ProcessSnapshot, percent: Double) throws {
        guard target.canControl else {
            throw ProcessFailure(
                operation: String(
                    localized: "This process is protected, stopped, or belongs to another user"),
                code: EPERM)
        }
        try validatePercent(percent)
    }

    public static func validatePercent(_ percent: Double) throws {
        guard percent.isFinite, percent >= 1,
            percent <= Double(ProcessInfo.processInfo.activeProcessorCount * 100)
        else {
            let maximumPercent = ProcessInfo.processInfo.activeProcessorCount * 100
            throw ProcessFailure(
                operation: String(
                    format: String(localized: "CPU limit must be between 1 and %d%%"),
                    locale: .current,
                    arguments: [maximumPercent]
                ),
                code: EINVAL)
        }
    }

    @discardableResult
    public func stop() -> String? {
        if !inputClosed {
            inputClosed = true
            input.fileHandleForWriting.closeFile()
        }
        process.waitUntilExit()
        return failure()
    }

    public func failure() -> String? {
        guard !process.isRunning, process.terminationStatus != 0 else { return nil }
        let detail = String(
            decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        guard detail.isEmpty else { return detail }
        return String(
            format: String(
                localized:
                    "CPU controller for PID %d exited with status %d. Remove and reapply the limit."
            ),
            locale: .current,
            arguments: [identity.pid, process.terminationStatus]
        )
    }

    deinit {
        input.fileHandleForWriting.closeFile()
    }
}
