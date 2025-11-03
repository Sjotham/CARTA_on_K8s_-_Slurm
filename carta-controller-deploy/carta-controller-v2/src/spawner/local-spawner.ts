// local-spawner.ts
import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import * as fs from "node:fs";
import type { WriteStream } from "node:fs";
import * as net from "node:net";
import * as tcpPortUsed from "tcp-port-used";
import { v4 as uuidv4 } from "uuid";
import { LinkedList } from "mnemonist";
import type { Spawner, StartOptions, SpawnResult, SpawnStatus, ProxyTarget } from "./spawner";

type ProcessInfo = { process: ChildProcess; port: number; headerToken: string; ready: boolean; logStream?: WriteStream; };
const LOG_LIMIT = 1000;

class LocalState {
  processMap = new Map<string, ProcessInfo>();
  logMap = new Map<string, LinkedList<string>>();
  userLocks = new Map<string, Promise<void>>();
  appendLog(u: string, s: string) { if (!u) return; let l=this.logMap.get(u); if(!l){l=new LinkedList<string>(); this.logMap.set(u,l);} while(l.size>=LOG_LIMIT) l.shift(); l.push(s); }
  deleteUser(u: string){ this.processMap.delete(u); this.logMap.delete(u); }
  async withUserLock<T>(u:string, fn:()=>Promise<T>) { const prev=this.userLocks.get(u)??Promise.resolve(); let rel!:()=>void; const next=new Promise<void>(r=>rel=r); this.userLocks.set(u, prev.then(()=>next)); try{ return await fn(); } finally { rel(); if(this.userLocks.get(u)===next) this.userLocks.delete(u);} }
}

export class LocalSpawner implements Spawner {
  constructor(private cfg: {
    backendPorts: { min: number; max: number };
    processCommand: string;
    preserveEnv?: boolean;
    additionalArgs?: string[];
    baseFolderTemplate: string;
    rootFolderTemplate: string;
    backendLogFileTemplate?: string;
    startDelayMs: number;
    killCommand?: string;
    logger: { info:(m:string)=>void; warn:(m:string)=>void; error:(m:string)=>void; debug?:(m:unknown)=>void; };
    delay: (ms:number)=>Promise<void>;
  }) {}
  private state = new LocalState();

  async start(username: string, opts?: StartOptions): Promise<SpawnResult> {
    return this.state.withUserLock(username, async () => {
      const existing = this.state.processMap.get(username);
      if (existing && !opts?.forceRestart && !existing.process.signalCode) {
        return { success:true, existing:true, status: await this.status(username), proxyHeaders: this._proxyHeaders(existing), info:{ pid: existing.process.pid??0, port: existing.port } };
      }
      if (existing && opts?.forceRestart) await this._stopUnsafe(username, existing);
      return await this._startUnsafe(username);
    });
  }

  async stop(username: string){ return this.state.withUserLock(username, async ()=>{ const ex=this.state.processMap.get(username); if(!ex) return {success:true}; await this._stopUnsafe(username, ex); return {success:true}; }); }

  async status(username: string): Promise<SpawnStatus> {
    const info = this.state.processMap.get(username);
    if (!info) return { running:false, ready:false };
    const running = !info.process.killed && !info.process.signalCode;
    if (!running) return { running:false, ready:false };
    return { running:true, ready:!!info.ready, target: this._target(info) };
  }

  async logs(username: string, tail?: number) {
    const list = this.state.logMap.get(username);
    if (!list?.size) return { success:false };
    if (!tail || tail >= list.size) return { success:true, log:list.toArray().join("") };
    const out:string[]=[]; let skip=list.size-tail; for(const ln of list){ if(skip-- > 0) continue; out.push(ln); }
    return { success:true, log: out.join("") };
  }

  async getProxyTarget(username: string) {
    const st = await this.status(username);
    if (!st.running) return { success:false };
    if (!st.ready || !st.target) {
      const info = this.state.processMap.get(username);
      if (info && !(await this._waitForAccept(info.port, this.cfg.startDelayMs))) return { success:false };
      if (info) info.ready = true;
    }
    return { success:true, target: (await this.status(username)).target };
  }

  // internals
  private async _startUnsafe(username: string): Promise<SpawnResult> {
    const port = await this._reservePort(this.cfg.backendPorts.min, this.cfg.backendPorts.max);
    if (port < 0) return { success:false, status:{ running:false, ready:false } };

    const args: string[] = [];
    if (this.cfg.preserveEnv) args.push("--preserve-env=CARTA_AUTH_TOKEN");
    args.push("-n","-u", username, this.cfg.processCommand, "--no_frontend","--no_database","--port", String(port),
      "--top_level_folder", this.cfg.rootFolderTemplate.replace("{username}", username), "--controller_deployment");
    if (this.cfg.backendLogFileTemplate) args.push("--no_log");
    if (this.cfg.additionalArgs?.length) args.push(...this.cfg.additionalArgs);
    args.push(this.cfg.baseFolderTemplate.replace("{username}", username));

    const token = uuidv4();
    const child = spawn("sudo", args, { env: { ...process.env, CARTA_AUTH_TOKEN: token } });
    if (child.pid == null) return { success:false, status:{ running:false, ready:false } };

    const info: ProcessInfo = { process: child, port, headerToken: token, ready:false };
    this.state.processMap.set(username, info); this._wireLogs(username, info, child);

    child.once("exit", (code, signal) => {
      this.cfg.logger.info(`Local backend ${child.pid} exited (code=${code}, signal=${signal})`);
      child.removeAllListeners(); info.logStream?.end(); this.state.deleteUser(username);
    });

    const ok = await this._waitForAccept(port, this.cfg.startDelayMs);
    if (!ok) { try { child.kill("SIGTERM"); } catch {} return { success:false, status:{ running:false, ready:false } }; }
    info.ready = true;

    return { success:true, status:{ running:true, ready:true, target:this._target(info) }, proxyHeaders:this._proxyHeaders(info), info:{ pid: child.pid, port } };
  }

  private async _stopUnsafe(username: string, info: ProcessInfo) {
    const child = info.process; child.removeAllListeners(); try { child.kill("SIGTERM"); } catch {}
    const exited = await new Promise<boolean>(r=>{ const t=setTimeout(()=>r(false),3000); child.once("exit",()=>{clearTimeout(t); r(true);}); });
    if (!exited && this.cfg.killCommand) { spawnSync("sudo", ["-u", username, this.cfg.killCommand, String(child.pid)]); await this.cfg.delay(200); }
    info.logStream?.end(); this.state.deleteUser(username);
  }

  private _target(info: ProcessInfo): ProxyTarget { return { host:"127.0.0.1", port:info.port, path:"/", headers:this._proxyHeaders(info) }; }
  private _proxyHeaders(info: ProcessInfo){ return { "carta-auth-token": info.headerToken }; }

  private _wireLogs(user: string, info: ProcessInfo, child: ChildProcess) {
    const stamp = new Date().toISOString().replace(/[-:]/g,"").replace(/\..+/,"").replace("T",".");
    if (this.cfg.backendLogFileTemplate) {
      const loc = this.cfg.backendLogFileTemplate.replace("{username}", user).replace("{pid}", String(child.pid)).replace("{datetime}", stamp);
      try {
        info.logStream = fs.createWriteStream(loc, { flags:"a" });
        child.stdout?.pipe(info.logStream); child.stderr?.pipe(info.logStream);
        child.stdout?.on("data", d => this.state.appendLog(user, String(d)));
        child.stderr?.on("data", d => this.state.appendLog(user, String(d)));
        return;
      } catch { this.cfg.logger.error(`Could not write log file at ${loc}; falling back to console`); }
    }
    child.stdout?.on("data", d => { const s=String(d); this.state.appendLog(user,s); this.cfg.logger.info(s); });
    child.stderr?.on("data", d => { const s=String(d); this.state.appendLog(user,s); this.cfg.logger.error(s); });
  }

  private async _reservePort(min:number, max:number){ for(let p=min; p<=max; p++){ const ok=await new Promise<boolean>(res=>{ const s=net.createServer().once("error",()=>res(false)).once("listening",()=>s.close(()=>res(true))).listen(p,"127.0.0.1");}); if(ok){ const used=await tcpPortUsed.check(p); if(!used) return p; } } return -1; }
  private async _waitForAccept(port:number, timeoutMs:number){ const start=Date.now(); while(Date.now()-start<timeoutMs){ try{ if(await tcpPortUsed.check(port)) return true; }catch{} await this.cfg.delay(50);} return false; }
}
