import CryptoKit
import Foundation
import Testing
@testable import MijiaCore

struct UpdateCheckerTests {
    @Test("Versions compare numerically, ignoring a leading v")
    func versionCompare() {
        #expect(AppVersion("v1.10.0")! > AppVersion("1.9.3")!)
        #expect(AppVersion("1.2")! == AppVersion("1.2.0")!)
        #expect(AppVersion("2.0.0-beta")! > AppVersion("1.9")!)
        #expect(AppVersion("abc") == nil)
    }

    static func checker(status: Int, body: String) -> UpdateChecker {
        UpdateChecker(currentVersion: "1.0.0", transport: { request in
            #expect(request.url?.absoluteString == "https://api.github.com/repos/jryang1997/MenuBarMijia/releases/latest")
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        })
    }

    @Test("A newer release is reported with its download page")
    func newerRelease() async throws {
        let json = #"{"tag_name":"v1.1.0","html_url":"https://github.com/jryang1997/MenuBarMijia/releases/tag/v1.1.0","body":"新功能"}"#
        let result = try await Self.checker(status: 200, body: json).checkRelease()
        #expect(
            result == AppRelease(
                version: "1.1.0",
                pageURL: URL(string: "https://github.com/jryang1997/MenuBarMijia/releases/tag/v1.1.0")!,
                notes: "新功能",
                packageAsset: nil
            )
        )
    }

    @Test("Same version or no releases yet means up to date")
    func upToDate() async throws {
        let same = #"{"tag_name":"v1.0.0","html_url":"https://github.com/x"}"#
        #expect(try await Self.checker(status: 200, body: same).checkRelease() == nil)
        #expect(try await Self.checker(status: 404, body: "{}").checkRelease() == nil)
    }

    @Test("Server errors surface as a thrown error")
    func serverError() async {
        await #expect(throws: UpdateChecker.CheckError.self) {
            _ = try await Self.checker(status: 500, body: "").checkRelease()
        }
    }

    @Test("SHA256Digest parses GitHub inline digest and sidecar lines and streams file verification")
    func sha256DigestParsingAndFileMatching() throws {
        let payload = Data(repeating: 0x5A, count: 140 * 1024)
        let expectedHex = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()

        let fromInline = SHA256Digest(parsing: "sha256:\(expectedHex.uppercased())")
        let fromSidecar = SHA256Digest(parsing: "\(expectedHex)  MenuBarMijia-1.2.0.dmg\n")
        #expect(fromInline?.hex == expectedHex)
        #expect(fromSidecar == fromInline)
        #expect(SHA256Digest(parsing: "sha256:1234") == nil)
        #expect(SHA256Digest(parsing: String(repeating: "z", count: 64)) == nil)
        #expect(SHA256Digest.hash(payload) == fromInline)

        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("digest-test-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: tempFile) }
        try payload.write(to: tempFile)
        #expect(try SHA256Digest.hashFile(at: tempFile) == fromInline)
    }

    @Test("checkRelease selects DMG over ZIP and binds inline or sidecar SHA-256 integrity")
    func checkReleaseParsesDMGAssets() async throws {
        let digestHex = String(repeating: "a", count: 64)
        let inlineJSON = """
        {
          "tag_name": "v1.2.0",
          "html_url": "https://github.com/jryang1997/MenuBarMijia/releases/tag/v1.2.0",
          "body": "支持应用内更新",
          "assets": [
            {
              "name": "MenuBarMijia-1.2.0.zip",
              "browser_download_url": "https://example.com/MenuBarMijia-1.2.0.zip",
              "size": 1024,
              "digest": "sha256:\(digestHex)"
            },
            {
              "name": "MenuBarMijia-1.2.0.dmg",
              "browser_download_url": "https://example.com/MenuBarMijia-1.2.0.dmg",
              "size": 2048,
              "digest": "sha256:\(digestHex)"
            }
          ]
        }
        """
        let release1 = try await Self.checker(status: 200, body: inlineJSON).checkRelease()
        #expect(release1?.version == "1.2.0")
        #expect(release1?.notes == "支持应用内更新")
        #expect(release1?.packageAsset?.kind == .dmg)
        #expect(release1?.packageAsset?.sizeBytes == 2048)
        #expect(release1?.packageAsset?.integrity == .inlineSHA256(SHA256Digest(parsing: digestHex)!))

        let sidecarJSON = """
        {
          "tag_name": "v1.3.0",
          "html_url": "https://github.com/jryang1997/MenuBarMijia/releases/tag/v1.3.0",
          "body": "Sidecar checksum",
          "assets": [
            {
              "name": "MenuBarMijia-1.3.0.dmg",
              "browser_download_url": "https://example.com/MenuBarMijia-1.3.0.dmg",
              "size": 4096
            },
            {
              "name": "MenuBarMijia-1.3.0.dmg.sha256",
              "browser_download_url": "https://example.com/MenuBarMijia-1.3.0.dmg.sha256",
              "size": 96
            }
          ]
        }
        """
        let release2 = try await Self.checker(status: 200, body: sidecarJSON).checkRelease()
        #expect(release2?.packageAsset?.kind == .dmg)
        #expect(release2?.packageAsset?.integrity == .checksumAssetURL(URL(string: "https://example.com/MenuBarMijia-1.3.0.dmg.sha256")!))
    }

    private static func makeFakeAppBundle(
        in directory: URL,
        bundleID: String = AppUpdater.expectedBundleIdentifier,
        shortVersion: String = "1.2.0"
    ) throws -> URL {
        let appURL = directory.appendingPathComponent("MenuBarMijia.app", isDirectory: true)
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleShortVersionString": shortVersion,
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: contentsURL.appendingPathComponent("Info.plist"))
        return appURL
    }

    @Test("AppUpdater stages verified bundle and rejects checksum, bundle ID, signature, or codesign failures")
    func appUpdaterStageAndRejections() async throws {
        let rootDir = FileManager.default.temporaryDirectory.appendingPathComponent("updater-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootDir) }

        let targetAppURL = try Self.makeFakeAppBundle(in: rootDir, shortVersion: "1.0.0")
        let stagingParent = rootDir.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingParent, withIntermediateDirectories: true)

        let archiveBytes = Data("verified-dmg-content".utf8)
        let validDigest = SHA256Digest.hash(archiveBytes)
        let signingKey = Curve25519.Signing.PrivateKey()
        let signingPublicKey = signingKey.publicKey.rawRepresentation.base64EncodedString()
        let packageSignature = try signingKey.signature(for: archiveBytes).base64EncodedString()
        let sidecarText = "\(validDigest.hex)  MenuBarMijia-1.2.0.dmg\n"
        let release = AppRelease(
            version: "1.2.0",
            pageURL: URL(string: "https://github.com/jryang1997/MenuBarMijia/releases/tag/v1.2.0")!,
            notes: "Release notes",
            packageAsset: .init(
                name: "MenuBarMijia-1.2.0.dmg",
                downloadURL: URL(string: "https://example.com/MenuBarMijia-1.2.0.dmg")!,
                sizeBytes: Int64(archiveBytes.count),
                kind: .dmg,
                integrity: .checksumAssetURL(URL(string: "https://example.com/MenuBarMijia-1.2.0.dmg.sha256")!)
            )
        )

        func makeUpdater(driver: UpdateSystemDriver) -> AppUpdater {
            AppUpdater(
                currentVersion: "1.0.0",
                targetBundleURL: targetAppURL,
                stagingBaseDirectory: stagingParent,
                updateSigningPublicKeyBase64: signingPublicKey,
                driver: driver
            )
        }

        let happyDriver = UpdateSystemDriver(
            downloadFile: { _, destination, onProgress in
                try archiveBytes.write(to: destination)
                onProgress(DownloadProgress(receivedBytes: Int64(archiveBytes.count), totalBytes: Int64(archiveBytes.count)))
            },
            fetchData: { req in
                let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                if req.url?.path.hasSuffix(".ed25519.sig") == true {
                    #expect(req.url?.absoluteString == "https://example.com/MenuBarMijia-1.2.0.dmg.ed25519.sig")
                    return (Data(packageSignature.utf8), resp)
                }
                return (Data(sidecarText.utf8), resp)
            },
            unpackArchive: { _, _, destinationDir in
                try Self.makeFakeAppBundle(in: destinationDir, shortVersion: "1.2.0")
            },
            verifyCodeSignature: { _, _ in },
            launchDetachedSwapAndRelaunch: { _, _, _ in }
        )

        let staleDir = stagingParent.appendingPathComponent("com.jryang1997.MenuBarMijia.update-stale", isDirectory: true)
        try FileManager.default.createDirectory(at: staleDir, withIntermediateDirectories: true)

        let updater = makeUpdater(driver: happyDriver)
        let staged = try await updater.stageUpdate(for: release) { _ in }
        #expect(!FileManager.default.fileExists(atPath: staleDir.path))
        #expect(FileManager.default.fileExists(atPath: staged.stagedBundleURL.path))
        updater.cleanupStagedApp(staged)
        #expect(!FileManager.default.fileExists(atPath: staged.stagingRootURL.path))

        var symlinkDriver = happyDriver
        symlinkDriver.unpackArchive = { _, _, destinationDir in
            let symlinkURL = destinationDir.appendingPathComponent("MenuBarMijia.app")
            try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: targetAppURL)
            return symlinkURL
        }
        await #expect(throws: UpdateInstallError.unpackFailed("App bundle cannot be a symbolic link")) {
            _ = try await makeUpdater(driver: symlinkDriver).stageUpdate(for: release) { _ in }
        }

        var corruptedDriver = happyDriver
        corruptedDriver.downloadFile = { _, destination, _ in
            try Data("tampered-dmg-content".utf8).write(to: destination)
        }
        await #expect(throws: UpdateInstallError.self) {
            _ = try await makeUpdater(driver: corruptedDriver).stageUpdate(for: release) { _ in }
        }
        let remainingAfterChecksumFail = try FileManager.default.contentsOfDirectory(atPath: stagingParent.path)
        #expect(remainingAfterChecksumFail.isEmpty)

        var wrongBundleDriver = happyDriver
        wrongBundleDriver.unpackArchive = { _, _, destinationDir in
            try Self.makeFakeAppBundle(in: destinationDir, bundleID: "com.evil.Replacement", shortVersion: "1.2.0")
        }
        await #expect(throws: UpdateInstallError.bundleIdentifierMismatch(found: "com.evil.Replacement")) {
            _ = try await makeUpdater(driver: wrongBundleDriver).stageUpdate(for: release) { _ in }
        }

        var invalidSigDriver = happyDriver
        invalidSigDriver.verifyCodeSignature = { _, _ in
            throw UpdateInstallError.codeSignatureInvalid("a sealed resource is missing or invalid")
        }
        await #expect(throws: UpdateInstallError.codeSignatureInvalid("a sealed resource is missing or invalid")) {
            _ = try await makeUpdater(driver: invalidSigDriver).stageUpdate(for: release) { _ in }
        }

        // 篡改 DMG 后同步修改 .sha256：SHA-256 能过，但 Ed25519 必须拒绝。
        let tamperedBytes = Data("tampered-dmg-content".utf8)
        let tamperedDigest = SHA256Digest.hash(tamperedBytes)
        var tamperedDriver = happyDriver
        tamperedDriver.downloadFile = { _, destination, _ in
            try tamperedBytes.write(to: destination)
        }
        tamperedDriver.fetchData = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if req.url?.path.hasSuffix(".ed25519.sig") == true {
                return (Data(packageSignature.utf8), resp)
            }
            return (Data("\(tamperedDigest.hex)  MenuBarMijia-1.2.0.dmg\n".utf8), resp)
        }
        await #expect(throws: UpdateInstallError.updateSignatureInvalid("signature does not match the package")) {
            _ = try await makeUpdater(driver: tamperedDriver).stageUpdate(for: release) { _ in }
        }

        // .sig 缺失（404）时中止安装。
        var missingSignatureDriver = happyDriver
        missingSignatureDriver.fetchData = { req in
            if req.url?.path.hasSuffix(".ed25519.sig") == true {
                let resp = HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
                return (Data(), resp)
            }
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(sidecarText.utf8), resp)
        }
        await #expect(throws: UpdateInstallError.updateSignatureMissing) {
            _ = try await makeUpdater(driver: missingSignatureDriver).stageUpdate(for: release) { _ in }
        }

        // .sig 内容不是合法 base64 时同样中止。
        var malformedSignatureDriver = happyDriver
        malformedSignatureDriver.fetchData = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if req.url?.path.hasSuffix(".ed25519.sig") == true {
                return (Data("not-base64".utf8), resp)
            }
            return (Data(sidecarText.utf8), resp)
        }
        await #expect(throws: UpdateInstallError.updateSignatureInvalid("signature is not valid base64")) {
            _ = try await makeUpdater(driver: malformedSignatureDriver).stageUpdate(for: release) { _ in }
        }
    }

    @Test("Ed25519 update signatures round-trip and reject tampered data, keys, or signatures")
    func ed25519SignatureVerification() throws {
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        let data = Data("update-package-bytes".utf8)
        let signature = try key.signature(for: data).base64EncodedString()
        #expect(UpdateSignature.verify(signatureBase64: signature, publicKeyBase64: publicKey, data: data))
        #expect(!UpdateSignature.verify(signatureBase64: signature, publicKeyBase64: publicKey, data: Data("tampered".utf8)))

        let otherKey = Curve25519.Signing.PrivateKey()
        #expect(!UpdateSignature.verify(
            signatureBase64: signature,
            publicKeyBase64: otherKey.publicKey.rawRepresentation.base64EncodedString(),
            data: data
        ))
        let otherSignature = try otherKey.signature(for: data).base64EncodedString()
        #expect(!UpdateSignature.verify(signatureBase64: otherSignature, publicKeyBase64: publicKey, data: data))
        #expect(!UpdateSignature.verify(signatureBase64: "not-base64", publicKeyBase64: publicKey, data: data))
        #expect(!UpdateSignature.verify(signatureBase64: signature, publicKeyBase64: "AAAA", data: data))
        #expect(Data(base64Encoded: UpdateChecker.updateSigningPublicKeyBase64)?.count == 32)
        #expect(AppUpdater.signatureURL(for: URL(string: "https://example.com/MenuBarMijia-1.2.0.dmg")!)
            == URL(string: "https://example.com/MenuBarMijia-1.2.0.dmg.ed25519.sig")!)
    }


    @MainActor
    @Test("HomeStore orchestrates throttling, staging, cancellation, retry, and relaunch")
    func homeStoreUpdateStateMachine() async throws {
        let suite = "com.jryang1997.MenuBarMijia.update-test.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let rootDir = FileManager.default.temporaryDirectory.appendingPathComponent("store-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootDir) }

        let targetAppURL = try Self.makeFakeAppBundle(in: rootDir, shortVersion: "1.0.0")
        let archiveBytes = Data("release-binary".utf8)
        let digest = SHA256Digest.hash(archiveBytes)
        let signingKey = Curve25519.Signing.PrivateKey()
        let signingPublicKey = signingKey.publicKey.rawRepresentation.base64EncodedString()
        let packageSignature = try signingKey.signature(for: archiveBytes).base64EncodedString()
        let releaseJSON = """
        {
          "tag_name": "v1.4.0",
          "html_url": "https://github.com/jryang1997/MenuBarMijia/releases/tag/v1.4.0",
          "body": "支持状态栏气泡提醒",
          "assets": [
            {
              "name": "MenuBarMijia-1.4.0.dmg",
              "browser_download_url": "https://example.com/MenuBarMijia-1.4.0.dmg",
              "size": \(archiveBytes.count),
              "digest": "sha256:\(digest.hex)"
            }
          ]
        }
        """

        final class Probe: @unchecked Sendable {
            var checkCallCount = 0
            var shouldFailUnpack = false
            var shouldBlockDownloadForCancel = false
            var swappedTargetURL: URL?
        }
        let probe = Probe()

        let makeUpdater = { () -> AppUpdater in
            let driver = UpdateSystemDriver(
                downloadFile: { _, destination, onProgress in
                    if probe.shouldBlockDownloadForCancel {
                        try await Task.sleep(for: .seconds(10))
                    }
                    try archiveBytes.write(to: destination)
                    onProgress(DownloadProgress(receivedBytes: Int64(archiveBytes.count), totalBytes: Int64(archiveBytes.count)))
                },
                fetchData: { req in
                    probe.checkCallCount += 1
                    let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                    if req.url?.path.hasSuffix(".ed25519.sig") == true {
                        return (Data(packageSignature.utf8), resp)
                    }
                    return (Data(releaseJSON.utf8), resp)
                },
                unpackArchive: { _, _, destinationDir in
                    if probe.shouldFailUnpack {
                        throw UpdateInstallError.unpackFailed("Simulated mount error")
                    }
                    return try Self.makeFakeAppBundle(in: destinationDir, shortVersion: "1.4.0")
                },
                verifyCodeSignature: { _, _ in },
                launchDetachedSwapAndRelaunch: { _, targetURL, _ in
                    probe.swappedTargetURL = targetURL
                }
            )
            return AppUpdater(
                currentVersion: "1.0.0",
                targetBundleURL: targetAppURL,
                stagingBaseDirectory: rootDir,
                updateSigningPublicKeyBase64: signingPublicKey,
                driver: driver
            )
        }

        let store = HomeStore(
            provider: MockHomeProvider(),
            defaultsSuiteName: suite,
            updater: makeUpdater()
        )
        var didTerminate = false
        store.onTerminateForUpdate = { didTerminate = true }

        store.automaticallyChecksForUpdates = false
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        await store.checkForUpdatesIfNeeded(now: t0)
        #expect(probe.checkCallCount == 0)
        #expect(store.updateState == .idle)

        store.automaticallyChecksForUpdates = true
        await store.checkForUpdatesIfNeeded(now: t0)
        #expect(probe.checkCallCount == 1)
        #expect(store.updateState.badgeRelease?.version == "1.4.0")

        store.updater = AppUpdater(
            currentVersion: "1.4.0",
            targetBundleURL: targetAppURL,
            stagingBaseDirectory: rootDir,
            updateSigningPublicKeyBase64: signingPublicKey,
            driver: UpdateSystemDriver(
                downloadFile: { _, _, _ in },
                fetchData: { req in
                    probe.checkCallCount += 1
                    let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                    return (Data(releaseJSON.utf8), resp)
                },
                unpackArchive: { _, _, dir in dir },
                verifyCodeSignature: { _, _ in },
                launchDetachedSwapAndRelaunch: { _, _, _ in }
            )
        )
        await store.checkForUpdates(now: t0)
        #expect(store.updateState == .upToDate(checkedAt: t0))
        let countAfterManual = probe.checkCallCount

        await store.checkForUpdatesIfNeeded(now: t0.addingTimeInterval(3600))
        #expect(probe.checkCallCount == countAfterManual)

        store.updater = makeUpdater()
        await store.checkForUpdatesIfNeeded(now: t0.addingTimeInterval(6 * 3600 + 1))
        #expect(probe.checkCallCount == countAfterManual + 1)
        #expect(store.updateState.associatedRelease?.version == "1.4.0")

        probe.shouldBlockDownloadForCancel = true
        let installTask = Task { await store.startUpdateInstallation() }
        try await Task.sleep(for: .milliseconds(40))
        store.cancelUpdateInstallation()
        await installTask.value
        #expect(store.updateState.associatedRelease?.version == "1.4.0")
        if case .available(let release) = store.updateState {
            #expect(release.version == "1.4.0")
        } else {
            Issue.record("Expected .available after cancelling installation, got \(store.updateState)")
        }
        probe.shouldBlockDownloadForCancel = false

        probe.shouldFailUnpack = true
        await store.startUpdateInstallation()
        if case .failed(let failure) = store.updateState {
            #expect(failure.canRetryInstall)
            #expect(failure.fallbackURL.absoluteString == "https://github.com/jryang1997/MenuBarMijia/releases/tag/v1.4.0")
        } else {
            Issue.record("Expected .failed state on unpack error, got \(store.updateState)")
        }

        probe.shouldFailUnpack = false
        await store.startUpdateInstallation()
        #expect(store.updateState.isReadyToRelaunch)

        store.confirmRelaunchForUpdate()
        #expect(probe.swappedTargetURL == targetAppURL)
        #expect(didTerminate)
    }

    #if os(macOS)
    private static func runTool(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        process.standardError = errPipe
        try process.run()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        while process.isRunning {
            Thread.sleep(forTimeInterval: 0.005)
        }
        if process.terminationStatus != 0 {
            let errText = String(data: errData, encoding: .utf8) ?? ""
            throw UpdateInstallError.unpackFailed("\(executable) exited \(process.terminationStatus): \(errText)")
        }
    }

    private static func makeSignedMachOAppBundle(
        in directory: URL,
        bundleID: String = AppUpdater.expectedBundleIdentifier,
        shortVersion: String = "1.5.0"
    ) throws -> URL {
        let appURL = directory.appendingPathComponent("MenuBarMijia.app", isDirectory: true)
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOSURL, withIntermediateDirectories: true)
        let executableURL = macOSURL.appendingPathComponent("MenuBarMijiaApp")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executableURL)
        let plist: [String: Any] = [
            "CFBundleExecutable": "MenuBarMijiaApp",
            "CFBundleIdentifier": bundleID,
            "CFBundleShortVersionString": shortVersion,
            "CFBundlePackageType": "APPL",
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: contentsURL.appendingPathComponent("Info.plist"))
        try runTool("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", bundleID, appURL.path])
        return appURL
    }

    @Test("UpdateSystemDriver.live unpacks ZIP and DMG, enforces the codesign requirement, and swaps bundle")
    func liveDriverUnpacksAndVerifiesSignedBundles() async throws {
        let rootDir = FileManager.default.temporaryDirectory.appendingPathComponent("live-driver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootDir) }

        let missingPinRequirement = AppUpdater.codeSigningRequirement(
            bundleIdentifier: AppUpdater.expectedBundleIdentifier,
            certificateSHA1: nil
        )
        let pinnedRequirement = AppUpdater.codeSigningRequirement(
            bundleIdentifier: AppUpdater.expectedBundleIdentifier,
            certificateSHA1: String(repeating: "a", count: 40)
        )
        let buildDir = rootDir.appendingPathComponent("build", isDirectory: true)
        try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)
        let signedAppURL = try Self.makeSignedMachOAppBundle(in: buildDir, shortVersion: "1.5.0")

        let zipURL = rootDir.appendingPathComponent("MenuBarMijia-1.5.0.zip")
        try Self.runTool("/usr/bin/ditto", ["-c", "-k", "--keepParent", signedAppURL.path, zipURL.path])

        let zipDest = rootDir.appendingPathComponent("zip-dest", isDirectory: true)
        try FileManager.default.createDirectory(at: zipDest, withIntermediateDirectories: true)
        let unpackedFromZip = try await UpdateSystemDriver.live.unpackArchive(zipURL, .zip, zipDest)
        #expect(unpackedFromZip.lastPathComponent == "MenuBarMijia.app")
        try await UpdateSystemDriver.live.stripQuarantine(unpackedFromZip)
        await #expect(throws: UpdateInstallError.self) {
            try await UpdateSystemDriver.live.verifyCodeSignature(unpackedFromZip, missingPinRequirement)
        }
        // 同 Bundle ID 的 ad-hoc 包必须被钉住证书的 requirement 拒绝。
        await #expect(throws: UpdateInstallError.self) {
            try await UpdateSystemDriver.live.verifyCodeSignature(unpackedFromZip, pinnedRequirement)
        }

        let dmgSrcDir = rootDir.appendingPathComponent("dmg-src", isDirectory: true)
        try FileManager.default.createDirectory(at: dmgSrcDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: signedAppURL,
            to: dmgSrcDir.appendingPathComponent("MenuBarMijia.app", isDirectory: true)
        )
        let dmgURL = rootDir.appendingPathComponent("MenuBarMijia-1.5.0.dmg")
        try Self.runTool(
            "/usr/bin/hdiutil",
            ["create", "-volname", "MenuBarMijia 1.5.0", "-srcfolder", dmgSrcDir.path, "-ov", "-format", "UDZO", dmgURL.path]
        )

        let dmgDest = rootDir.appendingPathComponent("dmg-dest", isDirectory: true)
        try FileManager.default.createDirectory(at: dmgDest, withIntermediateDirectories: true)
        let unpackedFromDmg = try await UpdateSystemDriver.live.unpackArchive(dmgURL, .dmg, dmgDest)
        #expect(unpackedFromDmg.lastPathComponent == "MenuBarMijia.app")
        #expect(!FileManager.default.fileExists(atPath: dmgDest.appendingPathComponent("mnt").path))
        try await UpdateSystemDriver.live.stripQuarantine(unpackedFromDmg)
        await #expect(throws: UpdateInstallError.self) {
            try await UpdateSystemDriver.live.verifyCodeSignature(unpackedFromDmg, missingPinRequirement)
        }

        let evilDir = rootDir.appendingPathComponent("evil", isDirectory: true)
        try FileManager.default.createDirectory(at: evilDir, withIntermediateDirectories: true)
        let evilAppURL = try Self.makeSignedMachOAppBundle(in: evilDir, bundleID: "com.evil.Other", shortVersion: "1.5.0")
        await #expect(throws: UpdateInstallError.self) {
            try await UpdateSystemDriver.live.verifyCodeSignature(evilAppURL, pinnedRequirement)
        }
    }
    #endif
}
