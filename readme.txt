https://multipass.run

https://microk8s.io

https://github.com/oracle-quickstart/oke-airflow/tree/master/userdata/templates

https://github.com/GoogleCloudPlatform/python-docs-samples/tree/main/composer/2022_airflow_summit

sudo apt install virt-manager qemu-kvm libvirt-daemon-system libvirt-daemon virtinst cpu-checker
sudo snap install multipass
sudo snap connect multipass:libvirt
multipass set local.driver=libvirt

sudo snap restart multipass.multipassd

multipass launch -n microk8s-01 -v -c 2 -m 4G -d 10G --cloud-init ~/multipass.yaml 22.04
multipass launch -n microk8s-02 -v -c 2 -m 4G -d 10G --cloud-init ~/multipass.yaml 22.04
multipass launch -n nfs -v -c 2 -m 1G -d 10G --cloud-init ~/multipass.yaml 22.04

multipass shell microk8s-01
multipass shell microk8s-02

ip route get 1 | awk '{print $7;exit}'

cat <<EOF>> /etc/hosts

# K8S cluster nodes
192.168.122.156 microk8s-01
192.168.122.179 microk8s-02
EOF

snap install microk8s --classic --channel=1.26/stable

snap alias microk8s.kubectl kubectl
snap alias microk8s.kubectl k
snap alias microk8s.ctr ctr

microk8s enable helm3
snap alias microk8s.helm3 helm
helm version

microk8s enable rbac
microk8s enable dns
microk8s enable metrics-server
microk8s.enable ingress
microk8s.enable registry

# multipass shell microk8s-01
microk8s add-node

# multipass shell microk8s-02
microk8s join 192.168.122.179:25000/d15bd74a849c87708f473bae67f0fb87/99cee66a0d4c --worker

multipass exec microk8s-01 -- sudo microk8s config > ~/.kube/config

# Bastion
sudo curl -fsSL https://dl.k8s.io/release/v1.26.4/bin/linux/amd64/kubectl -o /usr/local/bin/kubectl
curl -fsSL https://get.helm.sh/helm-v3.8.1-linux-amd64.tar.gz | \
  sudo tar zxvf - -C "/usr/local/bin" linux-amd64/helm --strip-components 1

kubectl get nodes

kubectl label node microk8s-01 node-role.kubernetes.io/control-plane=control-plane
kubectl label node microk8s-02 node-role.kubernetes.io/worker=worker

kubectl taint node microk8s-01 node-role.kubernetes.io/control-plane:NoSchedule

kubectl create deployment httpd --image=httpd --port=80 \
  --dry-run=client -o yaml > httpd.yaml

kubectl apply -f httpd.yaml

kubectl expose deployment httpd --type=NodePort --port=80 --name=httpd \
  --dry-run=client -o yaml > httpd-svc.yaml

kubectl apply -f httpd-svc.yaml

NODE_PORT=$(kubectl describe service httpd | grep ^NodePort | grep -Eo '[0-9]*')
NODE_IP=$(kubectl get pod -l app=httpd -o jsonpath='{.items[0].status.hostIP}')

curl -fsSL $NODE_IP:$NODE_PORT

cat <<EOF> test-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: test-ingress
spec:
  ingressClassName: public
  defaultBackend:
    service:
      name: httpd
      port:
        number: 80
EOF

kubectl apply -f test-ingress.yaml

curl http://localhost
curl https://localhost -k
curl http://$NODE_IP
curl https://$NODE_IP -k

kubectl delete -f test-ingress.yaml

multipass shell nfs
########################################################
apt update && apt -y install nfs-kernel-server
mkdir -p /srv/nfs /srv/nfs/airflow-dags /srv/nfs/airflow-logs
groupadd --gid 60001 anongid
useradd -s /usr/sbin/nologin -d /nonexistent -g anongid --uid 60001 anonuid
chown -R anonuid:anongid /srv/nfs
chmod -R u=rwX,g=rwX,o= /srv/nfs

mv /etc/exports /etc/exports.bak
echo '/srv/nfs 192.168.122.0/24(rw,sync,no_subtree_check,root_squash,anonuid=60001,anongid=60001)' | sudo tee /etc/exports

systemctl restart nfs-kernel-server

echo NFS_SERVER=$(ip route get 1 | awk '{print $7;exit}')
########################################################
# multipass shell microk8s-01
# multipass shell microk8s-02
apt -y install nfs-common
mount -t nfs4 -o nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2 192.168.122.229:/srv/nfs /mnt

df -h /mnt
umount /mnt
########################################################

helm repo add csi-driver-nfs \
  https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/charts \
  --force-update

helm install csi-driver-nfs csi-driver-nfs/csi-driver-nfs \
  --namespace kube-system \
  --set kubeletDir=/var/snap/microk8s/common/var/lib/kubelet \
  --set driver.mountPermissions=0770 \
  --set controller.runOnControlPlane=false \
  --set controller.replicas=1

kubectl -n container-registry port-forward deployment/registry 5000:5000

docker build -t localhost:5000/airflow:2.3.3 .
docker push localhost:5000/airflow:2.3.3

kubectl apply -f mysql.yaml

kubectl get pods
kubectl get pods -l app=mysql -o jsonpath='{.items[0].metadata.name}' | read mysql_pod

kubectl exec -it $mysql_pod -- mysql -h mysql.default.svc.cluster.local -uairflow -pairflow -e "show databases"

kubectl apply -f namespace.yaml -f secrets.yaml -f configmap.yaml -f volumes.yaml

kubectl get pv | grep -e dags -e logs
kubectl apply -f airflow.yaml

kubectl -n airflow get pod --watch

kubectl -n airflow logs deployments/airflow -f

NODE_PORT=$(kubectl -n airflow describe service airflow | grep ^NodePort | grep -Eo '[0-9]*')
NODE_IP=$(kubectl -n airflow get pod -l app=airflow -o jsonpath='{.items[0].status.hostIP}')

echo http://$NODE_IP:$NODE_PORT


cat <<EOF> airflow-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: airflow-ingress
  namespace: airflow
spec:
  ingressClassName: public
  defaultBackend:
    service:
      name: airflow
      port:
        number: 8080
EOF

kubectl apply -f airflow-ingress.yaml

echo https://$NODE_IP
