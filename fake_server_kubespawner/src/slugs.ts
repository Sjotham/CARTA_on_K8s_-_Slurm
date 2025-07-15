// Tools for generating slugs like Kubernetes object names and labels

import crypto from 'crypto';

const alphanum = [...'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'];
const alphaLower = [...'abcdefghijklmnopqrstuvwxyz'];
const alphanumLower = [...'abcdefghijklmnopqrstuvwxyz0123456789'];
const lowerPlusHyphen = [...alphanumLower, '-'];

const objectPattern = /^[a-z0-9\-]+$/;
const labelPattern = /^[a-z0-9.\-_]+$/i;
const nonAlphanumPattern = /[^a-z0-9]+/g;
const hashLength = 8;

const escapeSlugSafeChars = new Set('abcdefghijklmnopqrstuvwxyz0123456789');

export function escapeSlug(name: string): string {
  return name
    .toLowerCase()
    .split('')
    .map((ch) => (escapeSlugSafeChars.has(ch) ? ch : '-'))
    .join('');
}

function isValidGeneral(
  s: string,
  opts: {
    startsWith?: string[];
    endsWith?: string[];
    pattern?: RegExp;
    minLength?: number;
    maxLength?: number;
  }
): boolean {
  if (opts.minLength && s.length < opts.minLength) return false;
  if (opts.maxLength && s.length > opts.maxLength) return false;
  if (opts.startsWith && !opts.startsWith.some((ch) => s.startsWith(ch))) return false;
  if (opts.endsWith && !opts.endsWith.some((ch) => s.endsWith(ch))) return false;
  if (opts.pattern && !opts.pattern.test(s)) return false;
  return true;
}

export function isValidObjectName(s: string): boolean {
  return isValidGeneral(s, {
    startsWith: alphaLower,
    endsWith: alphanumLower,
    pattern: objectPattern,
    maxLength: 63,
    minLength: 1,
  });
}

export function isValidLabel(s: string): boolean {
  if (!s) return true;
  return isValidGeneral(s, {
    startsWith: alphanum,
    endsWith: alphanum,
    pattern: labelPattern,
    maxLength: 63,
  });
}

export function isValidDefault(s: string): boolean {
  return isValidObjectName(s);
}

function extractSafeName(name: string, maxLength: number): string {
  let safe = name.toLowerCase().replace(nonAlphanumPattern, '-');
  safe = safe.replace(/^-+/, '').slice(0, maxLength).replace(/-+$/, '');
  if (safe && !alphaLower.some((c) => safe.startsWith(c))) {
    safe = 'x-' + safe.slice(0, maxLength - 2);
  }
  if (!safe) safe = 'x';
  return safe;
}

export function stripAndHash(name: string, maxLength = 32): string {
  const nameLength = maxLength - (hashLength + 3);
  if (nameLength < 1) {
    throw new Error(`Cannot make safe names shorter than ${hashLength + 4}`);
  }
  const hash = crypto.createHash('sha256').update(name, 'utf8').digest('hex').slice(0, hashLength);
  const safe = extractSafeName(name, nameLength);
  return `${safe}---${hash}`;
}

export function safeSlug(
  name: string,
  isValid: (s: string) => boolean = isValidDefault,
  maxLength?: number
): string {
  if (name.includes('--')) return stripAndHash(name, maxLength ?? 32);
  if (isValid(name) && (maxLength === undefined || name.length <= maxLength)) {
    return name;
  }
  return stripAndHash(name, maxLength ?? 32);
}

export function multiSlug(names: string[], maxLength = 48): string {
  const hasher = crypto.createHash('sha256');
  hasher.update(Buffer.from(names[0], 'utf8'));
  for (const name of names.slice(1)) {
    hasher.update(Buffer.from([0xff]));
    hasher.update(Buffer.from(name, 'utf8'));
  }
  const hash = hasher.digest('hex').slice(0, hashLength);
  const available = maxLength - (hashLength + 1);
  const perName = Math.floor(available / names.length);
  const nameMax = perName - 2;
  if (nameMax < 2) throw new Error(`Not enough characters for ${names.length} names: ${maxLength}`);

  const slugs = names.map((name) => extractSafeName(name, nameMax));
  return `${slugs.join('--')}---${hash}`;
}
