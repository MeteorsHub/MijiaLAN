import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';

/** JSON lines over inherited pipes; no listening port, shell interpolation or tokens in arguments. */
export class DeviceRPC {
  #child;
  #pending = new Map();
  #next = 1;
  #closed = false;
  constructor(executable, config, { timeout = 30_000 } = {}) {
    this.timeout = timeout;
    this.#child = spawn(executable, ['matter-rpc', config], { stdio: ['pipe', 'pipe', 'inherit'] });
    const lines = createInterface({ input: this.#child.stdout });
    lines.on('line', line => {
      try {
        const reply = JSON.parse(line);
        const pending = this.#pending.get(reply.id);
        if (!pending) return;
        this.#pending.delete(reply.id);
        clearTimeout(pending.timer);
        if (reply.error) pending.reject(new Error('Device operation failed'));
        else if (!Array.isArray(reply.devices)) pending.reject(new Error('Invalid device reply'));
        else pending.resolve(reply.devices);
      } catch { this.#fail(new Error('Invalid device RPC output')); }
    });
    this.#child.on('error', () => this.#fail(new Error('Cannot start mijia-lan executable')));
    this.#child.on('exit', () => this.#fail(new Error('Device RPC exited')));
    this.#child.stdin.on('error', () => this.#fail(new Error('Device RPC pipe closed')));
  }
  #fail(error) {
    this.#closed = true;
    for (const pending of this.#pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(error);
    }
    this.#pending.clear();
  }
  request(method, params = {}) {
    if (this.#closed) return Promise.reject(new Error('Device RPC is closed'));
    const id = this.#next++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.#pending.delete(id);
        // A late write could still complete. Stop the bridge instead of queueing more commands.
        this.close();
        reject(new Error('Device RPC timed out'));
      }, this.timeout);
      this.#pending.set(id, { resolve, reject, timer });
      this.#child.stdin.write(JSON.stringify({ ...params, id, method }) + '\n');
    });
  }
  close() {
    this.#fail(new Error('Device RPC closed'));
    this.#child.stdin.end();
    this.#child.kill();
  }
}
