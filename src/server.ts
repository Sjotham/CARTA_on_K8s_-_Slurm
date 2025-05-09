import express, { Request, Response } from 'express';
import bodyParser from 'body-parser';
import { KubeSpawner } from './spawner.ts'; // ✅ ESM-compliant

import { V1Pod } from '@kubernetes/client-node';

const app = express();
const port = 8000;

app.use(bodyParser.json());

class MockHub {
  public public_host = 'http://127.0.0.1:8081';
  public url = 'http://127.0.0.1:8081';
  public base_url = '/hub/';
  public api_url = 'http://127.0.0.1:8081/hub/api';
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

app.post('/', async (req: Request, res: Response) => {
  const { method, params = [], id }: JSONRPCRequest = req.body;

  try {
    let result;
    if (method === 'create_k8s_pod') {
      result = await createK8sPod(params[0], params[1] || 'default');
    } else {
      throw new Error(`Method ${method} not found`);
    }

    res.json({
      jsonrpc: '2.0',
      result,
      id,
    });
  } catch (error: any) {
    res.json({
      jsonrpc: '2.0',
      error: { code: -32601, message: error.message },
      id,
    });
  }
});

async function createK8sPod(username: string, namespace = 'default') {
  const user = new MockUser(username);
  const spawner = new KubeSpawner({
    user,
    hubUrl: 'http://127.0.0.1:8081',
    namespace,
  });

  spawner.apiToken = 'dummy-token';
  spawner.userOptions = {};
  user.spawner = spawner;

  const pod = await spawner.start();
  return { message: `Pod for user ${username} started successfully in namespace ${namespace}.` };
}

app.listen(port, () => {
  console.log(`JSON-RPC Server is running on http://127.0.0.1:${port}`);
});
