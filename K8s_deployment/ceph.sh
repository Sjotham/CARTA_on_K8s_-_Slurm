# Starting minikube 
minikube start \
  -p cluster-multi \
  --driver=docker \
  --nodes=3 \
  --cpus=4 \
  --memory=4096
# install kubectl 
curl -LO "https://dl.k8s.io/release/v1.26.1/bin/darwin/arm64/kubectl"
chmod +x kubectl
sudo mv kubectl /usr/local/bin/
# ssh to minikube and create directory
minikube ssh
sudo mkdir /mnt/disks
# Create an empty file of size 10GB to mount disk as ceph osd
sudo dd if=/dev/zero of=/mnt/disks/mydisk.img bs=1M count=10240
sudo apt update
sudo apt upgrade
sudo apt-get install qemu-utils

# List the nbd devices
lsblk | grep nbd
# If you are unable to see the nbd device, load the NBD (Network Block Device) kernel module.
sudo modprobe nbd max_part=8
# To bind nbd device to the file
# Note: Please check there is no necessary data in /dev/nbdx, otherwise back up that data
sudo qemu-nbd --format raw -c /dev/nbd0 /mnt/disks/mydisk.img
# Verify the size of the nbd device by using lsblk
lsblk | grep nbd0
# Clone the Rook repository to your host machine.
git clone https://github.com/rook/rook.git
cd rook/deploy/examples/

kubectl create -f crds.yaml -f common.yaml -f operator.yaml -f csi-operator.yaml
# Verify that the rook-ceph-operator is in a running state before proceeding.
kubectl get pods -n rook-ceph
kubectl create -f cluster-test.yaml
kubectl -n rook-ceph get pod

kubectl create -f toolbox.yaml
kubectl -n rook-ceph rollout status deploy/rook-ceph-tools
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- bash
ceph status

