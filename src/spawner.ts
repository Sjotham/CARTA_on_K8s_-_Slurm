// src/spawner.ts

import { CoreV1Api, NetworkingV1Api, V1Pod } from '@kubernetes/client-node';
import { KubeConfig } from '@kubernetes/client-node';
import slugify from 'slugify';
import * as k8s from '@kubernetes/client-node';

import {
  makePod,
  makePVC,
  makeService,
  makeIngress,
  makeNamespace,
  makeOwnerReference
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
  private coreApi!: k8s.CoreV1Api;
  private netApi!: k8s.NetworkingV1Api;
  private podReflector: NamespacedResourceReflector<V1Pod>;

  constructor(options: KubeSpawnerOptions) {
    this.user = options.user;
    this.namespace = options.namespace || 'default';
    this.image = options.image || 'jupyter/base-notebook:latest';
    this.cpuLimit = options.cpuLimit || '500m';
    this.memoryLimit = options.memoryLimit || '1Gi';
    this.workingDir = options.workingDir || '/home/jovyan';
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
    this.kubeApi = options.kubeApi || kubeConfig.makeApiClient(CoreV1Api);
    this.netApi = options.netApi || kubeConfig.makeApiClient(NetworkingV1Api);

    this.podReflector = new NamespacedResourceReflector<V1Pod>('pods', this.namespace);
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
      podName: this.safeName('jupyter'),
      namespace: this.namespace,
      image: this.image,
      url: this.hubUrl
    };
  }

  public loadState(state: Record<string, any>): void {
    if (state.namespace) this.namespace = state.namespace;
    if (state.image) this.image = state.image;
    if (state.url) this.hubUrl = state.url;
  }

  public async getLogs(): Promise<string> {
    const podName = this.safeName('jupyter');
    const logs = await this.kubeApi.readNamespacedPodLog(podName, this.namespace);
    return logs.body;
  }

  public async progress(): Promise<string[]> {
    return [`Spawning pod ${this.safeName('jupyter')}...`];
  }

  public getResourceNames(): Record<string, string> {
    return {
      pod: this.safeName('jupyter'),
      pvc: this.safeName('pvc'),
      svc: this.safeName('svc'),
      ingress: this.safeName('ingress')
    };
  }

  public async start(): Promise<V1Pod> {
    await this.preSpawnHook();

    const pvcName = this.safeName('pvc');
    const podName = this.safeName('jupyter');

    const pvc = makePVC(pvcName, '1Gi');
    try {
      await this.kubeApi.createNamespacedPersistentVolumeClaim(this.namespace, pvc);
    } catch (e: any) {
      if (e?.response?.statusCode !== 409) throw e;
    }

    const pod = makePod(podName, this.command, 8888, this.image, this.args, this.env, pvcName);
    await this.kubeApi.createNamespacedPod(this.namespace, pod);

    const service = makeService(this.safeName('svc'), { app: 'jupyterhub', user: this.user.name });
    try {
      await this.kubeApi.createNamespacedService(this.namespace, service);
    } catch (e: any) {
      if (e?.response?.statusCode !== 409) throw e;
    }

    if (this.ingressHost) {
      await this.createIngress();
      this.hubUrl = `${this.enableTLS ? 'https' : 'http'}://${this.ingressHost}/hub/user/${this.user.name}`;
    }

    await this.postStartHook();
    return this.kubeApi.readNamespacedPod(podName, this.namespace).then(res => res.body);
  }

  private async createIngress(): Promise<void> {
    const ingressName = this.safeName('ingress');
    const svcName = this.safeName('svc');
    const port = 8888;
    const annotations = {
      app: 'jupyterhub',
      user: this.user.name,
    };
    const labels = {
      app: 'jupyterhub',
      user: this.user.name,
    };

    const [endpoint, service, ingress] = makeIngress(
      ingressName,
      this.ingressHost!,
      '127.0.0.1',
      annotations,
      this.namespace,
      port,
      labels,
      this.enableTLS,
      'jupyterhub-tls'
    );

    try {
      await this.coreApi.createNamespacedEndpoints(this.namespace, endpoint);
      await this.coreApi.createNamespacedService(this.namespace, service);
      await this.netApi.createNamespacedIngress(this.namespace, ingress);
    } catch (e: any) {
      if (e?.response?.statusCode !== 409) throw e;
    }
  }

  public async stop(): Promise<void> {
    const podName = this.safeName('jupyter');
    const pvcName = this.safeName('pvc');
    const svcName = this.safeName('svc');
    const ingressName = this.safeName('ingress');

    await this.kubeApi.deleteNamespacedPod(podName, this.namespace);
    await this.kubeApi.deleteNamespacedService(svcName, this.namespace);
    await this.kubeApi.deleteNamespacedPersistentVolumeClaim(pvcName, this.namespace);
    await this.netApi.deleteNamespacedIngress(ingressName, this.namespace);

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
      const pod = await this.kubeApi.readNamespacedPodStatus(this.safeName('jupyter'), this.namespace);
      return pod.body.status?.phase || 'Unknown';
    } catch {
      return 'Not Found';
    }
  }
}
