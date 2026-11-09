import Foundation
import MijiaCore
import MijiaLAN
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// No calls to CurtainControlSession.poll. Baselines are explicit, separate single-round invocations.
enum CurtainAttributes {
    struct Options: Encodable, Sendable {
        let plan: CurtainAttributePlan
        let slot: Int
        let execute: Bool
        let baselineNormal: Bool
        let logDirectory: String?
    }
    static func invalid() -> MiioError { .badResponse("curtain-attributes requires --properties 2.PIID[,2.PIID...] (only 2,3,4,5,9,10; ordered, unique), --packet-layout batch|single --phase baseline-before|probe|baseline-after --slot N --rounds 1...48 --interval 5...300. Baseline phases require exactly 2.2,2.3,2.4,2.5,2.9,2.10, batch, one round. Real reads require --execute --baseline-normal --log-directory NEW_DIRECTORY and private config on stdin. No writes, automatic full queries or recovery.") }
    static func parse(_ args: [String]) throws -> Options {
        let keys: Set<String> = ["--properties", "--packet-layout", "--phase", "--slot", "--rounds", "--interval", "--log-directory"]
        var values: [String: String] = [:], flags: Set<String> = [], index = 0
        while index < args.count {
            let key = args[index]
            if ["--execute", "--baseline-normal"].contains(key) {
                guard flags.insert(key).inserted else { throw invalid() }; index += 1
            } else {
                guard keys.contains(key), values[key] == nil, index + 1 < args.count else { throw invalid() }
                values[key] = args[index + 1]; index += 2
            }
        }
        guard let raw = values["--properties"], let layout = values["--packet-layout"].flatMap(CurtainAttributePlan.Layout.init(rawValue:)),
              let phase = values["--phase"].flatMap(CurtainAttributePlan.Phase.init(rawValue:)),
              let slot = values["--slot"].flatMap(Int.init), (1...256).contains(slot),
              let rounds = values["--rounds"].flatMap(Int.init), let interval = values["--interval"].flatMap(Int.init),
              !flags.contains("--execute") || (flags.contains("--baseline-normal") && values["--log-directory"] != nil) else { throw invalid() }
        let pieces = raw.split(separator: ",", omittingEmptySubsequences: false)
        var ids: [Int] = []
        for piece in pieces {
            guard let id = CurtainAttributePlan.whitelist.first(where: { piece == "2.\($0)" }) else { throw invalid() }
            ids.append(id)
        }
        let plan: CurtainAttributePlan
        do { plan = try .init(properties: ids, layout: layout, phase: phase, rounds: rounds, intervalSeconds: interval) }
        catch { throw invalid() }
        return .init(plan: plan, slot: slot, execute: flags.contains("--execute"), baselineNormal: flags.contains("--baseline-normal"), logDirectory: values["--log-directory"])
    }
    enum Finish: String, Encodable, Sendable { case complete, failed, cancelled }
    struct Report: Encodable, Sendable {
        let outcome: Finish
        let plan: CurtainAttributePlan
        let completedRounds: Int
        let reason: DeviceEventLog.Reason?
        let code: Int?
        let exposure: CurtainAttributeExposure
        let elapsedMilliseconds: Int64
        let countScope = "Actual Mac sends in this invocation only; no hardware-global threshold or prior phone/cloud accounting"
    }
    static func run(_ args: [String], port: UInt16) async throws {
        let options = try parse(args)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        print(String(decoding: try encoder.encode(options), as: UTF8.self))
        guard options.execute else { return } // No stdin, Keychain, socket or file access in plan mode.
        guard let config = LocalHomeConfig.decode(FileHandle.standardInput.readDataToEndOfFile()),
              options.slot <= config.devices.count, let path = options.logDirectory, path.hasPrefix("/") else { throw invalid() }
        let device = config.devices[options.slot - 1]
        guard device.model == CurtainValidationSession.model, device.specType == CurtainValidationSession.specification,
              MiioToken.parse(device.token) != nil, UInt32(device.did).map({ $0 > 0 }) == true else { throw DeviceControlError.wrongDevice }
        guard mkdir(path, 0o700) == 0 else { throw MiioError.badResponse("Attribute log directory must be new and writable") }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try encoder.encode(options).write(to: directory.appendingPathComponent("plan.json"), options: .atomic)
        let journal = DeviceEventLog(fileURL: directory.appendingPathComponent("traffic.jsonl"), scope: .experiment)
        journal.register([device.did])
        let probe = try CurtainAttributeProbe(device: device, plan: options.plan, journal: journal, port: port)
        let origin = ContinuousClock.now
        let worker = Task { () -> (Int, Finish, DeviceEventLog.Reason?, Int?) in
            var completed = 0
            var previousStart: ContinuousClock.Instant?
            for _ in 0..<options.plan.rounds {
                do {
                    if let previousStart { try await Task.sleep(until: previousStart.advanced(by: .seconds(options.plan.intervalSeconds)), clock: .continuous) }
                    try Task.checkCancellation()
                    previousStart = .now
                    try await probe.readRound()
                    completed += 1
                    journal.flush()
                    if journal.storageFailed { return (completed, .failed, .configuration, nil) }
                } catch { return (completed, error is CancellationError ? .cancelled : .failed, DeviceEventLog.reason(error), DeviceEventLog.code(error)) }
            }
            return (completed, .complete, nil, nil)
        }
        let interrupts = [SIGINT, SIGTERM].map { number in
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            let previous = signal(number, SIG_IGN)
            source.setEventHandler { worker.cancel(); Task { await probe.end() } }
            source.activate(); return (source, number, previous)
        }
        defer { for (source, number, previous) in interrupts { source.cancel(); _ = signal(number, previous) } }
        let (completed, outcome, reason, code) = await worker.value
        await probe.end()
        let elapsed = origin.duration(to: .now).components
        let report = Report(outcome: outcome, plan: options.plan, completedRounds: completed, reason: reason, code: code,
            exposure: await probe.exposure(), elapsedMilliseconds: elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000)
        let data = try encoder.encode(report)
        try data.write(to: directory.appendingPathComponent("result.json"), options: .atomic)
        print(String(decoding: data, as: UTF8.self))
        guard outcome == .complete else { throw MiioError.badResponse("Attribute probe stopped; inspect sanitized result and traffic. No next stage, baseline, retry or recovery was sent.") }
    }
}
