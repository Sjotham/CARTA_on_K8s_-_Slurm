import { CoreV1Api, KubernetesListObject, Watch, KubeConfig } from '@kubernetes/client-node';
import { sharedClient, loadConfig } from './clients.ts';
import { V1ObjectMeta } from '@kubernetes/client-node';
import { setTimeout } from 'timers/promises';
import { EventEmitter } from 'events';

export abstract class ResourceReflector<T extends { metadata?: V1ObjectMeta }> extends EventEmitter {
  protected api: CoreV1Api;
  protected resources: Map<string, T> = new Map();
  protected kind: string = 'resource';
  protected namespace?: string;
  protected labelSelector?: string;
  protected fieldSelector?: string;
  protected timeoutSeconds = 10;
  protected requestTimeout = 60;
  protected restartSeconds = 30;
  protected omitNamespace = false;
  protected listMethodName: string;
  protected apiGroup: new (...args: any[]) => CoreV1Api = CoreV1Api;  
  protected watchTask?: Promise<void>;
  protected stopping = false;
  protected onFailure?: () => void;
  public firstLoadPromise: Promise<void>;
  private resolveFirstLoad!: () => void;
  private rejectFirstLoad!: (err: any) => void;
  protected kubeConfig: KubeConfig = new KubeConfig();

  constructor(kind: string, namespace?: string, labelSelector?: string, fieldSelector?: string) {
    super();
    this.kind = kind;
    this.namespace = namespace;
    this.labelSelector = labelSelector;
    this.fieldSelector = fieldSelector;

    this.kubeConfig.loadFromDefault();
    this.api = sharedClient(this.apiGroup);

    const methodMap: Record<string, { namespaced: string; allNamespaces: string }> = {
      pods: {
        namespaced: 'listNamespacedPod',
        allNamespaces: 'listPodForAllNamespaces',
      },
      services: {
        namespaced: 'listNamespacedService',
        allNamespaces: 'listServiceForAllNamespaces',
      },
      ingresses: {
        namespaced: 'listNamespacedIngress',
        allNamespaces: 'listIngressForAllNamespaces',
      },
      endpoints: {
        namespaced: 'listNamespacedEndpoints',
        allNamespaces: 'listEndpointsForAllNamespaces',
      },
    };

    const methodNames = methodMap[this.kind];
    if (!methodNames) {
      throw new Error(`No method mapping defined for kind: ${this.kind}`);
    }
    this.listMethodName = this.omitNamespace ? methodNames.allNamespaces : methodNames.namespaced;

    this.firstLoadPromise = new Promise((res, rej) => {
      this.resolveFirstLoad = res;
      this.rejectFirstLoad = rej;
    });
  }

  public getResources(): T[] {
    return Array.from(this.resources.values());
  }

  protected getKey(meta: V1ObjectMeta): string {
    return `${meta.namespace}/${meta.name}`;
  }

  protected async listAndUpdate(): Promise<string> {
    const method = (this.api as any)[this.listMethodName].bind(this.api);
    const args: any = {
      labelSelector: this.labelSelector,
      fieldSelector: this.fieldSelector,
      _request_timeout: this.requestTimeout,
    };
    if (!this.omitNamespace && this.namespace) {
      args.namespace = this.namespace;
    }
    const resp = await method(args);
    const items = (resp.body as KubernetesListObject<T>).items;
    this.resources.clear();
    for (const item of items) {
      if (item.metadata) {
        const key = this.getKey(item.metadata);
        this.resources.set(key, item);
      }
    }
    this.resolveFirstLoad();
    return (resp.body.metadata?.resourceVersion) || '0';
  }

  public async start(): Promise<void> {
    if (this.watchTask) {
      throw new Error(`Reflector for ${this.kind} already started`);
    }
    try {
      await this.listAndUpdate();
    } catch (err) {
      this.rejectFirstLoad(err);
      throw err;
    }
    this.watchTask = this.watchAndUpdate();
  }

  public async stop(): Promise<void> {
    this.stopping = true;
    if (this.watchTask) {
      await this.watchTask;
    }
  }

  private async watchAndUpdate(): Promise<void> {
    let resourceVersion = '0';
    let delay = 0.1;
    const watch = new Watch(this.kubeConfig);
    while (!this.stopping) {
      try {
        resourceVersion = await this.listAndUpdate();
        delay = 0.1;

        const watchArgs: any = {
          labelSelector: this.labelSelector,
          fieldSelector: this.fieldSelector,
          resourceVersion,
          timeoutSeconds: this.timeoutSeconds,
        };
        if (!this.omitNamespace && this.namespace) {
          watchArgs.namespace = this.namespace;
        }

        const method = (this.api as any)[this.listMethodName].bind(this.api);
        const stream = await watch.watch(
          method,
          watchArgs,
          (phase: string, obj: T) => {
            if (!obj.metadata) return;
            const key = this.getKey(obj.metadata);
            if (phase === 'DELETED') {
              this.resources.delete(key);
            } else {
              this.resources.set(key, obj);
              resourceVersion = obj.metadata.resourceVersion || resourceVersion;
            }
          },
          (err: any) => {
            if (err) {
              console.error(`${this.kind} reflector error:`, err);
            }
          }
        );

        await stream.done;
      } catch (err) {
        console.warn(`${this.kind} watch failed:`, err);
        resourceVersion = '0';
        delay *= 2;
        if (delay > 30) {
          if (this.onFailure) this.onFailure();
          return;
        }
        await setTimeout(delay * 1000);
      }
    }
  }
}

export class NamespacedResourceReflector<T extends { metadata?: V1ObjectMeta }> extends ResourceReflector<T> {
  constructor(kind: string, namespace: string, labelSelector?: string, fieldSelector?: string) {
    super(kind, namespace, labelSelector, fieldSelector);
    this.omitNamespace = false;
  }
}

export class MultiNamespaceResourceReflector<T extends { metadata?: V1ObjectMeta }> extends ResourceReflector<T> {
  constructor(kind: string, labelSelector?: string, fieldSelector?: string) {
    super(kind, undefined, labelSelector, fieldSelector);
    this.omitNamespace = true;
  }
}
