// General utility functions not tied directly to the Spawner

import crypto from 'crypto';

export function generateHashedSlug(slug: string, limit = 63, hashLength = 6): string {
  if (slug.length < (limit - hashLength)) {
    return slug;
  }
  const hash = crypto.createHash('sha256').update(slug, 'utf8').digest('hex');
  return `${slug.slice(0, limit - hashLength - 1)}-${hash.slice(0, hashLength)}`.toLowerCase();
}

export function updateK8sModel<T extends { [key: string]: any; attribute_map: Record<string, string> }>(
  target: T,
  changes: Partial<T> | Record<string, any>,
  logger?: { info: (msg: string) => void },
  targetName?: string,
  changesName?: string
): T {
  const modelType = target.constructor as new (...args: any[]) => T;

  if (!('attribute_map' in target)) {
    throw new Error(`Target object must have 'attribute_map'.`);
  }

  const changesDict = getK8sModelDict(modelType, changes);

  for (const [key, value] of Object.entries(changesDict)) {
    if (!(key in target.attribute_map)) {
      throw new Error(`Changes object contains unknown attribute '${key}'.`);
    }

    if (typeof changes === 'object' && (value || typeof changes === 'object')) {
      if (target[key]) {
        if (logger && changesName && targetName) {
          logger.info(`'${targetName}.${key}' current value: '${target[key]}' is overridden with '${value}', from '${changesName}.${key}'.`);
        }
      }
      (target as Record<string, any>)[key] = value;

    }
  }

  return target;
}


export function getK8sModel<T>(modelType: new (...args: any[]) => T, modelDict: T | Record<string, any>): T {
  const cloned = JSON.parse(JSON.stringify(modelDict));

  if (cloned instanceof modelType) {
    return cloned;
  } else if (typeof cloned === 'object') {
    const formatted = mapDictKeysToModelAttributes(modelType, cloned);
    return new modelType(formatted);
  } else {
    throw new Error(`Expected object of type '${modelType.name}' or plain object, but got ${typeof cloned}`);
  }
}

function getK8sModelDict<T>(
  modelType: new (...args: any[]) => T,
  model: T | Record<string, any>
): Record<string, any> {
  const cloned = JSON.parse(JSON.stringify(model));

  if (model instanceof modelType) {
    return (model as any).toJSON?.() ?? cloned;
  } else if (typeof model === 'object') {
    return mapDictKeysToModelAttributes(modelType, cloned);
  } else {
    throw new Error(`Expected model type '${modelType.name}' or plain object`);
  }
}


function mapDictKeysToModelAttributes(modelType: any, modelDict: Record<string, any>): Record<string, any> {
  const newDict: Record<string, any> = {};
  for (const [key, value] of Object.entries(modelDict)) {
    newDict[getK8sModelAttribute(modelType, key)] = value;
  }
  return newDict;
}

function getK8sModelAttribute(modelType: any, fieldName: string): string {
  if (fieldName in modelType.attribute_map) {
    return fieldName;
  }
  for (const [key, val] of Object.entries(modelType.attribute_map)) {
    if (val === fieldName) {
      return key;
    }
  }
  throw new Error(`No attribute mapping found in '${modelType.name}' for field '${fieldName}'`);
}

export function hostMatching(host: string, wildcard: string): boolean {
  if (!wildcard.startsWith('*.')) return host === wildcard;

  const hostParts = host.split('.');
  const wildcardParts = wildcard.split('.');
  return hostParts.slice(1).join('.') === wildcardParts.slice(1).join('.');
}

export function recursiveUpdate(target: Record<string, any>, incoming: Record<string, any>): void {
  for (const [key, value] of Object.entries(incoming)) {
    if (value === null) {
      delete target[key];
    } else if (typeof value === 'object' && value !== null && !Array.isArray(value)) {
      if (!(key in target)) {
        target[key] = {};
      }
      recursiveUpdate(target[key], value);
    } else {
      target[key] = value;
    }
  }
}

class IgnoreMissing extends Map<string, any> {
  get(key: string): any {
    return super.has(key) ? super.get(key) : `{${key}}`;
  }
}

export function recursiveFormat(obj: any, values: Record<string, any>): any {
  if (typeof obj === 'string') {
    return obj.replace(/{([^{}]+)}/g, (_, k) => (k in values ? values[k] : `{${k}}`));
  } else if (Array.isArray(obj)) {
    return obj.map((item) => recursiveFormat(item, values));
  } else if (obj instanceof Set) {
    return new Set(Array.from(obj).map((item) => recursiveFormat(item, values)));
  } else if (typeof obj === 'object' && obj !== null) {
    const result: Record<string, any> = {};
    for (const [k, v] of Object.entries(obj)) {
      result[recursiveFormat(k, values)] = recursiveFormat(v, values);
    }
    return result;
  } else {
    return obj;
  }
}
