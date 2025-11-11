This repository contains two deployments systems on deploying interactive applications, using the Cube Analysis and Rendering Tool for Astronomy (CARTA) as the use case. We compare the use of Kubernetes as an orchestration framework and Slurm as a resource manager in HPC environment. The objective is to find the best deployment system for interactive applications. For each deployment method we going to list the scripts that needs to be executed.

Deploment method
* Kubernetes Deployment (K8s_deployment) deploys on a Kubernetes cluster.
--firsttime_install.sh this script install docker engine for minikube, minikube and kubectl to manage K8s deployments
--CephFS.sh script Install Rook to deploy a Ceph distributed file system on a Minikube Kubernetes cluster
--Storage.yaml && filesystem.yaml should be deployed after CephFS.sh as it works with the ceph file system
--kubernetes_run.sh script uses three scripts: carta-backend.yaml, carta-b.yaml and carta-c.yaml which deploys carta-backend on different namespaces but each YAML file can be deployed indidually and it should work.
* SLURM deployment (Slurm is a resource manager for HPC environment)
--Two scripts that works to install slurm in a cluster, one install slurm on the login node and slurm on compute nodes.
** we still working on the deployment of CARTA on the Slurm cluster
* Local deployment 
--installing_carta.sh install carta on a local computer which has the frontend, controller and carta-backend.


