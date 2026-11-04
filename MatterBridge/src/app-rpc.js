import { createInterface } from 'node:readline';

/** App owns the controller; this child requests operations through its inherited pipes. */
export class AppRPC {
  #next = 1;
  #pending = new Map();
  #lines;
  #closed = false;
  constructor() {
    this.#lines = createInterface({ input: process.stdin }).on('line', line => {
      try {
        const reply = JSON.parse(line);
        const p = this.#pending.get(reply.id);
        if (!p) return;
        this.#pending.delete(reply.id);
        clearTimeout(p.timer);
        if (reply.error) p.reject(new Error('Device operation failed'));
        else p.resolve(reply.devices);
      } catch { this.close(); }
    }).on('close', () => { this.close(); this.onClose?.(); });
  }
  request(method, params = {}) {
    const id = this.#next++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { this.#pending.delete(id); reject(new Error('App RPC timed out')); }, 30_000);
      this.#pending.set(id, { resolve, reject, timer });
      process.stdout.write(JSON.stringify({ id, method, ...params }) + '\n');
    });
  }
  close() {
    if (this.#closed) return;
    this.#closed = true;
    for (const p of this.#pending.values()) { clearTimeout(p.timer); p.reject(new Error('App RPC closed')); }
    this.#pending.clear();
    this.#lines.close();
    process.stdin.destroy();
  }
}
