// utils.ts

import * as crypto from 'crypto';
import * as http from 'http';
import * as https from 'https';
import * as net from 'net';
import * as url from 'url';
import { promisify } from 'util';
import * as os from 'os';
import * as process from 'process';
import { URL } from 'url';

/**
 * Cast an environment variable to boolean.
 * Returns default if the variable is unset or empty.
 */
export function boolEnv(key: string, defaultValue = false): boolean {
  const value = process.env[key] || '';
  if (value === '') {
    return defaultValue;
  }
  return !['0', 'false'].includes(value.toLowerCase());
}

/**
 * Get a single random available port.
 */
export function randomPort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.listen(0, () => {
      const address = server.address();
      if (address && typeof address === 'object') {
        const port = address.port;
        server.close(() => resolve(port));
      } else {
        server.close(() => reject(new Error('Failed to get port')));
      }
    });
    server.on('error', reject);
  });
}

/**
 * Render a Date object as an ISO 8601 UTC timestamp.
 */
export function isoformat(date: Date): string {
  return date.toISOString();
}

/**
 * Check if we can connect to an ip:port.
 * Returns true if the connection is successful, false otherwise.
 */
export function canConnect(ip: string, port: number, timeout = 1000): Promise<boolean> {
  return new Promise((resolve) => {
    const socket = new net.Socket();
    const onError = () => {
      socket.destroy();
      resolve(false);
    };
    socket.setTimeout(timeout);
    socket.once('error', onError);
    socket.once('timeout', onError);
    socket.connect(port, ip, () => {
      socket.end();
      resolve(true);
    });
  });
}

/**
 * Exponentially backoff until `passFunc` returns a truthy value.
 * Throws an error if the timeout is exceeded.
 */
export async function exponentialBackoff<T>(
  passFunc: () => Promise<T | false>,
  failMessage: string,
  startWait = 200,
  scaleFactor = 2,
  maxWait = 5000,
  timeout = 10000
): Promise<T> {
  const deadline = Date.now() + timeout;
  let wait = startWait;
  while (Date.now() < deadline) {
    const result = await passFunc();
    if (result) {
      return result;
    }
    await new Promise((res) => setTimeout(res, Math.min(wait, maxWait)));
    wait *= scaleFactor;
  }
  throw new Error(failMessage);
}

/**
 * Wait for any server to show up at ip:port.
 */
export async function waitForServer(ip: string, port: number, timeout = 10000): Promise<void> {
  await exponentialBackoff(
    () => canConnect(ip, port),
    `Server at ${ip}:${port} didn't respond in ${timeout / 1000} seconds`,
    200,
    2,
    5000,
    timeout
  );
}

/**
 * Wait for an HTTP Server to respond at the given URL.
 * Any non-5XX response code will do, even 404.
 */
export async function waitForHttpServer(targetUrl: string, timeout = 10000): Promise<void> {
  const parsedUrl = url.parse(targetUrl);
  const get = parsedUrl.protocol === 'https:' ? https.get : http.get;

  await exponentialBackoff(
    () =>
      new Promise<boolean>((resolve) => {
        const req = get(targetUrl, (res) => {
          res.resume(); // Consume response data to free up memory
          resolve(res.statusCode !== undefined && res.statusCode < 500);
        });
        req.on('error', () => resolve(false));
      }),
    `Server at ${targetUrl} didn't respond in ${timeout / 1000} seconds`,
    200,
    2,
    5000,
    timeout
  );
}

/**
 * Generate a new random token.
 */
export function newToken(): string {
  return crypto.randomUUID().replace(/-/g, '');
}

/**
 * Hash a token and return it as `algorithm:rounds:salt:hash`.
 */
export function hashToken(
  token: string,
  saltLength = 8,
  rounds = 16384,
  algorithm = 'sha512'
): string {
  const salt = crypto.randomBytes(saltLength).toString('hex');
  let hash = crypto.createHash(algorithm).update(salt + token).digest('hex');
  for (let i = 1; i < rounds; i++) {
    hash = crypto.createHash(algorithm).update(hash).digest('hex');
  }
  return `${algorithm}:${rounds}:${salt}:${hash}`;
}

/**
 * Compare a token with a hashed token.
 */
export function compareToken(hashedToken: string, token: string): boolean {
  const [algorithm, roundsStr, salt, hash] = hashedToken.split(':');
  const rounds = parseInt(roundsStr, 10);
  const newHash = hashToken(token, salt.length / 2, rounds, algorithm);
  return crypto.timingSafeEqual(Buffer.from(hashedToken), Buffer.from(newHash));
}

/**
 * Escape a value to be used in URLs, cookies, etc.
 */
export function urlEscapePath(value: string): string {
  return encodeURIComponent(value).replace(/%2F/g, '/');
}

/**
 * Join components of URL into a relative URL.
 */
export function urlPathJoin(...pieces: string[]): string {
  return pieces
    .map((piece, index) => {
      if (index === 0) {
        return piece.replace(/\/+$/, '');
      } else {
        return piece.replace(/^\/+|\/+$/g, '');
      }
    })
    .filter((piece) => piece.length > 0)
    .join('/');
}

/**
 * Return current UTC time.
 */
export function utcNow(): Date {
  return new Date();
}
// -------------------------------
// Recursive Update of Objects
// -------------------------------
export function recursiveUpdate(target: any, newObj: any): void {
    for (const [key, value] of Object.entries(newObj)) {
      if (value && typeof value === 'object' && !Array.isArray(value)) {
        if (!target[key]) {
          target[key] = {};
        }
        recursiveUpdate(target[key], value);
      } else if (value === null) {
        delete target[key];
      } else {
        target[key] = value;
      }
    }
  }
  
  // -------------------------------
  // Format IP for URL use
  // -------------------------------
  export function fmtIpUrl(ip: string): string {
    return ip.includes(':') ? `[${ip}]` : ip;
  }
  
  // -------------------------------
  // Accept Header Parsing
  // -------------------------------
  function parseAcceptHeader(accept: string): Array<[string, number]> {
    if (!accept) return [];
    return accept
      .split(',')
      .map((media) => {
        const [type, ...params] = media.split(';').map(p => p.trim());
        let q = 1.0;
        for (const param of params) {
          const [k, v] = param.split('=');
          if (k === 'q') {
            const parsed = parseFloat(v);
            if (!isNaN(parsed)) q = parsed;
          }
        }
        return [type, q] as [string, number];
      })
      .sort((a, b) => b[1] - a[1]);
  }
  
  export function getAcceptedMimeType(acceptHeader: string, choices?: string[]): string | null {
    const parsed = parseAcceptHeader(acceptHeader);
    for (const [mime] of parsed) {
      if (!choices || choices.includes(mime)) return mime;
    }
    return null;
  }
  
  // -------------------------------
  // Protocol Detection
  // -------------------------------
  export function getBrowserProtocol(requestHeaders: Record<string, string>, requestProtocol: string): string {
    const forwarded = requestHeaders['forwarded'];
    if (forwarded) {
      const parts = forwarded.split(',')[0].split(';');
      for (const part of parts) {
        const [k, v] = part.split('=');
        if (k.trim().toLowerCase() === 'proto') {
          return v.trim().toLowerCase();
        }
      }
    }
    const xProto = requestHeaders['x-scheme'] || requestHeaders['x-forwarded-proto'];
    if (xProto) {
      return xProto.split(',')[0].trim().toLowerCase();
    }
    return requestProtocol;
  }
  