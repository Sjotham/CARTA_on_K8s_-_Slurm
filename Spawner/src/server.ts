import express, { Request, Response } from 'express';
import bodyParser from 'body-parser';
import { KubeSpawner } from "./kubeSpawner";  // ✅ Use .js for ESM runtime
import { V1Pod } from '@kubernetes/client-node';

const app = express();
const port = 8000;

app.use(bodyParser.json());

// ✅ Spawner registry: one per user
const spawnerRegistry: Map<string, KubeSpawner> = new Map();

// ✅ Minimal user interface
interface User {
  name: string;
  id: string;
  spawner?: KubeSpawner;
  url?: string;
}

// ✅ JSON-RPC types
interface JSONRPCRequest {
  jsonrpc: string;
  method: string;
  params?: any[];
  id?: number | string;
}

// ✅ Create or retrieve a spawner
function getOrCreateSpawner(username: string, namespace: string = 'default'): KubeSpawner {
  if (spawnerRegistry.has(username)) {
    return spawnerRegistry.get(username)!;
  }

  const user: User = {
    name: username,
    id: username,
  };

  const kubeSpawner = new KubeSpawner({
    user,
    namespace,
    image: 'cartavis/carta:beta',
    command: ['/usr/bin/carta_backend'],
    args: ['--no_http'],
    env: {
      CARTA_USER: username,
      CARTA_BACKEND_PORT: '3001',
    },
    // hubUrl: 'http://127.0.0.1:8081',
    apiToken: 'dummy-token',
    userOptions: {},
  });

  user.spawner = kubeSpawner;
  spawnerRegistry.set(username, kubeSpawner);
  return kubeSpawner;
}

// ✅ JSON-RPC handler
app.post('/', async (req: Request, res: Response) => {
  const { method, params = [], id }: JSONRPCRequest = req.body;

  try {
    const username = params[0];
    const namespace = params[1] || 'default';
    const spawner = getOrCreateSpawner(username, namespace);

    let result;
    switch (method) {
      case 'create_k8s_pod':
        await spawner.start();
        result = { message: `Pod for user ${username} started successfully.` };
        break;
      case 'stop_k8s_pod':
        await spawner.stop();
        result = { message: `Pod for user ${username} stopped successfully.` };
        break;
      case 'status_k8s_pod':
        const status = await spawner.getStatus();
        result = { username, status };
        break;
      default:
        throw new Error(`Method ${method} not found`);
    }

    res.json({
      jsonrpc: '2.0',
      result,
      id,
    });
  } catch (error: any) {
    console.error(error);
    res.json({
      jsonrpc: '2.0',
      error: { code: -32601, message: error.message },
      id,
    });
  }
});

app.listen(port, () => {
  console.log(`✅ JSON-RPC Server is running on http://127.0.0.1:${port}`);
}).on('error', (err) => {
  console.error('❌ Server failed to start:', err);
});
