"use strict";
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
const express_1 = __importDefault(require("express"));
const body_parser_1 = __importDefault(require("body-parser"));
const spawner_1 = require("./spawner"); // Your custom spawner logic
const app = (0, express_1.default)();
const port = 8000;
app.use(body_parser_1.default.json());
class MockHub {
    constructor() {
        this.public_host = 'http://127.0.0.1:8081';
        this.url = 'http://127.0.0.1:8081';
        this.base_url = '/hub/';
        this.api_url = 'http://127.0.0.1:8081/hub/api';
    }
}
class MockUser {
    constructor(name) {
        this.name = name;
        this.id = name;
        this.spawner = null;
        this.url = `/user/${name}`;
    }
    toString() {
        return this.name;
    }
}
app.post('/', async (req, res) => {
    const { method, params = [], id } = req.body;
    try {
        let result;
        if (method === 'create_k8s_pod') {
            result = await createK8sPod(params[0], params[1] || 'default');
        }
        else {
            throw new Error(`Method ${method} not found`);
        }
        res.json({
            jsonrpc: '2.0',
            result,
            id,
        });
    }
    catch (error) {
        res.json({
            jsonrpc: '2.0',
            error: { code: -32601, message: error.message },
            id,
        });
    }
});
async function createK8sPod(username, namespace = 'default') {
    const user = new MockUser(username);
    const spawner = new spawner_1.KubeSpawner({
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
