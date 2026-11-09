import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import MijiaCore
import MijiaLAN

/// No environment options, Keychain access, discovery or writes. Real communication requires every
/// axis plus --execute and --baseline-normal; otherwise this command only prints a plan.
enum CurtainExperiment {
    struct Options: Encodable, Sendable {
        let policy: MiioCommunicationPolicy
        let slot: Int
        let reads: Int
        let interval: Int
        let execute: Bool
        let baselineNormal: Bool
        let logDirectory: String?
    }
    static func parse(_ args: [String]) throws -> Options {
        var values: [String: String] = [:], flags: Set<String> = []
        let valueKeys: Set<String> = ["--socket", "--layout", "--hello", "--stamp", "--slot", "--reads", "--interval", "--log-directory"]
        var index = 0
        while index < args.count {
            let key = args[index]
            if ["--execute", "--baseline-normal"].contains(key) {
                guard flags.insert(key).inserted else { throw invalid() }; index += 1
            } else {
                guard valueKeys.contains(key), values[key] == nil, index + 1 < args.count else { throw invalid() }
                values[key] = args[index + 1]; index += 2
            }
        }
        guard let socket = values["--socket"].flatMap(MiioCommunicationPolicy.Socket.init(rawValue:)),
              let layout = values["--layout"].flatMap(MiioCommunicationPolicy.Layout.init(rawValue:)),
              let hello = values["--hello"].flatMap(MiioCommunicationPolicy.Hello.init(rawValue:)),
              let stamp = values["--stamp"].flatMap(MiioCommunicationPolicy.Stamp.init(rawValue:)),
              let slot = values["--slot"].flatMap(Int.init), (1...256).contains(slot),
              let reads = values["--reads"].flatMap(Int.init), (1...48).contains(reads),
              let interval = values["--interval"].flatMap(Int.init), (5...300).contains(interval),
              !flags.contains("--execute") || (flags.contains("--baseline-normal") && values["--log-directory"] != nil) else { throw invalid() }
        return Options(policy: .init(socket: socket, layout: layout, hello: hello, stamp: stamp), slot: slot,
                       reads: reads, interval: interval, execute: flags.contains("--execute"),
                       baselineNormal: flags.contains("--baseline-normal"), logDirectory: values["--log-directory"])
    }
    static func invalid() -> MiioError { .badResponse("curtain-experiment requires explicit --socket fresh|stable --layout full|adaptive|single --hello silence|periodic --stamp replyPlusOne|helloAnchored --slot N --reads 1...48 --interval 5...300; real reads also require --execute --baseline-normal --log-directory NEW_DIRECTORY. No writes are supported.") }
    static func run(_ args: [String], port: UInt16) async throws {
        let options = try parse(args)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        print(String(decoding: try encoder.encode(options), as: UTF8.self))
        guard options.execute else { return } // Does not even read stdin in plan mode.
        guard let config = LocalHomeConfig.decode(FileHandle.standardInput.readDataToEndOfFile()),
              options.slot <= config.devices.count, let directory = options.logDirectory else { throw invalid() }
        // Slot is the private input list's order, not an alias from an earlier App run.
        let device = config.devices[options.slot - 1]
        guard device.model == CurtainValidationSession.model, device.specType == CurtainValidationSession.specification else { throw DeviceControlError.wrongDevice }
        let destination = URL(fileURLWithPath: directory, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw MiioError.badResponse("Experiment log directory must be new") }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let journal = DeviceEventLog(fileURL: destination.appendingPathComponent("traffic.jsonl"), scope: .experiment)
        journal.register([device.did])
        let session = try CurtainControlSession.experiment(device: device, policy: options.policy, journal: journal, port: port)
        let worker = Task { () -> Int in
            var completed = 0
            var lastStart: ContinuousClock.Instant?
        for _ in 0..<options.reads {
            do {
                if let lastStart { try await Task.sleep(until: lastStart.advanced(by: .seconds(options.interval)), clock: .continuous) }
                try Task.checkCancellation()
                lastStart = .now
                _ = try await session.poll(source: .experiment)
                completed += 1
                // Do not continue a hardware experiment after even a rejected/late datagram.
                if journal.snapshot().contains(where: { $0.outcome == .discarded }) { break }
            } catch {
                journal.record(device.did, source: .experiment, stage: .finished, outcome: .paused,
                    reason: DeviceEventLog.reason(error), code: DeviceEventLog.code(error))
                break
            }
        }
            return completed
        }
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        let previous = signal(SIGINT, SIG_IGN)
        interrupt.setEventHandler { worker.cancel(); Task { await session.end() } }
        interrupt.activate()
        defer { interrupt.cancel(); _ = signal(SIGINT, previous) }
        let completed = await worker.value
        await session.end(); journal.flush()
        print("experiment_finished completed_rounds=\(completed) writes=0; retained logs are in the explicitly selected directory")
    }
}
