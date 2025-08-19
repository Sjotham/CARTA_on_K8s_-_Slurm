import {
  CoreV1Api,
  KubernetesListObject,
  KubernetesObject,
  Watch,
  KubeConfig,
} from '@kubernetes/client-node';
import { V1ObjectMeta } from '@kubernetes/client-node';
import { setTimeout as sleep } from 'timers/promises';
import { EventEmitter } from 'events';

type K8sListBody<T extends KubernetesObject> = KubernetesListObject<T>;
type K8sListResp<T extends KubernetesObject> = K8sListBody<T> | { body: K8sListBody<T> };

function unwrapList<T extends KubernetesObject>(resp: K8sListResp<T>): K8sListBody<T> {
  const maybe = resp as any;
  if (maybe && Array.isArray(maybe.items)) return maybe as K8sListBody<T>;
  if (maybe && maybe.body && Array.isArray(maybe.body.items)) return maybe.body as K8sListBody<T>;
  // Helpful diagnostics if the client shape changes
  // eslint-disable-next-line no-console
  console.error('[Reflector] Unexpected list response shape:', {
    type: typeof resp,
    keys: resp && Object.keys(resp as any),
    bodyType: resp && typeof (resp as any).body,
    bodyKeys:
      resp && (resp as any).body && Object.keys((resp as any).body),
  });
  throw new Error('Kubernetes list call did not return an object with .items');
}

function watchPathFor(kind: string, ns?: string, allNamespaces = false): string {
  const pick = (namespaced: string, all: string) => (allNamespaces ? all : namespaced);

  switch (kind) {
    case 'pods':
      return pick(`/api/v1/namespaces/${ns}/pods`, `/api/v1/pods`);
    case 'services':
      return pick(`/api/v1/namespaces/${ns}/services`, `/api/v1/services`);
    case 'endpoints':
      return pick(`/api/v1/namespaces/${ns}/endpoints`, `/api/v1/endpoints`);
    case 'ingresses':
      return pick(
        `/apis/networking.k8s.io/v1/namespaces/${ns}/ingresses`,
        `/apis/networking.k8s.io/v1/ingresses`,
      );
    default:
      throw new Error(`No watch path mapping for kind: ${kind}`);
  }
}


export abstract class ResourceReflector<T extends { metadata?: V1ObjectMeta }>
  extends EventEmitter {
  protected api: CoreV1Api;
  protected kubeConfig: KubeConfig;

  protected resources: Map<string, T> = new Map();
  protected kind = 'resource';
  protected namespace?: string;
  protected labelSelector?: string;
  protected fieldSelector?: string;

  // Tunables
  protected timeoutSeconds = 10;     // per-watch server timeout
  protected requestTimeout = 60;     // client-side request timeout
  protected restartSeconds = 30;     // not used directly; kept for compatibility
  protected omitNamespace = false;

  protected listMethodName: string;
  protected apiGroup: new (...args: any[]) => CoreV1Api = CoreV1Api;

  protected watchTask?: Promise<void>;
  protected stopping = false;
  protected onFailure?: () => void;

  public firstLoadPromise: Promise<void>;
  private resolveFirstLoad!: () => void;
  private rejectFirstLoad!: (err: any) => void;

  // Track the active watch request so we can abort on stop()
  private currentWatchReq?: { abort: () => void };

  constructor(
    kind: string,
    namespace: string | undefined,
    kubeApi: CoreV1Api,
    kubeConfig: KubeConfig,
    labelSelector?: string,
    fieldSelector?: string
  ) {
    super();
    this.kind = kind;
    this.namespace = namespace;
    this.labelSelector = labelSelector;
    this.fieldSelector = fieldSelector;
    this.api = kubeApi;
    this.kubeConfig = kubeConfig; // external config (e.g., skipTLSVerify)

    const methodMap: Record<
      string,
      { namespaced: string; allNamespaces: string }
    > = {
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
    this.listMethodName = this.omitNamespace
      ? methodNames.allNamespaces
      : methodNames.namespaced;

    this.firstLoadPromise = new Promise<void>((res, rej) => {
      this.resolveFirstLoad = res;
      this.rejectFirstLoad = rej;
    });
  }

  public getResources(): T[] {
    return Array.from(this.resources.values());
  }

  protected getKey(meta: V1ObjectMeta): string {
    // Always include namespace if available to avoid collisions in multi-namespace mode
    return `${meta.namespace ?? ''}/${meta.name}`;
  }

  /**
   * Lists current resources and updates cache.
   * Returns the latest resourceVersion to seed the watch call.
   */
  protected async listAndUpdate(): Promise<string> {
    const method = (this.api as any)[this.listMethodName].bind(this.api);

    // NOTE: Some client versions expect positional args. However, when used
    // via Watch with a method reference, an options object is supported.
    const args: any = {
      labelSelector: this.labelSelector,
      fieldSelector: this.fieldSelector,
      _request_timeout: this.requestTimeout,
    };
    if (!this.omitNamespace && this.namespace) {
      args.namespace = this.namespace;
    }

    const resp: K8sListResp<T> = await method(args);
    const list = unwrapList<T>(resp);

    this.resources.clear();
    for (const item of list.items ?? []) {
      if (item?.metadata?.name) {
        const key = this.getKey(item.metadata);
        this.resources.set(key, item);
      }
    }

    // Unblock firstLoad waiters on successful list
    this.resolveFirstLoad();

    return list.metadata?.resourceVersion ?? '0';
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
    this.stopping = false;
    this.watchTask = this.watchAndUpdate();
  }

  public async stop(): Promise<void> {
    this.stopping = true;
    // Abort the current watch HTTP request (if any)
    try {
      this.currentWatchReq?.abort();
    } catch {
      /* ignore */
    }
    if (this.watchTask) {
      await this.watchTask;
      this.watchTask = undefined;
    }
  }

  /**
   * Continuous watch loop with exponential backoff.
   * Uses Watch from client-node; the returned object supports `abort()`.
   */
  private async watchAndUpdate(): Promise<void> {
    const watch = new Watch(this.kubeConfig);

    let resourceVersion = '0';
    let delay = 0.1; // seconds; exponential backoff up to ~30s

    while (!this.stopping) {
      try {
        // Always refresh the cache first (and get current RV)
        resourceVersion = await this.listAndUpdate();
        delay = 0.1;

        const watchArgs: any = {
          labelSelector: this.labelSelector,
          fieldSelector: this.fieldSelector,
          resourceVersion,
          timeoutSeconds: this.timeoutSeconds,
          allowWatchBookmarks: true,
        };
        if (!this.omitNamespace && this.namespace) {
          watchArgs.namespace = this.namespace;
        }

        const method = (this.api as any)[this.listMethodName].bind(this.api);

        // Promise we can await until watch finishes or errors
        let resolveDone!: () => void;
        let rejectDone!: (e: any) => void;
        const done = new Promise<void>((resolve, reject) => {
          resolveDone = resolve;
          rejectDone = reject;
        });

        const onEvent = (phase: string, obj: T) => {
          if (!obj?.metadata?.name) return;
          const key = this.getKey(obj.metadata);
          if (phase === 'DELETED') {
            this.resources.delete(key);
          } else {
            this.resources.set(key, obj);
            const rv = obj.metadata.resourceVersion;
            if (rv) resourceVersion = rv;
          }
          // Emit events for external consumers if needed
          this.emit(phase.toLowerCase(), obj);
        };

        const onDone = (err: any) => {
          if (err) {
            // eslint-disable-next-line no-console
            console.error(`${this.kind} reflector error:`, err);
            rejectDone(err);
          } else {
            resolveDone();
          }
        };

        const req = await watch.watch(method, watchArgs, onEvent, onDone);
        this.currentWatchReq = req;

        try {
          await done; // wait for server-side close or error
        } finally {
          // Always abort the request handle to free sockets
          try {
            req.abort();
          } catch {
            /* ignore */
          }
          if (this.currentWatchReq === req) {
            this.currentWatchReq = undefined;
          }
        }
      } catch (err) {
        // eslint-disable-next-line no-console
        console.warn(`${this.kind} watch failed:`, err);
        resourceVersion = '0'; // reset; the next list will re-sync
        delay = Math.min(delay * 2, 30);
        if (this.onFailure && delay >= 30) {
          try {
            this.onFailure();
          } catch {
            /* ignore hook errors */
          }
        }
        if (this.stopping) break;
        await sleep(delay * 1000);
      }
    }
  }
}

export class NamespacedResourceReflector<T extends KubernetesObject> extends ResourceReflector<T> {
  constructor(
    kind: string,
    namespace: string,
    kubeApi: CoreV1Api,
    kubeConfig: KubeConfig,
    labelSelector?: string,
    fieldSelector?: string
  ) {
    super(kind, namespace, kubeApi, kubeConfig, labelSelector, fieldSelector);
    this.omitNamespace = false;
  }
}

export class MultiNamespaceResourceReflector<T extends KubernetesObject> extends ResourceReflector<T> {
  constructor(
    kind: string,
    kubeApi: CoreV1Api,
    kubeConfig: KubeConfig,
    labelSelector?: string,
    fieldSelector?: string
  ) {
    super(kind, undefined, kubeApi, kubeConfig, labelSelector, fieldSelector);
    this.omitNamespace = true;
  }
}
