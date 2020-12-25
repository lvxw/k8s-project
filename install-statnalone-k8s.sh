#!/bin/bash

curr_ip=`hostname -i  |  awk '{print $1}'`

function initHostname(){
    hostnamectl set-hostname k8s-standalone
    echo "${curr_ip}    k8s-standalone" >> /etc/hosts
    echo "${curr_ip}    k8s-master01" >> /etc/hosts
    echo "199.232.68.133 raw.githubusercontent.com" >> /etc/hosts

    hostname -F  /etc/hostname
}

function installDependency(){
  yum install -y wget conntrack ntpdate ntp ipvsadm ipset jq iptables curl sysstat libseccomp wget vim net-tools git
}

function closeSwap(){
    swapoff -a
    sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
}

function closeSelinux(){
    setenforce 0
    sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config
}

function closeIpTable(){
    systemctl stop firewalld
    systemctl disable firewalld
    yum -y install iptables-services
    systemctl start iptables
    systemctl enable iptables
    iptables -F
    service iptables save
}

function setTimeZone(){
    timedatectl set-timezone Asia/Shanghai
    timedatectl set-local-rtc 0
    systemctl restart rsyslog
    systemctl restart crond
}

function closeUnusedService(){
    systemctl stop postfix
    systemctl disable postfix
}

function configJournal(){
    mkdir /var/log/journal # 持久化保存日志的目录
    mkdir /etc/systemd/journald.conf.d
    cat > /etc/systemd/journald.conf.d/99-prophet.conf <<EOF
[Journal]
Storage=persistent
Compress=yes
SyncIntervalSec=5m
RateLimitInterval=30s
RateLimitBurst=1000
SystemMaxUse=10G
SystemMaxFileSize=200M
MaxRetentionSec=2week
ForwardToSyslog=no
EOF
    systemctl restart systemd-journald
}


function configIpvs(){
    modprobe br_netfilter
    cat > /etc/sysconfig/modules/ipvs.modules <<EOF
#!/bin/bash
modprobe -- ip_vs
modprobe -- ip_vs_rr
modprobe -- ip_vs_wrr
modprobe -- ip_vs_sh
modprobe -- nf_conntrack_ipv4
EOF
    chmod 755 /etc/sysconfig/modules/ipvs.modules
    bash /etc/sysconfig/modules/ipvs.modules
    lsmod | grep -e ip_vs -e nf_conntrack_ipv4
}


function installDocker(){
    yum install -y yum-utils device-mapper-persistent-data lvm2
    yum-config-manager --add-repo http://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo
    yum install -y docker-ce
    mkdir /etc/docker
    cat > /etc/docker/daemon.json <<EOF
{
"exec-opts": ["native.cgroupdriver=systemd"],
"log-driver": "json-file",
"log-opts": {
"max-size": "100m"
}
}
EOF
   mkdir -p /etc/systemd/system/docker.service.d
   systemctl daemon-reload
   systemctl restart docker
   systemctl enable docker

}

function installKubeadm(){
    cat <<EOF > /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=http://mirrors.aliyun.com/kubernetes/yum/repos/kubernetes-el7-x86_64
enabled=1
gpgcheck=0
repo_gpgcheck=0
gpgkey=http://mirrors.aliyun.com/kubernetes/yum/doc/yum-key.gpg
http://mirrors.aliyun.com/kubernetes/yum/doc/rpm-package-key.gpg
EOF
    yum -y install kubeadm-1.15.1 kubectl-1.15.1 kubelet-1.15.1
    systemctl enable kubelet.service

    kubeadm config print init-defaults > kubeadm-config.yaml
    sed -i "s/advertiseAddress: 1.2.3.4/advertiseAddress: ${curr_ip}/g"  kubeadm-config.yaml
    sed -i "s/serviceSubnet: 10.96.0.0\/12/serviceSubnet: 10.96.0.0\/12\\n  podSubnet: 10.244.0.0\/16/g"  kubeadm-config.yaml
    sed -i "s/kubernetesVersion: v1.14.0/kubernetesVersion: v1.15.1/g"  kubeadm-config.yaml
    sed -i "s/k8s.gcr.io/registry.aliyuncs.com\/google_containers/g" kubeadm-config.yaml

    cat <<EOF >> kubeadm-config.yaml
---
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
featureGates:
SupportIPVSProxyMode: true
mode: ipvs
EOF

    kubeadm init --config=kubeadm-config.yaml --experimental-upload-certs | tee kubeadm-init.log
    mkdir -p $HOME/.kube
    cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
    chown $(id -u):$(id -g) $HOME/.kube/config

    kubectl taint node --all node-role.kubernetes.io/master-
}

function installFlannel(){
    wget https://raw.githubusercontent.com/coreos/flannel/v0.13.0/Documentation/kube-flannel.yml --no-check-certificate
    sed -i "s/quay.io/quay.mirrors.ustc.edu.cn/g" kube-flannel.yml
    kubectl apply -f kube-flannel.yml
}

function configK8s(){
    sed -i "s/- kube-apiserver/- kube-apiserver\\n    - --service-node-port-range=1-65535/g" /etc/kubernetes/manifests/kube-apiserver.yaml
}

function checkK8s(){
     echo "please wait ....................."
     sleep 20s
     kubectl  get nodes
     kubectl  get pod --all-namespaces
}

function installNfs() {
    yum -y install nfs-utils showmount
    echo "/media `echo ${curr_ip}  |  awk -F '.' '{print $1"."$2"."$3".0"}'`/24(rw,no_root_squash,sync)" > /etc/exports
    systemctl start nfs
    systemctl enable nfs
    mkdir /data
    mount  k8s-master01:/media /data/
    showmount -e k8s-master01
    echo "k8s-master01:/media     /data   nfs     defaults        0       0" >> /etc/fstab
}

initHostname
installDependency
closeSwap
closeSelinux
closeIpTable
setTimeZone
closeUnusedService
configJournal
configIpvs
installDocker
installKubeadm
installFlannel
configK8s
installNfs
checkK8s
