import express, { Request, Response } from 'express';
import bodyParser from 'body-parser';
import { KubeSpawner } from './spawner.ts'; // ✅ ESM-compliant
import { V1Pod } from '@kubernetes/client-node';

const app = express();
const port = 8000;

app.use(bodyParser.json());

// 🔄 Spawner registry: one per user
const spawnerRegistry: Map<string, KubeSpawner> = new Map();

class MockHub {
  public public_host = 'http://127.0.0.1:8000';
  public url = 'http://127.0.0.1:8000';
  public base_url = '/hub/';
  public api_url = 'http://127.0.0.1:8000/hub/api';
}

class MockUser {
  public name: string;
  public id: string;
  public spawner: any;
  public url: string;

  constructor(name: string) {
    this.name = name;
    this.id = name;
    this.spawner = null;
    this.url = `/user/${name}`;
  }

  toString() {
    return this.name;
  }
}

interface JSONRPCRequest {
  jsonrpc: string;
  method: string;
  params?: any[];
  id?: number | string;
}

// 🔧 Helper: get or create a spawner for a user
function getOrCreateSpawner(username: string, namespace: string): KubeSpawner {
  if (spawnerRegistry.has(username)) {
    return spawnerRegistry.get(username)!;
  }

  const user = new MockUser(username);
 const spawner = new KubeSpawner({
  user,
  namespace,
  hubUrl: 'http://127.0.0.1:8081',
  apiToken: 'dummy-token',
  userOptions: {},
  command: ['start-notebook.sh'], // ✅ required field
});


  user.spawner = spawner;
  spawnerRegistry.set(username, spawner);
  return spawner;
}

// 🧠 Main JSON-RPC handler
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
  console.log(`JSON-RPC Server is running on http://127.0.0.1:${port}`);
});