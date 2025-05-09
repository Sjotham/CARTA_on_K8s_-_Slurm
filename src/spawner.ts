// src/KubeSpawner.ts
import * as k8s from '@kubernetes/client-node';
import { CoreV1Api, KubeConfig, V1Pod } from '@kubernetes/client-node';

interface User {
  name: string;
  id: string;
  spawner?: any;
  url?: string;
}

interface KubeSpawnerOptions {
  user: User;
  namespace?: string;
  image?: string;
  cpuLimit?: string;
  memoryLimit?: string;
  workingDir?: string;
  command?: string[];
  args?: string[];
  env?: Record<string, string>;
  hubUrl?: string;
  apiToken?: string;
  userOptions?: Record<string, any>;
}

export class KubeSpawner {
  private user: User;
  public hubUrl?: string;
  public apiToken?: string;
  public userOptions: Record<string, any>;
  private namespace: string;
  private image: string;
  private cpuLimit: string;
  private memoryLimit: string;
  private workingDir: string;
  private command: string[];
  private args: string[];
  private env: Record<string, string>;
  private kubeApi: CoreV1Api;

  constructor(options: KubeSpawnerOptions) {
    this.user = options.user;
    this.namespace = options.namespace || 'default';
    this.image = options.image || 'jupyter/base-notebook:latest';
    this.cpuLimit = options.cpuLimit || '500m';
    this.memoryLimit = options.memoryLimit || '1Gi';
    this.workingDir = options.workingDir || '/home/jovyan';
    this.command = options.command || ['start-notebook.sh'];
    this.args = options.args || [];
    this.env = options.env || {};
    this.hubUrl = options.hubUrl;
    this.apiToken = options.apiToken;
    this.userOptions = options.userOptions || {};
    const kubeConfig = new KubeConfig();
    kubeConfig.loadFromDefault();
    this.kubeApi = kubeConfig.makeApiClient(CoreV1Api);
  }

  private generatePodName(): string {
    return `jupyter-${this.user.name}`;
  }

  public async start(): Promise<V1Pod> {
    const podName = this.generatePodName();

    const podManifest: V1Pod = {
      metadata: {
        name: podName,
        labels: {
          app: 'jupyterhub',
          user: this.user.name,
        },
      },
      spec: {
        containers: [
          {
            name: 'notebook',
            image: this.image,
            command: this.command,
            args: this.args,
            workingDir: this.workingDir,
            resources: {
              limits: {
                cpu: this.cpuLimit,
                memory: this.memoryLimit,
              },
            },
            env: Object.entries(this.env).map(([name, value]) => ({ name, value })) as k8s.V1EnvVar[],
          },
        ],
        restartPolicy: 'Never',
      },
    };
    

    try {
      const response = await this.kubeApi.createNamespacedPod(this.namespace, podManifest);
      return response.body; 
    } catch (error) {
      throw new Error(`Failed to create pod: ${error}`);
    }
  }

  public async stop(): Promise<void> {
    const podName = this.generatePodName();

    try {
      await this.kubeApi.deleteNamespacedPod(podName, this.namespace);
    } catch (error) {
      throw new Error(`Failed to delete pod: ${error}`);
    }
  }

  public async getStatus(): Promise<string> {
    const podName = this.generatePodName();

    try {
      const response = await this.kubeApi.readNamespacedPodStatus(podName, this.namespace);
return response.body.status?.phase || 'Unknown';
    } catch (error) {
      throw new Error(`Failed to get pod status: ${error}`);
    }
  }
}
