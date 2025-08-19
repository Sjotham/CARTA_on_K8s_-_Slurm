// src/spawner.ts

import { CoreV1Api, NetworkingV1Api, V1Pod, KubeConfig } from '@kubernetes/client-node';
import slugify from 'slugify';
import * as k8s from '@kubernetes/client-node';

import {
  makePod,
  makePVC,
  makeService,
  makeIngress,
  makeNamespace,
  makeOwnerReference,
} from './objects.ts';
import { NamespacedResourceReflector } from './reflector.ts';
import { exponentialBackoff } from './Utils1.ts';
import { loadConfig, sharedClient } from './clients.ts';

interface User {
  name: string;
  id: string;
  spawner?: any;
  url?: string;
}

interface UserOptions {
  image?: string;
  cpuLimit?: string;
  memoryLimit?: string;
  cpuGuarantee?: string;
  memoryGuarantee?: string;
  [key: string]: any;
}

interface KubeSpawnerOptions {
  user: User;
  namespace?: string;
  image?: string;
  cpuLimit?: string;
  memoryLimit?: string;
  workingDir?: string;
  command: string | string[];
  args?: string | string[];
  env?: Record<string, string>;
  hubUrl?: string;
  apiToken?: string;
  ingressHost?: string;
  enableTLS?: boolean;
  userOptions?: UserOptions;
  kubeApi?: CoreV1Api;
  netApi?: NetworkingV1Api;
}

export class KubeSpawner {
  private user: User;
  private namespace: string;
  private image: string;
  private cpuLimit: string;
  private memoryLimit: string;
  private workingDir: string;
  private command: string[];
  private args: string[];
  private env: Record<string, string>;
  private hubUrl?: string;
  private apiToken?: string;
  private ingressHost?: string;
  private enableTLS: boolean;
  private userOptions: UserOptions;
  private kubeApi: CoreV1Api;
  private kubeConfig: KubeConfig;
  private coreApi!: k8s.CoreV1Api;
  private netApi!: k8s.NetworkingV1Api;
  private podReflector: NamespacedResourceReflector<V1Pod>;

  constructor(options: KubeSpawnerOptions) {
    this.user = options.user;
    this.namespace = options.namespace || 'default';
    this.image = options.image || 'cartavis/carta:beta';
    this.cpuLimit = options.cpuLimit || '500m';
    this.memoryLimit = options.memoryLimit || '1Gi';
    this.workingDir = options.workingDir || '/';
    this.command = Array.isArray(options.command) ? options.command : [options.command];
    this.args = Array.isArray(options.args) ? options.args : [];
    this.env = options.env || {};
    this.hubUrl = options.hubUrl;
    this.apiToken = options.apiToken;
    this.ingressHost = options.ingressHost;
    this.enableTLS = options.enableTLS ?? false;
    this.userOptions = options.userOptions || {};

    const kubeConfig = new KubeConfig();
    kubeConfig.loadFromDefault();
    this.kubeConfig = kubeConfig;
    this.kubeApi = options.kubeApi || kubeConfig.makeApiClient(CoreV1Api);
    this.netApi = options.netApi || kubeConfig.makeApiClient(NetworkingV1Api);

    this.podReflector = new NamespacedResourceReflector<V1Pod>('pods', this.namespace, this.kubeApi, this.kubeConfig);
    this.podReflector.start().catch(console.error);

    this.applyUserOptions();
  }

  private applyUserOptions() {
    const opts = this.userOptions;
    if (opts.image) this.image = opts.image;
    if (opts.cpuLimit) this.cpuLimit = opts.cpuLimit;
    if (opts.memoryLimit) this.memoryLimit = opts.memoryLimit;
  }

  private safeName(prefix: string): string {
    return `${prefix}-${slugify(this.user.name, { lower: true, strict: true })}`;
  }

  public getState(): Record<string, any> {
    return {
      podName: this.safeName('carta'),
      namespace: this.namespace,
      image: this.image,
      url: this.hubUrl,
    };
  }

  public loadState(state: Record<string, any>): void {
    if (state.namespace) this.namespace = state.namespace;
    if (state.image) this.image = state.image;
    if (state.url) this.hubUrl = state.url;
  }

  public async getLogs(): Promise<string> {
    const podName = this.safeName('carta');
    const logs = await this.kubeApi.readNamespacedPodLog({
      name: podName,
      namespace: this.namespace
    });
    return typeof logs === 'string' ? logs : '';
  }

  public async progress(): Promise<string[]> {
    return [`Spawning pod ${this.safeName('carta')}...`];
  }

  public getResourceNames(): Record<string, string> {
    return {
      pod: this.safeName('carta'),
      pvc: this.safeName('pvc'),
      svc: this.safeName('svc'),
      ingress: this.safeName('ingress'),
    };
  }

  public async start(): Promise<V1Pod> {
    await this.preSpawnHook();

    const pvcName = this.safeName('pvc');
    const podName = this.safeName('carta');

    const pvc = makePVC(pvcName, '1Gi');
    try {
      await this.kubeApi.createNamespacedPersistentVolumeClaim({
        namespace: this.namespace,
        body: pvc
      });
    } catch (e: any) {
      if (e?.response?.statusCode !== 409) throw e;
    }

    const port = 3001;
    const pod = makePod(podName, this.command, port, this.image, this.args, this.env, pvcName);
    await this.kubeApi.createNamespacedPod({
      namespace: this.namespace,
      body: pod
    });

    const service = makeService(this.safeName('svc'), { app: 'carta', user: this.user.name }, 3001);
    try {
      await this.kubeApi.createNamespacedService({
        namespace: this.namespace,
        body: service
      });
    } catch (e: any) {
      if (e?.response?.statusCode !== 409) throw e;
    }

    if (this.ingressHost) {
      await this.createIngress(port);
      this.hubUrl = `${this.enableTLS ? 'https' : 'http'}://${this.ingressHost}/user/${this.user.name}`;
    }

    await this.postStartHook();
    return this.kubeApi.readNamespacedPod({
      name: podName,
      namespace: this.namespace
    });
  }

  private async createIngress(port: number): Promise<void> {
    const ingressName = this.safeName('ingress');
    const annotations = { app: 'carta', user: this.user.name } as Record<string, string>;
    const labels = { app: 'carta', user: this.user.name } as Record<string, string>;

    const [endpoint, service, ingress] = makeIngress(
      ingressName,
      this.ingressHost!,
      '127.0.0.1',
      annotations,
      this.namespace,
      port,
      labels,
      this.enableTLS,
      'carta-tls'
    );

    try {
      await (this.kubeApi as any).createNamespacedEndpoints({
        namespace: this.namespace,
        body: endpoint
      });
      await this.kubeApi.createNamespacedService({
        namespace: this.namespace,
        body: service
      });
      await this.netApi.createNamespacedIngress({
        namespace: this.namespace,
        body: ingress
      });
    } catch (e: any) {
      if (e?.response?.statusCode !== 409) throw e;
    }
  }

  public async stop(): Promise<void> {
    const podName = this.safeName('carta');
    const pvcName = this.safeName('pvc');
    const svcName = this.safeName('svc');
    const ingressName = this.safeName('ingress');

    try { await this.kubeApi.deleteNamespacedPod({ name: podName, namespace: this.namespace }); } catch {}
    try { await this.kubeApi.deleteNamespacedService({ name: svcName, namespace: this.namespace }); } catch {}
    try { await this.kubeApi.deleteNamespacedPersistentVolumeClaim({ name: pvcName, namespace: this.namespace }); } catch {}
    try { await this.netApi.deleteNamespacedIngress({ name: ingressName, namespace: this.namespace }); } catch {}

    await this.postStopHook();
  }

  private async preSpawnHook(): Promise<void> {
    console.log(`Pre-spawn hook for ${this.user.name}`);
  }

  private async postStartHook(): Promise<void> {
    console.log(`Post-start hook for ${this.user.name}`);
  }

  private async postStopHook(): Promise<void> {
    console.log(`Post-stop hook for ${this.user.name}`);
  }

  public async getStatus(): Promise<string> {
    try {
      const pod = await this.kubeApi.readNamespacedPodStatus({
        name: this.safeName('carta'),
        namespace: this.namespace
      });
      return (pod as any).body?.status?.phase || (pod as any).status?.phase || 'Unknown';
    } catch {
      return 'Not Found';
    }
  }
}
