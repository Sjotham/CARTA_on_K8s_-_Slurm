// src/objects.ts
import * as k8s from '@kubernetes/client-node';
import { readFileSync } from 'fs';
import {
  V1Namespace,
  V1ObjectMeta,
  V1OwnerReference,
  V1PersistentVolumeClaim,
  V1Pod,
  V1Service,
  V1Secret, // ✅ add this
} from '@kubernetes/client-node';


export function makePod(
  name: string,
  cmd: string[],
  port: number,
  image: string,
  args: string[],
  env: Record<string, string>,
  imagePullPolicy?: string,
  imagePullSecrets?: (string | k8s.V1LocalObjectReference)[],
  nodeSelector?: Record<string, string>,
  uid?: number,
  gid?: number,
  fsGid?: number,
  supplementalGids?: number[],
  privileged = false,
  allowPrivilegeEscalation?: boolean,
  containerSecurityContext?: k8s.V1SecurityContext,
  podSecurityContext?: k8s.V1PodSecurityContext,
  workingDir?: string,
  volumes?: k8s.V1Volume[],
  volumeMounts?: k8s.V1VolumeMount[],
  labels?: Record<string, string>,
  annotations?: Record<string, string>,
  cpuLimit?: string,
  cpuGuarantee?: string,
  memLimit?: string,
  memGuarantee?: string,
  extraResourceLimits?: Record<string, string>,
  extraResourceGuarantees?: Record<string, string>,
  lifecycleHooks?: k8s.V1Lifecycle,
  initContainers?: k8s.V1Container[],
  serviceAccount?: string,
  automountServiceAccountToken?: boolean,
  extraContainerConfig?: Partial<k8s.V1Container>,
  extraPodConfig?: Partial<k8s.V1PodSpec>,
  extraContainers?: k8s.V1Container[],
  schedulerName?: string,
  tolerations?: k8s.V1Toleration[],
  nodeAffinityPreferred?: k8s.V1PreferredSchedulingTerm[],
  nodeAffinityRequired?: k8s.V1NodeSelectorTerm[],
  podAffinityPreferred?: k8s.V1WeightedPodAffinityTerm[],
  podAffinityRequired?: k8s.V1PodAffinityTerm[],
  podAntiAffinityPreferred?: k8s.V1WeightedPodAffinityTerm[],
  podAntiAffinityRequired?: k8s.V1PodAffinityTerm[],
  priorityClassName?: string
): k8s.V1Pod {
  const envVars: k8s.V1EnvVar[] = env
    ? Object.entries(env).map(([name, value]) => ({ name, value }))
    : [];

  const limits: Record<string, string> = { ...extraResourceLimits };
  if (cpuLimit !== undefined) limits.cpu = cpuLimit;
  if (memLimit !== undefined) limits.memory = memLimit;

  const requests: Record<string, string> = { ...extraResourceGuarantees };
  if (cpuGuarantee !== undefined) requests.cpu = cpuGuarantee;
  if (memGuarantee !== undefined) requests.memory = memGuarantee;

  const container: k8s.V1Container = {
    name: 'notebook',
    image,
    command: cmd,
    workingDir,
    ports: [{ containerPort: port, name: 'notebook-port' }],
    env: envVars,
    imagePullPolicy,
    lifecycle: lifecycleHooks,
    volumeMounts,
    resources: {
      limits,
      requests,
    },
    securityContext: {
      runAsUser: uid,
      runAsGroup: gid,
      privileged,
      allowPrivilegeEscalation,
      ...containerSecurityContext,
    },
    ...extraContainerConfig,
  };

  const podSecurityCtx: k8s.V1PodSecurityContext = {
    fsGroup: fsGid,
    supplementalGroups: supplementalGids,
    ...podSecurityContext,
  };

  const affinity: k8s.V1Affinity = {
    nodeAffinity: nodeAffinityPreferred || nodeAffinityRequired ? {
      preferredDuringSchedulingIgnoredDuringExecution: nodeAffinityPreferred,
      requiredDuringSchedulingIgnoredDuringExecution: nodeAffinityRequired
        ? { nodeSelectorTerms: nodeAffinityRequired }
        : undefined,
    } : undefined,
    podAffinity: podAffinityPreferred || podAffinityRequired ? {
      preferredDuringSchedulingIgnoredDuringExecution: podAffinityPreferred,
      requiredDuringSchedulingIgnoredDuringExecution: podAffinityRequired,
    } : undefined,
    podAntiAffinity: podAntiAffinityPreferred || podAntiAffinityRequired ? {
      preferredDuringSchedulingIgnoredDuringExecution: podAntiAffinityPreferred,
      requiredDuringSchedulingIgnoredDuringExecution: podAntiAffinityRequired,
    } : undefined,
  };

  const podSpec: k8s.V1PodSpec = {
    containers: [container, ...(extraContainers || [])],
    restartPolicy: 'OnFailure',
    volumes,
    nodeSelector,
    initContainers,
    tolerations,
    schedulerName,
    priorityClassName,
    serviceAccountName: serviceAccount,
    automountServiceAccountToken,
    securityContext: podSecurityCtx,
    imagePullSecrets: imagePullSecrets?.map((s) =>
      typeof s === 'string' ? { name: s } : s
    ),
    affinity,
    ...extraPodConfig,
  };

  return {
    apiVersion: 'v1',
    kind: 'Pod',
    metadata: {
      name,
      labels: { app: 'carta', user: name, ...labels },
      annotations,
    },
    spec: podSpec,
  };
}

export function makeService(
  name: string,
  labels: Record<string, string>,
  port = 8888
): V1Service {
  return {
    metadata: { name, labels },
    spec: {
      selector: labels,
      ports: [{ name: 'carta', port, targetPort: port }],
    },
  };
}

export function makePVC(
  name: string,
  storage: string,
  storageClass?: string,
  accessModes: string[] = ['ReadWriteOnce'],
  selector?: k8s.V1LabelSelector,
  labels?: Record<string, string>,
  annotations?: Record<string, string>
): k8s.V1PersistentVolumeClaim {
  const pvc: k8s.V1PersistentVolumeClaim = {
    apiVersion: 'v1',
    kind: 'PersistentVolumeClaim',
    metadata: {
      name,
      labels,
      annotations: {
        ...(annotations || {}),
        ...(storageClass ? { 'volume.beta.kubernetes.io/storage-class': storageClass } : {}),
      },
    },
    spec: {
      accessModes,
      resources: {
        requests: {
          storage,
        },
      },
      storageClassName: storageClass,
      selector,
    },
  };
  return pvc;
}

export function makeNamespace(name: string): k8s.V1Namespace {
  return {
    apiVersion: 'v1',
    kind: 'Namespace',
    metadata: {
      name,
    },
  };
}

export function makeSecretFromFiles(
  name: string,
  certPaths: { keyfile: string; certfile: string; cafile: string },
  hubCaPath: string,
  ownerReferences: k8s.V1OwnerReference[],
  labels?: Record<string, string>,
  annotations?: Record<string, string>
): k8s.V1Secret {
  const secret: k8s.V1Secret = {
    apiVersion: 'v1',
    kind: 'Secret',
    metadata: {
      name,
      labels,
      annotations,
      ownerReferences,
    },
    type: 'Opaque',
    data: {
      'ssl.key': Buffer.from(readFileSync(certPaths.keyfile, 'utf-8')).toString('base64'),
      'ssl.crt': Buffer.from(readFileSync(certPaths.certfile, 'utf-8')).toString('base64'),
      'notebooks-ca_trust.crt': Buffer.from(
        readFileSync(certPaths.cafile, 'utf-8').trim() + '\n' + readFileSync(hubCaPath, 'utf-8')
      ).toString('base64'),
    },
  };
  return secret;
}

export function makeOwnerReference(name: string, uid: string): k8s.V1OwnerReference {
  return {
    apiVersion: 'v1',
    kind: 'Pod',
    name,
    uid,
    blockOwnerDeletion: true,
    controller: false,
  };
}
/** Create a Kubernetes Secret (placeholder for extensibility) */
export function makeSecret(name: string, data: Record<string, string>): V1Secret {
  return {
    metadata: { name },
    data,
    type: 'Opaque',
  };
}


export function makeIngress(
  name: string,
  host: string,
  targetIP: string,
  annotations: Record<string, string>,
  namespace: string,
  servicePort = 8888,
  labels?: Record<string, string>,
  enableTLS = false,
  tlsSecretName?: string
): [k8s.V1Endpoints, k8s.V1Service, k8s.V1Ingress] {
  const endpoint: k8s.V1Endpoints = {
    metadata: {
      name,
      namespace,
      labels,
    },
    subsets: [
      {
        addresses: [{ ip: targetIP }],
        ports: [{ port: servicePort }],
      },
    ],
  };

  const service: k8s.V1Service = {
    metadata: {
      name,
      namespace,
      labels,
    },
    spec: {
      type: 'ClusterIP',
      ports: [
        {
          port: servicePort,
          targetPort: servicePort,
        },
      ],
      selector: labels,
    },
  };

  const ingressSpec: k8s.V1IngressSpec = {
    rules: [
      {
        host,
        http: {
          paths: [
            {
              path: '/',
              pathType: 'Prefix',
              backend: {
                service: {
                  name,
                  port: {
                    number: servicePort,
                  },
                },
              },
            },
          ],
        },
      },
    ],
  };

  if (enableTLS) {
    ingressSpec.tls = [
      {
        hosts: [host],
        secretName: tlsSecretName || `${name}-tls`,
      },
    ];
  }

  const ingress: k8s.V1Ingress = {
    metadata: {
      name,
      namespace,
      labels,
      annotations,
    },
    spec: ingressSpec,
  };

  return [endpoint, service, ingress];
}
