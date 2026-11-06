# 家庭设备最小只读诊断

先核对运行进程路径、可执行文件 SHA-256、Info.plist 版本；只有匹配构建记录时才声称对应源码提交。
无需重启已运行的 App，不改变桥接开关、配对或任何设备设置。仅在家庭环境、用户授权后查询。

新增 `mijia-lan diagnose` 仅从 stdin 接收现有 `LocalHomeConfig`，不接收 token 参数。
只对六个已报告型号执行 `miIO.info` 和逐项 `get_properties`，不发送 `set_properties`、`action`、
喂食、电机、工厂模式、重置或其他写指令。每个属性只读一次、不重试。
输出保留型号、导入配置中记录的规格 URN、可用固件版本和所请求属性的 SIID/PIID、返回码及原始 JSON 标量值。
字符串最多 96 字符；数组/对象仅报告类型并省略内容。逐属性错误后继续其他读取；型号不匹配或 info 失败则停止查询该设备。
另附本机匹配型号的缓存规格候选（URN、SIID/PIID、format、access、description/comment、range、options），只读文件、不联网获取。
`specificationSource: imported_config` 不证明当前 App 正在使用该版本；缓存也可能同时有多个版本，需与当前设备信息页核对。
不输出 IP、MAC、设备 ID、名称、房间、账号、token 或配对密钥。

在 Mac checkout 中先编译 CLI（不要修改源码）：

```sh
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build --product mijia-lan --force-resolved-versions
```

已有私有设备清单时：

```sh
umask 077
diagnostic_dir=$(mktemp -d "${TMPDIR:-/tmp}/mijialan-diagnose.XXXXXX")
.build/debug/mijia-lan diagnose < /absolute/path/devices.local.json > "$diagnostic_dir/report.json"
```

没有清单时，可在用户同意访问该 App 钥匙串项后，通过管道传递，不在终端显示或落盘凭据：

```sh
set -o pipefail
umask 077
diagnostic_dir=$(mktemp -d "${TMPDIR:-/tmp}/mijialan-diagnose.XXXXXX")
security find-generic-password -s com.mijialan.MijiaLAN -a secrets -w |
  python3 -c 'import sys,json,base64; data=json.load(sys.stdin); sys.stdout.buffer.write(base64.b64decode(data["home_config_v1"], validate=True))' |
  .build/debug/mijia-lan diagnose > "$diagnostic_dir/report.json"
```

不要在上述管道中插入 `tee`、调试打印或 `set -x`。若钥匙串访问被拒绝或没有该项，停止并报告，不导出其他凭据。
先本地检查最终报告，再只反馈型号、固件、规格 URN 和属性结果。不发送原始清单或整个钥匙串。

当前查询：

- `dooya.motor.dc1545`：2.2、2.3、2.4、2.5、2.9、2.10；不读取只写 2.1。
- `xiaomi.pet_waterer.70m2`：2.1、2.3、2.4、2.7、2.10、2.11，区分两条出水间隔。
- `xiaomi.derh.13l`：2.1、2.2、2.3、2.5、3.1、3.2。
- `iot.tow_w.jd015`：2.1～2.6。
- `giot.heater.v13daf`：2.1、2.2、2.3、3.1、3.2，保留两个服务的独立状态。
- `xiaomi.feeder.pi2001`：2.1、2.6、2.10、2.11、2.13、2.15、2.26、2.28、2.29、2.31、2.32。

喂食器三个报错厂商开关先从设备信息或缓存规格记录确切 SIID/PIID、format、access、description，
再由云端审核后补入白名单；当前不臆测它们的地址。

默认自动读取 `~/Library/Caches/MijiaLAN/instances` 中这六个型号的缓存规格候选。
若输出 `cachedSpecifications: []`，只报告缓存缺失，切勿运行 `spec` 联网刷新、删除缓存或重置配置来获取诊断。
不需要另行发送缓存目录或配置目录。
`-4004`、`-4001` 只能作为返回码保留，不据此断定不支持 MIoT。

先核对 `git rev-parse HEAD`，构建并执行 `swift test --filter ReadOnlyDiagnosticsTests`。云端的可移植测试不替代 macOS CLI 编译和真实只读查询。

第一、二轮实机采集均已完成；结果见 [household-followup-diagnostics.md](household-followup-diagnostics.md)。用户随后报告米家控制也异常；退出 MijiaLAN 后，手机控制未驱动卷帘；用户澄清实体遥控可驱动卷帘，实体动作后米家状态能正确更新，具体字段和值未提供。隔离观察已完成，MijiaLAN 保持退出，继续暂停设备查询，不重跑以上命令。
