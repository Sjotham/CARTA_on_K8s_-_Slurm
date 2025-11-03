// k8s-spawner.ts
import { KubeConfig, AppsV1Api, CoreV1Api, PortForward, Log } from "@kubernetes/client-node";
import * as net from "node:net";
import * as http from "node:http";
import * as stream from "node:stream";
import { LinkedList } from "mnemonist";
import { v4 as uuidv4 } from "uuid";
import type { Spawner, StartOptions, SpawnResult, SpawnStatus, ProxyTarget } from "./spawner";

/**
 * Concrete Kubernetes spawner with a fixed deployment spec:
 * - Namespace: carta
 * - PVC: carta-data (CephFS, RWX, rook-cephfs)
 * - Deployment/Service: one per user (names derived from username)
 * - Container: cartavis/carta:beta, mounts PVC at /images with subPath=<username>
 * - Exposes via local port-forward to 127.0.0.1:<port>
 */
export class K8sSpawner implements Spawner {
  private readonly namespace = "carta";
  private readonly pvcName = "carta-data";
  private readonly image = "cartavis/carta:beta";
  private readonly containerPort = 3002;

  private kc: KubeConfig;
  private core: CoreV1Api;
  private apps: AppsV1Api;
  private pf: PortForward;
  private logApi: Log;

  private startDelayMs: number;
  private localPortRange: { min: number; max: number };
  private logger: { info:(m:string)=>void; warn:(m:string)=>void; error:(m:string)=>void; debug?:(m:unknown)=>void; };
  private delay: (ms:number)=>Promise<void>;

  private state = new Map<string, {
    headerToken: string;
    workloadName: string;
    podName?: string;
    ready: boolean;
    localPort?: number;
    pfReq?: http.ClientRequest;
    pfStream?: stream.Duplex;
  }>();
  private logs = new Map<string, LinkedList<string>>();
  private static readonly LOG_LIMIT = 1000;

  constructor(cfg: {
    kubeconfigPath: string;               // path to mounted kubeconfig secret
    startDelayMs?: number;                // default 15s
    localPortRange?: { min:number; max:number }; // default 30020-30100
    logger: { info:(m:string)=>void; warn:(m:string)=>void; error:(m:string)=>void; debug?:(m:unknown)=>void; };
    delay: (ms:number)=>Promise<void>;
  }) {
    this.startDelayMs = cfg.startDelayMs ?? 15000;
    this.localPortRange = cfg.localPortRange ?? { min: 30020, max: 30100 };
    this.logger = cfg.logger; this.delay = cfg.delay;

    this.kc = new KubeConfig(); this.kc.loadFromFile(cfg.kubeconfigPath);
    this.core = this.kc.makeApiClient(CoreV1Api);
    this.apps = this.kc.makeApiClient(AppsV1Api);
    this.pf = new PortForward(this.kc);
    this.logApi = new Log(this.kc);
  }

  // ---------- Spawner ----------

  async start(username: string, opts?: StartOptions): Promise<SpawnResult> {
    const existing = this.state.get(username);
    if (existing && existing.ready && !opts?.forceRestart) {
      return { success:true, existing:true, status: await this.status(username), proxyHeaders:{ "carta-auth-token": existing.headerToken } };
    }
    if (existing && opts?.forceRestart) await this.stop(username);

    await this.ensureNamespace(); await this.ensurePvc();

    const name = this.workloadName(username);
    const token = uuidv4();

    // Apply Deployment + Service (fixed spec)
    const dep = this.deployment(name, username, token);
    await this.applyDeployment(dep);

    const svc = this.service(name);
    await this.applyService(svc);

    // Wait for ready pod
    const podName = await this.waitForReadyPod(username);
    if (!podName) return { success:false, status:{ running:false, ready:false } };

    // Port-forward to local
    const localPort = await this.reserveLocalPort();
    const { req, stream: pfStream } = await this.portForward(podName, this.containerPort, localPort);

    // Tail logs (best effort)
    this.tailLogs(username, podName).catch(()=>{});

    this.state.set(username, { headerToken: token, workloadName: name, podName, ready:true, localPort, pfReq: req, pfStream });

    return {
      success:true,
      status:{ running:true, ready:true, target: { host:"127.0.0.1", port: localPort, path:"/", headers:{ "carta-auth-token": token } } },
      proxyHeaders:{ "carta-auth-token": token },
      info:{ pod: podName, deployment: name, service: name, localPort }
    };
  }

  async stop(username: string): Promise<{ success: boolean }> {
    const s = this.state.get(username);
    const name = s?.workloadName ?? this.workloadName(username);
    // tear down port-forward
    try { s?.pfReq?.destroy(); } catch {}
    try { s?.pfStream?.destroy(); } catch {}
    // delete k8s resources (best-effort)
    await this.deleteDeployment(name).catch(()=>{});
    await this.deleteService(name).catch(()=>{});
    this.state.delete(username);
    return { success:true };
  }

  async status(username: string): Promise<SpawnStatus> {
    const s = this.state.get(username);
    if (!s) return { running:false, ready:false };
    if (s.podName) {
      try {
        const pod = await this.core.readNamespacedPod(s.podName, this.namespace);
        const phase = pod.body.status?.phase;
        const ready = (pod.body.status?.conditions ?? []).some(c => c.type === "Ready" && c.status === "True");
        if (!(phase === "Running" && ready)) return { running:false, ready:false };
      } catch { return { running:false, ready:false }; }
    }
    if (!s.localPort) return { running:true, ready:false };
    return { running:true, ready:!!s.ready, target:{ host:"127.0.0.1", port:s.localPort, path:"/", headers:{ "carta-auth-token": s.headerToken } } };
  }

  async logs(username: string, tail?: number) {
    const list = this.logs.get(username);
    if (!list?.size) return { success:false };
    if (!tail || tail >= list.size) return { success:true, log:list.toArray().join("") };
    const out:string[]=[]; let skip=list.size-tail; for(const ln of list){ if(skip-- > 0) continue; out.push(ln); }
    return { success:true, log: out.join("") };
  }

  async getProxyTarget(username: string): Promise<{ success: boolean; target?: ProxyTarget }> {
    const st = await this.status(username);
    if (!st.running || !st.ready || !st.target) return { success:false };
    return { success:true, target: st.target };
  }

  // ---------- Fixed spec builders ----------

  private workloadName(username: string) {
    const safe = username.toLowerCase().replace(/[^a-z0-9-]/g, "-").replace(/^-+|-+$/g, "");
    return `carta-backend-${safe}`;
  }

  private deployment(name: string, username: string, token: string) {
    const labels = { app: "carta-backend", instance: username };
    return {
      apiVersion: "apps/v1",
      kind: "Deployment",
      metadata: { name, namespace: this.namespace, labels },
      spec: {
        replicas: 1,
        strategy: { type: "Recreate" },
        selector: { matchLabels: labels },
        template: {
          metadata: { labels },
          spec: {
            securityContext: {
              runAsUser: 1000, runAsGroup: 1000, fsGroup: 1000, fsGroupChangePolicy: "OnRootMismatch",
            },
            containers: [{
              name: "carta-backend",
              image: this.image,
              imagePullPolicy: "IfNotPresent",
              ports: [{ name: "http", containerPort: this.containerPort }],
              volumeMounts: [{ name: "carta-storage", mountPath: "/images", subPath: username }],
              startupProbe: { tcpSocket: { port: this.containerPort }, failureThreshold: 30, periodSeconds: 2 },
              readinessProbe:{ tcpSocket: { port: this.containerPort }, initialDelaySeconds: 10, periodSeconds: 10, failureThreshold: 3 },
              livenessProbe: { tcpSocket: { port: this.containerPort }, initialDelaySeconds: 30, periodSeconds: 10, failureThreshold: 3 },
              env: [{ name: "CARTA_AUTH_TOKEN", value: token }],
              args: [], // fixed deployment; leave empty
            }],
            volumes: [{ name: "carta-storage", persistentVolumeClaim: { claimName: this.pvcName } }],
          }
        }
      }
    };
  }

  private service(name: string) {
    return {
      apiVersion: "v1",
      kind: "Service",
      metadata: { name, namespace: this.namespace },
      spec: {
        type: "NodePort",
        selector: { app: "carta-backend", instance: name.replace(/^carta-backend-/, "") }, // match deployment
        ports: [{ name: "tcp", port: this.containerPort, targetPort: this.containerPort }],
      },
    };
  }

  // ---------- K8s ops (idempotent) ----------

  private async ensureNamespace() {
    try { await this.core.readNamespace(this.namespace); }
    catch { await this.core.createNamespace({ metadata: { name: this.namespace } } as any); }
  }

  private async ensurePvc() {
    try { await this.core.readNamespacedPersistentVolumeClaim(this.pvcName, this.namespace); }
    catch {
      await this.core.createNamespacedPersistentVolumeClaim(this.namespace, {
        apiVersion: "v1", kind: "PersistentVolumeClaim",
        metadata: { name: this.pvcName },
        spec: {
          accessModes: ["ReadWriteMany"],
          storageClassName: "rook-cephfs",
          resources: { requests: { storage: "20Gi" } },
          volumeMode: "Filesystem",
        },
      });
    }
  }

  private async applyDeployment(dep: any) {
    const name = dep.metadata.name;
    try { await this.apps.readNamespacedDeployment(name, this.namespace);
      await this.apps.replaceNamespacedDeployment(name, this.namespace, dep);
    } catch { await this.apps.createNamespacedDeployment(this.namespace, dep); }
  }

  private async applyService(svc: any) {
    const name = svc.metadata.name;
    try { await this.core.readNamespacedService(name, this.namespace);
      await this.core.replaceNamespacedService(name, this.namespace, svc);
    } catch { await this.core.createNamespacedService(this.namespace, svc); }
  }

  private async deleteDeployment(name: string){ await this.apps.deleteNamespacedDeployment(name, this.namespace); }
  private async deleteService(name: string){ await this.core.deleteNamespacedService(name, this.namespace); }

  private async waitForReadyPod(username: string): Promise<string | undefined> {
    const sel = `app=carta-backend,instance=${username}`;
    const deadline = Date.now() + this.startDelayMs;
    while (Date.now() < deadline) {
      const pods = await this.core.listNamespacedPod(this.namespace, undefined, undefined, undefined, undefined, sel);
      for (const pod of pods.body.items) {
        const conds = pod.status?.conditions ?? [];
        const ready = conds.some(c => c.type === "Ready" && c.status === "True");
        if (pod.status?.phase === "Running" && ready) return pod.metadata?.name;
      }
      await this.delay(500);
    }
    return undefined;
  }

  private async reserveLocalPort(): Promise<number> {
    for (let p=this.localPortRange.min; p<=this.localPortRange.max; p++){
      const ok = await new Promise<boolean>(res => {
        const s = net.createServer().once("error",()=>res(false)).once("listening",()=>s.close(()=>res(true))).listen(p,"127.0.0.1");
      });
      if (ok) return p;
    }
    throw new Error("No available local port");
  }

  private async portForward(podName: string, podPort: number, localPort: number) {
    const server = http.createServer();
    await new Promise<void>(r => server.listen(localPort, "127.0.0.1", () => r()));
    return await new Promise<{ req: http.ClientRequest; stream: stream.Duplex }>((resolve, reject) => {
      this.pf.portForward(this.namespace, podName, [podPort], server, (err, req) => {
        if (err) return reject(err);
        resolve({ req, stream: req as unknown as stream.Duplex });
      });
    });
  }

  private async tailLogs(username: string, podName: string) {
    const list = new LinkedList<string>(); this.logs.set(username, list);
    const push = (s: string) => { while (list.size >= K8sSpawner.LOG_LIMIT) list.shift(); list.push(s); };
    const pass = new stream.PassThrough();
    pass.on("data", c => push(c.toString("utf8"))); pass.on("error", ()=>{}); pass.on("close", ()=>{});
    await this.logApi.log(this.namespace, podName, "carta-backend", pass, { follow:true, tailLines:500, timestamps:false });
  }
}
