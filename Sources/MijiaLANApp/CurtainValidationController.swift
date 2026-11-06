import Foundation
import Observation
import MijiaCore
import MijiaLAN

@Observable @MainActor
final class CurtainValidationController {
    private let api: LANMiotAPI
    @ObservationIgnored private var session: CurtainValidationSession?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored var prepare: @MainActor () async throws -> Void = {}
    private(set) var deviceID: String?
    private(set) var state: CurtainValidationSession.State?
    private(set) var isWorking = false
    private(set) var error: String?

    init(api: LANMiotAPI) { self.api = api }

    func enable(_ device: LocalDevice) {
        guard !isWorking else { return }
        let id = UUID(); generation = id
        deviceID = device.did; session = nil; state = nil; error = nil; isWorking = true
        task = Task {
            defer { if generation == id { isWorking = false; task = nil } }
            do {
                await api.endCurtainValidation()
                try Task.checkCancellation()
                try await prepare()
                try Task.checkCancellation()
                guard generation == id else { return }
                let created = try await api.beginCurtainValidation(did: device.did)
                guard generation == id else { await created.end(); return }
                session = created
                _ = try await created.start()
            } catch { if generation == id { self.error = error.localizedDescription } }
            if generation == id { state = await session?.snapshot() }
        }
    }
    func disable() {
        let previous = task
        previous?.cancel()
        let id = UUID(); generation = id
        deviceID = nil; isWorking = true
        task = Task {
            await api.endCurtainValidation()
            await previous?.value
            guard generation == id else { return }
            session = nil; state = nil; error = nil; isWorking = false; task = nil
        }
    }
    func refresh() { perform { try await $0.refresh() } }
    func move(to target: Int) { perform { try await $0.move(to: target) } }
    func confirm() { perform { try await $0.confirmPendingMove() } }

    private func perform(_ action: @escaping @Sendable (CurtainValidationSession) async throws -> CurtainValidationSession.State) {
        guard !isWorking, let session else { return }
        let id = generation
        isWorking = true; error = nil
        task = Task {
            defer { if generation == id { isWorking = false; task = nil } }
            do { _ = try await action(session) }
            catch { if generation == id { self.error = error.localizedDescription } }
            if generation == id { state = await session.snapshot() }
        }
    }
}
