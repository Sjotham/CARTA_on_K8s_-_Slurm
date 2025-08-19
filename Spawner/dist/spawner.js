"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.KubeSpawner = void 0;
const client_node_1 = require("@kubernetes/client-node");
class KubeSpawner {
    constructor(options) {
        this.user = options.user;
        this.namespace = options.namespace || 'default';
        this.image = options.image || 'jupyter/base-notebook:latest';
        this.cpuLimit = options.cpuLimit || '500m';
        this.memoryLimit = options.memoryLimit || '1Gi';
        this.workingDir = options.workingDir || '/home/jovyan';
        this.command = options.command || ['start-notebook.sh'];
        this.args = options.args || [];
        this.env = options.env || {};
        this.hubUrl = options.hubUrl;
        this.apiToken = options.apiToken;
        this.userOptions = options.userOptions || {};
        const kubeConfig = new client_node_1.KubeConfig();
        kubeConfig.loadFromDefault();
        this.kubeApi = kubeConfig.makeApiClient(client_node_1.CoreV1Api);
    }
    generatePodName() {
        return `jupyter-${this.user.name}`;
    }
    async start() {
        const podName = this.generatePodName();
        const podManifest = {
            metadata: {
                name: podName,
                labels: {
                    app: 'jupyterhub',
                    user: this.user.name,
                },
            },
            spec: {
                containers: [
                    {
                        name: 'notebook',
                        image: this.image,
                        command: this.command,
                        args: this.args,
                        workingDir: this.workingDir,
                        resources: {
                            limits: {
                                cpu: this.cpuLimit,
                                memory: this.memoryLimit,
                            },
                        },
                        env: Object.entries(this.env).map(([name, value]) => ({ name, value })),
                    },
                ],
                restartPolicy: 'Never',
            },
        };
        try {
            const response = await this.kubeApi.createNamespacedPod({
                namespace: this.namespace,
                body: podManifest,
            });
            return response.body;
        }
        catch (error) {
            throw new Error(`Failed to create pod: ${error}`);
        }
    }
    async stop() {
        const podName = this.generatePodName();
        try {
            await this.kubeApi.deleteNamespacedPod({ name: podName, namespace: this.namespace });
        }
        catch (error) {
            throw new Error(`Failed to delete pod: ${error}`);
        }
    }
    async getStatus() {
        const podName = this.generatePodName();
        try {
            const response = await this.kubeApi.readNamespacedPodStatus({ name: podName, namespace: this.namespace });
            return response.body.status?.phase || 'Unknown';
        }
        catch (error) {
            throw new Error(`Failed to get pod status: ${error}`);
        }
    }
}
exports.KubeSpawner = KubeSpawner;
