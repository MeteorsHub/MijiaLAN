# MijiaCore / MenuBarMijia

MijiaLAN 在此维护 MijiaCore 的本地副本。上游仓库已无法访问，构建通过本地 Swift package 使用这份源码。
MijiaLAN maintains this local MijiaCore package after the upstream repository became unavailable. Builds use this directory directly.

## 来源 / Provenance

- Original repository: `https://github.com/jryang1997/MenuBarMijia`
- Release: `1.1.4`
- Revision: `c6a9db1c84fa30125ed4b642b6745487dec94e89`
- License: MIT; the original copyright and permission notice are preserved in [LICENSE](LICENSE).
- Recovered from the exact Git objects already used by MijiaLAN's pinned dependency.

`Sources/MijiaCore`, `Tests/MijiaCoreTests` and `Tests/Fixtures` are imported unchanged from that revision. They include all 48 core Swift sources, the localization resource, all 36 core test files and five shared golden fixtures.

## 本地维护 / Local maintenance

The local manifest exposes the `MijiaCore` library and its tests. It omits the upstream app, app UI tests and their snapshot-testing dependency. The package name stays `MenuBarMijia` so the existing `MenuBarMijia_MijiaCore.bundle` name and localization lookup continue to work. The library has no external package dependencies.

Future core changes are maintained here and should be described in this section. Keep the original MIT notice when modifying or redistributing this code. MijiaLAN's app packaging includes this license.

## 验证 / Validation

Run both the core and application suites from the MijiaLAN repository root:

```bash
swift test --package-path Vendor/MenuBarMijia --scratch-path "$PWD/.build/mijiacore-tests" -c release
swift test -c release --force-resolved-versions
```

Native CI and local release packaging run both suites. The golden fixtures remain at their original relative paths for the upstream tests' fixture lookup.
