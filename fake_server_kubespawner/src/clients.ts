// src/clients.ts

import {
  KubeConfig,
  CoreV1Api,
  AppsV1Api,
  CustomObjectsApi,
  NetworkingV1Api,
  Cluster,
  ApiType,
} from '@kubernetes/client-node';
import fs from 'fs';
import os from 'os';
import path from 'path';

const clientCache = new Map<string, any>();
const kubeConfig = new KubeConfig();

const caPath = '/var/run/secrets/kubernetes.io/serviceaccount/ca.crt';
if (fs.existsSync(caPath)) {
  kubeConfig.loadFromCluster();
} else {
  const kubeconfigPath = path.join(os.homedir(), '.kube', 'config');
  console.warn(`Loading kubeconfig from ${kubeconfigPath}`);
  kubeConfig.loadFromFile(kubeconfigPath);
}

interface SharedClientOptions {
  host?: string;
  sslCaCert?: string;
  verifySsl?: boolean;
}

/**
 * Loads the Kubernetes config and sets global overrides.
 * This should be called before creating any shared clients.
 */
export function loadConfig(options: SharedClientOptions = {}): KubeConfig {
  const kc = new KubeConfig();

  if (options.host) {
    const cluster: Cluster = {
      name: 'custom',
      server: options.host,
      skipTLSVerify: options.verifySsl === false,
      caFile: options.sslCaCert,
    };

    kc.loadFromOptions({
      clusters: [cluster],
      users: [],
      contexts: [
        {
          name: 'custom',
          cluster: 'custom',
          user: '',
        },
      ],
      currentContext: 'custom',
    });
  } else {
    kc.loadFromDefault();
  }

  return kc;
}

/**
 * Returns a shared client instance of the specified API class.
 * Ensures only one client per API type / args combo.
 */
export function sharedClient<T extends ApiType>(
  ClientClass: new (...args: any[]) => T
): T {
  const key = ClientClass.name;

  if (!clientCache.has(key)) {
    const client = kubeConfig.makeApiClient(ClientClass);
    clientCache.set(key, client);
  }

  return clientCache.get(key);
}
