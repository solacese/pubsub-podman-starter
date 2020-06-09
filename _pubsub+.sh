#!/bin/bash

# Override defaults by setting environment variables
SOLACE_PUBSUB_PLUS_IMAGE=${SOLACE_PUBSUB_PLUS_IMAGE:-standard}
SOLACE_PUBSUB_PLUS_TAG=${SOLACE_PUBSUB_PLUS_TAG:-latest}
SOLACE_ADMIN_PASSWORD=${SOLACE_ADMIN_PASSWORD:-admin}
SOLACE_DIR="/var/lib/solace"
SWAP="${SOLACE_DIR}/swap"
JAIL="${SOLACE_DIR}/jail"
SPOOL="${SOLACE_DIR}/spool"
LOGS="/var/log/solace"
SHARE="/mnt/solace-share"
USER=$(whoami)

presharedkey="c29sYWNlMTIz123456789121313123213123123123123123123213213123213123123123"
node1="solace1"
node2="solace2"
node3="solace3"
node1ip="192.168.100.101"
node2ip="192.168.100.102"
node3ip="192.168.100.103"
node1type="message_routing"
node2type="message_routing"
node3type="monitoring"
sysloghost="192.168.1.1:122"
offset=0
guest=$(hostname)

case "${guest}" in
$node1 )
    echo "Setting up ACTIVE NODE"
    node=$node1
    role=primary
    nodetype=message_routing
    node_ssh_port=1222
    # offset=100
    # mate_smf=$((55555+200))
    ;;
$node2 )
    echo "Setting up STANDBY NODE"
    node=$node2
    role=backup
    nodetype=message_routing
    node_ssh_port=3222
    # offset=200
    # mate_smf=$((55555+100))
    ;;
$node3 )
    echo "Setting up MONITORING NODE"
    node=$node3
    role=primary
    nodetype=monitoring
    node_ssh_port=3222
    # offset=300
    ;;
* )
    echo "Usage: solace.sh 1|2|3"
    echo "\t1\tActive Node"
    echo "\t2\tStandby Node"
    echo "\t3\tMonitoring Node"
    exit 2
    ;;
esac

main() {
    echo "Launch PubSub+..."
    init
    # launch_1
    launch_ha
}

init() {
    echo "solace repository..."
    [ -d ${SOLACE_DIR} ] || sudo mkdir ${SOLACE_DIR}
    sudo chown -R ${USER}:${USER} ${SOLACE_DIR}

    echo "solace swap"
    [ -d ${SWAP} ] || mkdir -p ${SWAP}
    sudo chown -R ${USER}:${USER} ${SWAP}

    echo "solace spool"
    [ -d ${SPOOL}/${node}-spool ] || mkdir -p ${SPOOL}/${node}-spool
    sudo chown -R ${USER}:${USER} ${SPOOL}

    echo "solace jail"
    [ -d ${JAIL}/${node}-jail ] || mkdir -p ${JAIL}/${node}-jail
    sudo chown -R ${USER}:${USER} ${JAIL}

    echo "solace logs"
    [ -d ${LOGS} ] || sudo mkdir -p ${LOGS}
    sudo chown -R ${USER}:${USER} ${LOGS}

    echo "optional - share host diractory via sshfs, can volume mount as well in a container."
    [ -d ${SHARE} ] || sudo mkdir -p ${SHARE}
    sudo chown -R ${USER}:${USER} ${SHARE}

    echo "install podman"
    os=$(cat /etc/os-release | grep "^ID=" | awk -F= '{print $2 }')
    if [ ${os}==centos ] || [ ${os}==rhat ]; then
        sudo dnf -y module disable container-tools
        sudo dnf -qq -y install 'dnf-command(copr)'
        sudo dnf -y copr enable rhcontainerbot/container-selinux
        sudo curl -L -o /etc/yum.repos.d/devel:kubic:libcontainers:stable.repo https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/CentOS_8/devel:kubic:libcontainers:stable.repo
        sudo dnf update -qq
        sudo dnf -qq -y install podman
    elif [ ${os}==ubuntu ]; then
        . /etc/os-release
        sudo sh -c "echo 'deb https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/xUbuntu_${VERSION_ID}/ /' > /etc/apt/sources.list.d/devel:kubic:libcontainers:stable.list"
        curl -L https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/xUbuntu_${VERSION_ID}/Release.key | sudo apt-key add -
        sudo apt-get update -qq
        sudo apt-get -qq -y install podman
    fi

    echo "set user namespace mapping"
    sudo sed -i s/^${USER}.*/${USER}:1000000:65536/ /etc/subuid
    sudo sed -i s/^${USER}.*/${USER}:1000000:65536/ /etc/subgid
    podman system migrate

    echo "set user ulimit higher than solace container ulimit"
    echo "soladmin        hard    nofile          65535" | sudo tee /etc/security/limits.conf
    echo "soladmin        soft    nofile           8096" | sudo tee -a /etc/security/limits.conf

    echo "configure swap space"
    sudo swapoff ${SWAP}/${node}-swap > /dev/null 2>&1
    dd if=/dev/zero of=${SWAP}/${node}-swap count=2048 bs=1MiB
    mkswap -f ${SWAP}/${node}-swap > /dev/null 2>&1
    chmod 0600 ${SWAP}/${node}-swap
    podman unshare chown 30:30 ${SWAP}/${node}-swap
    sudo swapon -f ${SWAP}/${node}-swap
    sudo sed -i 's|^.*containers\/swap.*$|'${SWAP}/${node}-swaptou' none swap sw 0 0|' /etc/fstab

    echo "cleanup previous environment"
    podman rm -f solace > /dev/null 2>&1
    tag=$(podman images --format "table {{.Repository}} {{.Tag}}" | grep solace | awk '{ print $2 }')
    podman rmi solace-pubsub-standard:${tag} > /dev/null 2>&1

    echo "load pubsub+ standard edition software image"
    podman load -i ${HOME}/solace-pubsub-standard-${SOLACE_PUBSUB_PLUS_TAG}-docker.tar.gz
}

launch_1() {
    echo "create standalone software message broker..."
    echo "#++++++++++++++++++++++++++"

    tag=$(podman images --format "table {{.Repository}} {{.Tag}}" | grep solace | awk '{ print $2 }')

    echo "launch pubsub+"
    
    podman run -d \
    --env username_admin_globalaccesslevel=admin \
    --env username_admin_password=${SOLACE_ADMIN_PASSWORD} \
    --env system_scaling_maxconnectioncount=1000 \
    --userns keep-id \
    --log-driver k8s-file \
    --log-opt path=${LOGS}/${node}.log \
    --restart=on-failure:1 \
    --shm-size=2.5g \
    --ulimit host \
    --pull never \
    -p 8080:8080 \
    -p 55555:55555 \
    -p 1943:1943 \
    -p 1883:1883 \
    -p 8883:8883 \
    -p 8000:8000 \
    -p 5671:5671 \
    -p 9000:9000 \
    -p 9443:9443 \
    -p ${node_ssh_port}:2222 \
    -v ${JAIL}/${node}-jail:/usr/sw/jail \
    -v ${SPOOL}/${node}-spool:/usr/sw/internalSpool \
    --name=solace \
    --hostname=${node} \
    localhost/solace-pubsub-${SOLACE_PUBSUB_PLUS_IMAGE}:${tag}
}

launch_ha() {
    echo "create HA software message broker..."
    echo "#++++++++++++++++++++++++++"

    tag=$(podman images --format "table {{.Repository}} {{.Tag}}" | grep solace | awk '{ print $2 }')

    echo "launch pubsub+"

    podman run -d \
    --env username_admin_globalaccesslevel=admin \
    --env username_admin_password=${SOLACE_ADMIN_PASSWORD} \
    --env system_scaling_maxconnectioncount=1000 \
    --env redundancy_enable=yes \
    --env redundancy_authentication_presharedkey_key=$presharedkey \
    --env redundancy_group_node_${node1}_connectvia=$node1ip \
    --env redundancy_group_node_${node1}_nodetype=$node1type \
    --env redundancy_group_node_${node2}_connectvia=$node2ip \
    --env redundancy_group_node_${node2}_nodetype=$node2type \
    --env redundancy_group_node_${node3}_connectvia=$node3ip \
    --env redundancy_group_node_${node3}_nodetype=$node3type \
    --env redundancy_activestandbyrole=$role \
    --env system_scaling_maxconnectioncount=1000 \
    --env routername=$node \
    --env configsync_enable=yes \
    --env nodetype=$nodetype \
    --userns keep-id \
    --log-driver k8s-file \
    --log-opt path=${LOGS}/${node}.log \
    --restart=on-failure:1 \
    --shm-size=2.5g \
    --ulimit host \
    --pull never \
    -p 55555:55555 \
    -p 8080:8080 \
    -p 1943:1943 \
    -p 1883:1883 \
    -p 8883:8883 \
    -p 8000:8000 \
    -p 5671:5671 \
    -p 9000:9000 \
    -p 9443:9443 \
    -p ${node_ssh_port}:2222 \
    -v ${JAIL}/${node}-jail:/usr/sw/jail \
    -v ${SPOOL}/${node}-spool:/usr/sw/internalSpool \
    --name=solace \
    --hostname=${node} \
    --network=host \
    localhost/solace-pubsub-${SOLACE_PUBSUB_PLUS_IMAGE}:${tag}
}

main $@