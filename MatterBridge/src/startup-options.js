// App launches retain 5540. Tests may explicitly choose another UDP port without changing stored credentials.
export function parseStartupOptions(args) {
  const appMode = args[0] === '--app';
  const customPort = appMode && args.length === 4 && args[2] === '--port';
  if (args.length !== 2 && !customPort) {
    throw new Error('Usage: main.js <executable> <config> OR --app <storage> [--port <1-65535>]');
  }
  const port = customPort ? Number(args[3]) : 5540;
  if (customPort && (!/^[1-9]\d*$/.test(args[3]) || !Number.isSafeInteger(port) || port > 65535)) {
    throw new Error('Expected a UDP port from 1 to 65535');
  }
  return { appMode, port };
}
