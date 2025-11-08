// spawner.ts
export type StartOptions = {
  forceRestart?: boolean;
  extraArgs?: string[];
  metadata?: Record<string, string>;
};

export type ProxyTarget = {
  host: string;
  port: number;
  path?: string;
  headers?: Record<string, string>;
};

export type SpawnStatus =
  | { running: false; ready: false; }
  | { running: true; ready: boolean; target?: ProxyTarget };

export type SpawnResult = {
  success: boolean;
  existing?: boolean;
  status: SpawnStatus;
  proxyHeaders?: Record<string, string>;
  info?: Record<string, string | number | boolean>;
};

export interface Spawner {
  start(username: string, opts?: StartOptions): Promise<SpawnResult>;
  stop(username: string): Promise<{ success: boolean }>;
  status(username: string): Promise<SpawnStatus>;
  logs(username: string, tail?: number): Promise<{ success: boolean; log?: string }>;
  getProxyTarget(username: string): Promise<{ success: boolean; target?: ProxyTarget }>;
}
