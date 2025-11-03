// serverHandlers.ts
import type { IncomingMessage } from "node:http";
import type { Socket } from "node:net";
import * as url from "node:url";
import * as querystring from "node:querystring";
import express, { type NextFunction, type Response } from "express";
import type Server from "http-proxy";
import io from "@pm2/io";

import { authGuard, getUser, verifyToken } from "./auth";
import { ServerConfig } from "./config";
import { logger, noCache, delay } from "./util";

import type { Spawner} from "./spawner/spawner";
import type { LocalSpawner } from "./spawner/local-spawner";
import type { K8sSpawner } from "./spawner/k8s-spawner"; 

// -------------------- Spawner wiring --------------------

// Choose which spawner to use. You can switch this with a config flag.
const spawner: Spawner = ServerConfig.backendMode === "k8s"
  ? new K8sSpawner({
      kubeconfigPath: ServerConfig.kubeconfigPath, // mount your kubeconfig secret to this path
      startDelayMs: ServerConfig.startDelay,
      localPortRange: ServerConfig.backendPorts,   // reuse same shape {min,max}
      logger,
      delay,
    })
  : new LocalSpawner({
      backendPorts: ServerConfig.backendPorts,
      processCommand: ServerConfig.processCommand,
      preserveEnv: ServerConfig.preserveEnv,
      additionalArgs: ServerConfig.additionalArgs,
      baseFolderTemplate: ServerConfig.baseFolderTemplate,
      rootFolderTemplate: ServerConfig.rootFolderTemplate,
      backendLogFileTemplate: ServerConfig.backendLogFileTemplate,
      startDelayMs: ServerConfig.startDelay,
      killCommand: ServerConfig.killCommand,
      logger,
      delay,
    });

// Optional PM2 metric (tracks “known running” users via /status calls)
const userProcessesMetric = io.metric({
  name: "Active Backend Processes",
  id: "app/realtime/backend",
});
async function refreshMetric(username?: string) {
  try {
    // This is a cheap metric heuristic: in a real setup you might track a set of users seen “running”
    let count = 0;
    if (username) {
      const st = await spawner.status(username);
      if (st.running) count = 1; // single-user metric bump
    }
    userProcessesMetric.set(count);
  } catch { /* ignore metric errors */ }
}

// -------------------- HTTP handlers --------------------

async function handleCheckServer(req: any, res: Response) {
  const username = req.username as string | undefined;
  if (!username) {
    return res.status(403).json({ success: false, message: "Invalid username" });
  }
  const st = await spawner.status(username);
  await refreshMetric(username);
  return res.json({ success: true, running: st.running, ready: st.running && st.ready });
}

async function handleLog(req: any, res: Response) {
  const username = req.username as string | undefined;
  if (!username) {
    return res.status(403).json({ success: false, message: "Invalid username" });
  }
  const tail = Number(req.query?.tail ?? NaN);
  const out = await spawner.logs(username, Number.isFinite(tail) ? tail : undefined);
  return res.json(out);
}

async function handleStartServer(req: any, res: Response, next: NextFunction) {
  try {
    const username = req.username as string | undefined;
    if (!username) return next({ statusCode: 403, message: "Invalid username" });

    const forceRestart = !!req.body?.forceRestart;
    const result = await spawner.start(username, { forceRestart });

    await refreshMetric(username);
    return res.json({
      success: result.success,
      existing: !!result.existing,
      running: result.status.running,
      ready: result.status.running && result.status.ready,
      info: result.info,
    });
  } catch (e) {
    logger.error(`start error: ${String(e)}`);
    return next({ statusCode: 500, message: "Problem starting backend" });
  }
}

async function handleStopServer(req: any, res: Response, next: NextFunction) {
  try {
    const username = req.username as string | undefined;
    if (!username) return next({ statusCode: 403, message: "Invalid username" });

    const out = await spawner.stop(username);
    await refreshMetric(username);
    return res.json(out);
  } catch (e) {
    logger.error(`stop error: ${String(e)}`);
    return next({ statusCode: 500, message: "Problem stopping backend" });
  }
}

// -------------------- Proxy helpers --------------------

/**
 * WebSocket upgrade handler: validates token, ensures backend is up,
 * fetches proxy target (host/port/headers), and forwards the socket.
 */
export const createUpgradeHandler =
  (proxy: Server) =>
  async (req: IncomingMessage, socket: Socket, head: Buffer) => {
    try {
      if (!req?.url) return socket.end();

      const parsed = url.parse(req.url);
      if (!parsed?.query) {
        logger.warn(`WS upgrade has no query: ${req.url}`);
        return socket.end();
      }

      const qs = querystring.parse(parsed.query);
      const tokenString = qs?.token;
      if (!tokenString || Array.isArray(tokenString)) {
        logger.warn(`WS upgrade missing token`);
        return socket.end();
      }

      const token = await verifyToken(tokenString);
      if (!token?.username) {
        logger.warn(`WS upgrade invalid token`);
        return socket.end();
      }

      const username = getUser(token.username, `${token.iss}`);
      if (!username) {
        logger.error(`WS upgrade unknown user ${token.username}`);
        return socket.end();
      }

      // Ensure a backend exists, then retrieve a proxy target
      const startResult = await spawner.start(username);
      if (!startResult.success) {
        logger.error(`WS: backend could not be started for ${username}`);
        return socket.end();
      }

      // Wait briefly if not ready yet (optional; many spawners already wait)
      if (!startResult.status.ready) await delay(ServerConfig.startDelay);

      const proxyInfo = await spawner.getProxyTarget(username);
      if (!proxyInfo.success || !proxyInfo.target) {
        logger.error(`WS: no proxy target for ${username}`);
        return socket.end();
      }

      const { host, port, headers } = proxyInfo.target;
      logger.info(`WS proxy -> ${host}:${port} for ${username}`);

      // Inject auth header while proxying
      (req as any).headers = { ...(req as any).headers, ...(headers ?? {}) };
      (req as any).url = "/";

      return proxy.ws(req, socket, head, {
        target: { host, port },
        headers, // http-proxy supports extra headers on upgrade
      });
    } catch (err) {
      logger.error(`Error upgrading socket: ${String(err)}`);
      return socket.end();
    }
  };

/**
 * HTTP scripting proxy: validates auth on req (authGuard sets req.username & req.scripting),
 * ensures backend is up, and proxies HTTP to the user target with injected headers.
 */
export const createScriptingProxyHandler =
  (proxy: Server) =>
  async (req: any, res: Response, next: NextFunction) => {
    const username = req?.username as string | undefined;
    if (!username) return next({ statusCode: 401, message: "Not authorized" });
    if (!req?.scripting) {
      return next({ statusCode: 403, message: "API token supplied does not permit scripting" });
    }

    try {
      const startResult = await spawner.start(username);
      if (!startResult.success) {
        return next({ statusCode: 500, message: `Backend could not be started for ${username}` });
      }

      if (!startResult.status.ready) await delay(ServerConfig.startDelay);

      const proxyInfo = await spawner.getProxyTarget(username);
      if (!proxyInfo.success || !proxyInfo.target) {
        return next({ statusCode: 500, message: `No proxy target for ${username}` });
      }

      const { host, port, headers } = proxyInfo.target;
      logger.info(`Scripting proxy -> ${host}:${port} for ${username}`);

      // Inject auth header as we forward
      req.headers = { ...req.headers, ...(headers ?? {}) };

      return proxy.web(req, res, {
        target: { host, port },
        headers, // pass-through as well
      });
    } catch (err) {
      logger.error(`Error proxying scripting request for ${username}: ${String(err)}`);
      return next({ statusCode: 500, message: `Error proxying scripting request for ${username}` });
    }
  };

// -------------------- Router --------------------

export const serverRouter = express.Router();
serverRouter.post("/start", authGuard, noCache, handleStartServer);
serverRouter.post("/stop", authGuard, noCache, handleStopServer);
serverRouter.get("/status", authGuard, noCache, handleCheckServer);
serverRouter.get("/log", authGuard, noCache, handleLog);
