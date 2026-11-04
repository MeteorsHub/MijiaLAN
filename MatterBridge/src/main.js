import { AppRPC } from './app-rpc.js';
import { mkdir, chmod, readFile, writeFile } from 'node:fs/promises';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomInt } from 'node:crypto';
import { Environment, Logger } from '@matter/main';
import { DeviceRPC } from './rpc.js';
import { createBridge } from './bridge.js';

// Restrict all newly created Matter credentials and fabric state to the current user.
process.umask(0o077);
const args = process.argv.slice(2);
if (args.length !== 2) {
  console.error('Usage: npm start -- /absolute/path/mijia-lan /absolute/path/local-home.json');
  process.exit(2);
}
const appMode = args[0] === '--app';
if (appMode) {
  console.log = (...values) => console.error(...values);
  for (const destination of Object.values(Logger.destinations)) {
    destination.write = text => process.stderr.write(text + '\n');
  }
}
const storage = appMode ? resolve(args[1]) : resolve(dirname(fileURLToPath(import.meta.url)), '../.matter');
await mkdir(storage, { recursive: true, mode: 0o700 });
await chmod(storage, 0o700);
Environment.default.vars.set('storage.path', storage);
const credentialsPath = resolve(storage, 'commissioning.json');
let credentials;
try {
  credentials = JSON.parse(await readFile(credentialsPath, 'utf8'));
} catch (error) {
  if (error.code !== 'ENOENT') throw error;
  let passcode;
  do { passcode = randomInt(1, 99_999_999); }
  while ([11111111, 22222222, 33333333, 44444444, 55555555, 66666666, 77777777, 88888888, 12345678, 87654321].includes(passcode));
  credentials = { passcode, discriminator: randomInt(0, 4096) };
  await writeFile(credentialsPath, JSON.stringify(credentials), { mode: 0o600, flag: 'wx' });
}
const rpc = appMode ? new AppRPC() : new DeviceRPC(resolve(args[0]), resolve(args[1]));
function report() {
  if (appMode && bridge) process.stdout.write(JSON.stringify({ event: "ready",
    code: bridge.node.state.commissioning.pairingCodes.manualPairingCode,
    uri: bridge.node.state.commissioning.pairingCodes.qrPairingCode,
    paired: bridge.node.state.commissioning.commissioned, count: bridge.endpoints.size }) + "\n");
}
let bridge;
let timer;
let stopping = false;
async function stop(code = 0) {
  if (stopping) return;
  stopping = true;
  clearTimeout(timer);
  rpc.close();
  try { await bridge?.node.close(); }
  catch { code = 1; }
  process.exitCode = code;
}
if (appMode) rpc.onClose = () => void stop();
process.once('SIGINT', () => void stop());
process.once('SIGTERM', () => void stop());
try {
  bridge = await createBridge(rpc, await rpc.request('snapshot'), credentials);
  if (stopping) {
    await bridge.node.close();
  } else {
    await bridge.node.start();
    report();
    console.log('在 Aqara Home 中添加 Matter 设备，输入以下配对码：');
    console.log(bridge.node.state.commissioning.pairingCodes.manualPairingCode);
    console.log('请保存 .matter 目录以保留配对信息。设备清单变化后请重启桥接。');
    async function poll() {
      try {
        await bridge.sync(await rpc.request('snapshot'));
        report();
        if (!stopping) timer = setTimeout(poll, 5000);
      } catch {
        if (stopping) return;
        try { await bridge.sync([]); } catch { /* Still close if the Matter transport failed. */ }
        console.error('设备进程通信失败，桥接已停止；请检查配置和设备后重启。');
        await stop(1);
      }
    }
    if (!stopping) timer = setTimeout(poll, 5000);
  }
} catch {
  console.error('Matter 桥接启动失败。请检查设备清单、可执行文件及网络权限。');
  await stop(1);
}
