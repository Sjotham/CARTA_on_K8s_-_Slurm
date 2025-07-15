// src/proxy.ts
import fs from 'fs';
import path from 'path';
import { CoreV1Api, NetworkingV1Api, V1Ingress, V1Service, V1Endpoints, V1DeleteOptions } from '@kubernetes/client-node';
import { makeIngress } from './objects.ts';
// import { exponentialBackoff } from './utils';
import { ResourceReflector } from './reflector.ts';
import { escapeSlug } from './slugs.ts';
import { generateHashedSlug } from './utils.ts';
import { exponentialBackoff } from './Utils1.ts';
import { loadConfig, sharedClient } from './clients.ts';
import * as k8s from '@kubernetes/client-node';
import { EventEmitter } from 'events';

class IngressReflector extends ResourceReflector<k8s.V1Ingress> {
  kind = 'ingresses';
  apiGroupName = 'NetworkingV1Api';
  firstLoadFuture: Promise<void>;

  get ingresses(): Record<string, k8s.V1Ingress> {
    const obj: Record<string, k8s.V1Ingress> = {};
    for (const [key, value] of this.resources.entries()) {
      obj[key] = value;
    }
    return obj;
  }

  constructor(namespace: string, labelSelector?: string) {
    super('ingresses', namespace, labelSelector);  // Pass all needed args
    this.firstLoadFuture = new Promise<void>((resolve) => {
      this.once('updated', () => resolve());
    });
  }
}


class ServiceReflector extends ResourceReflector<V1Service> {
  kind = 'services';

  get services(): Record<string, V1Service> {
    const obj: Record<string, V1Service> = {};
    for (const [key, value] of this.resources.entries()) {
      obj[key] = value;
    }
    return obj;
  }
}


class EndpointsReflector extends ResourceReflector<V1Endpoints> {
  kind = 'endpoints';

  get endpoints(): Record<string, V1Endpoints> {
    const obj: Record<string, V1Endpoints> = {};
    for (const [key, value] of this.resources.entries()) {
      obj[key] = value;
    }
    return obj;
  }
}


export class KubeIngressProxy {
  private coreApi: CoreV1Api;
  private networkingApi: NetworkingV1Api;
  private namespace: string;
  private componentLabel: string;
  private ingressReflector: IngressReflector;
  private serviceReflector: ServiceReflector;
  private endpointReflector: EndpointsReflector;

  constructor(
    coreApi: CoreV1Api,
    networkingApi: NetworkingV1Api,
    namespace: string,
    componentLabel = 'singleuser-server'
  ) {
    this.coreApi = coreApi;
    this.networkingApi = networkingApi;
    this.namespace = namespace;
    this.componentLabel = componentLabel;
  
    // Define labels as a key-value object
    const labels = {
      component: this.componentLabel,
      'hub.jupyter.org/proxy-route': 'true',
    };
  
    // Convert the labels object to a label selector string: "key1=value1,key2=value2"
    const labelSelector = Object.entries(labels)
      .map(([key, value]) => `${key}=${value}`)
      .join(',');
  
    // Pass the string labelSelector to each ResourceReflector
    this.ingressReflector = new IngressReflector(namespace, labelSelector);
    this.serviceReflector = new ServiceReflector(namespace, labelSelector);
    this.endpointReflector = new EndpointsReflector(namespace, labelSelector);
  }
  

  private safeNameForRoutespec(routespec: string): string {
    const slug = escapeSlug(routespec);
    return generateHashedSlug(`jupyter-${slug}-route`).toLowerCase();
  }

  async addRoute(routespec: string, target: string, data: Record<string, any>) {
    const safeName = this.safeNameForRoutespec(routespec);
    const fullName = `${this.namespace}/${safeName}`;

    const endpointServiceIngress = makeIngress(safeName, routespec, target, data, this.namespace);
    const [endpoint, service, ingress] = endpointServiceIngress;

    const ensureObject = async (
      createFunc: Function,
      patchFunc: Function,
      body: any,
      kind: string
    ) => {
      try {
        await createFunc(this.namespace, body);
        console.info(`Created ${kind}/${safeName}`);
      } catch (e: any) {
        if (e?.response?.statusCode === 409) {
          console.warn(`Trying to patch ${kind}/${safeName}, it already exists`);
          await patchFunc(this.namespace, body.metadata.name, body);
        } else {
          throw e;
        }
      }
    };

    if (endpoint) {
      await ensureObject(
        this.coreApi.createNamespacedEndpoints.bind(this.coreApi),
        this.coreApi.patchNamespacedEndpoints.bind(this.coreApi),
        endpoint,
        'endpoints'
      );
      await exponentialBackoff(
        async () => fullName in this.endpointReflector.endpoints,
        `Could not find endpoints/${safeName} after creating it`
      );
    }

    if (service) {
      await ensureObject(
        this.coreApi.createNamespacedService.bind(this.coreApi),
        this.coreApi.patchNamespacedService.bind(this.coreApi),
        service,
        'service'
      );
      await exponentialBackoff(
        async () => fullName in this.serviceReflector.services,
        `Could not find services/${safeName} after creating it`
      );
    }

    await ensureObject(
      this.networkingApi.createNamespacedIngress.bind(this.networkingApi),
      this.networkingApi.patchNamespacedIngress.bind(this.networkingApi),
      ingress,
      'ingress'
    );
    await exponentialBackoff(
      async () => fullName in this.ingressReflector.ingresses,
      `Could not find ingress/${safeName} after creating it`
    );
  }

  async deleteRoute(routespec: string) {
    const safeName = this.safeNameForRoutespec(routespec);
    const deleteOptions: V1DeleteOptions = { gracePeriodSeconds: 0 };
  
    const deleteIfExists = async (kind: string, deletePromise: Promise<any>) => {
      try {
        await deletePromise;
        console.info(`Deleted ${kind}/${safeName}`);
      } catch (e: any) {
        if (e?.response?.statusCode !== 404) {
          throw e;
        }
        console.warn(`Could not delete ${kind}/${safeName}: does not exist`);
      }
    };
  
    await Promise.all([
      deleteIfExists(
        'endpoint',
        this.coreApi.deleteNamespacedEndpoints(
          safeName,
          this.namespace,
          undefined, // pretty
          undefined, // dryRun
          undefined, // gracePeriodSeconds
          undefined, // orphanDependents
          undefined, // propagationPolicy
          deleteOptions // body
        )
      ),
      deleteIfExists(
        'service',
        this.coreApi.deleteNamespacedService(
          safeName,
          this.namespace,
          undefined,
          undefined,
          undefined,
          undefined,
          undefined,
          deleteOptions
        )
      ),
      deleteIfExists(
        'ingress',
        this.networkingApi.deleteNamespacedIngress(
          safeName,
          this.namespace,
          undefined,
          undefined,
          undefined,
          undefined,
          undefined,
          deleteOptions
        )
      ),
    ]);
  }
  

  async getAllRoutes(): Promise<Record<string, any>> {
    await this.ingressReflector.firstLoadFuture;
    const routes: Record<string, any> = {};

    for (const ingress of Object.values(this.ingressReflector.ingresses)) {
      const metadata = ingress.metadata as any;
      const annotations = metadata.annotations;
      const routespec = annotations['hub.jupyter.org/proxy-routespec'];

      routes[routespec] = {
        routespec,
        target: annotations['hub.jupyter.org/proxy-target'],
        data: JSON.parse(annotations['hub.jupyter.org/proxy-data']),
      };
    }

    return routes;
  }
}
