#!/bin/bash

SOLACE_DIR="/var/lib/solace"
DOWNLOAD="${SOLACE_DIR}/software"
SOLACE_PUBSUB_PLUS_TAG=${SOLACE_PUBSUB_PLUS_TAG:-latest} # "9.5.0.30"
USER=$(whoami)
VM_USER="soladmin"
VM_PASSWORD="solace"
VM_NAME="solace"
VM_DESC="Solace PubSub+ Host"
VM_PREP=false
VM_TRIPLET=false
VM_MAC=("52:54:00:8b:4d:f8" "52:54:00:a5:d1:ca" "52:54:00:e6:fd:ed")

VCPUS=4
MEM_SIZE=8192 # MiB
DISK_SIZE=180 # GiB
OS_TYPE="linux"
OS_VARIANT="centos8" # or rhel8
ISO_FILE="${HOME}/Downloads/images/centos/CentOS-8.1.1911-x86_64-dvd1.iso" # or rhel-8.2-x86_64-dvd.iso

declare -A nodes
nodes["${VM_NAME}1"]="192.168.100.101"
nodes["${VM_NAME}2"]="192.168.100.102"
nodes["${VM_NAME}3"]="192.168.100.103"

usage() { echo "Usage: $0 [--prep | --single | --triplet] [-c 2 | --cpu=2] [-m 4096 | --memory=4096] [-d 50 | --disk=50]" 1>&2; exit 1; }
arg() { if [ -z "${OPTARG}" ]; then usage; fi; }
no_arg() { if [ -n "$OPTARG" ]; then usage; fi; }

main() {
    # command-line options
    while getopts ":pstc:m:d:-:" OPT; do
        if [ "$OPT" = "-" ]; then
            OPT="${OPTARG%%=*}"
            OPTARG="${OPTARG#$OPT}"
            OPTARG="${OPTARG#=}"
        fi
        case "${OPT}" in
            prep )           no_arg; VM_PREP=true ;;
            single )         no_arg; VM_SINGLE=true ;;
            triplet )        no_arg; VM_TRIPLET=true ;;
            c | cpus )       arg; VCPUS=${OPTARG} ;;
            m | memory )     arg; MEM_SIZE=${OPTARG} ;;
            d | disk )       arg; DISK_SIZE=${OPTARG} ;;
            ??*|\?|*|? )     usage ;;
        esac
    done
    shift $((OPTIND-1))    
    ([[ ${VM_PREP} = true ]] && ([[ ${VM_SINGLE} = true ]] || [[ ${VM_TRIPLET} = true ]])) && usage
    ([[ ${VM_SINGLE} = true ]] && [[ ${VM_TRIPLET} = true ]]) && usage
    
    if [ ${VM_PREP} == true ]; then
        echo "Initialize SE environment..."
        init
        #create_base_vm  # uncomment if you need vm installed
    else
        echo "Start HA environment..."
        #create_vmz  # uncomment if you need vm installed
        launch_ha
    fi
}

init() {
    echo "solace repository..."
    [ -d ${SOLACE_DIR} ] || sudo mkdir ${SOLACE_DIR}    
    sudo chown -R ${USER}:${USER} ${SOLACE_DIR}

    echo "directory for storing VM images"
    [ -d ${SOLACE_DIR}/images ] || mkdir -p ${SOLACE_DIR}/images

    echo "directory for pubsub+ images"
    [ -d ${DOWNLOAD} ] || mkdir -p ${DOWNLOAD}

    echo "project ssh keys"
    [ -d ./ssh ] || (mkdir ssh && ssh-keygen -q -N "" -f ./ssh/id_rsa)

    echo "fetch pubsub+ image"
    curl -o ${DOWNLOAD}/solace-pubsub-standard-${SOLACE_PUBSUB_PLUS_TAG}-docker.tar.gz https://products.solace.com/download/PUBSUB_DOCKER_STAND
}

create_vm() {
    user=${VM_USER}
    password=${VM_PASSWORD}
    guest=${1}
    certs='./ssh'
    images=${SOLACE_DIR}/images

    rm $(pwd)/ks.cfg
    virsh destroy ${guest}
    virsh undefine ${guest}
    [ -f ${images}/${guest}.qcow2 ] &&  sudo rm ${images}/${guest}.qcow2

    # generate kickstart answer file
    kickstart
    sed -i 's/_HOSTNAME_/'$guest'/g' ks.cfg
    sed -i 's/_USER_/'$user'/g' ks.cfg
    sed -i 's/_PASSWORD_/'$password'/g' ks.cfg
    sed -i "s%_PUBLICKEY_%${publickey}%g" ks.cfg

    # install vm
    virt-install \
    --name ${guest} \
    --description "${VM_DESC}" \
    --vcpus=${VCPUS} \
    --memory=${MEM_SIZE} \
    --os-type ${OS_TYPE} \
    --os-variant=${OS_VARIANT} \
    --memballoon model=virtio \
    --location ${ISO_FILE} \
    --disk path=${images}/${guest}.qcow2,format=qcow2,bus=virtio,size=${DISK_SIZE} \
    --graphics=none \
    --initrd-inject=ks.cfg \
    --extra-args="ks=file:/ks.cfg console=tty0 console=ttyS0,115200n8" \
    --network bridge=virbr0
    # --extra-args "ip=192.168.100.100::192.168.100.1:255.255.255.0:${guest}.local:enp1s0:none"
}

clone_vm() {
    user=${VM_USER}
    password=${VM_PASSWORD}
    base_vm="${1}"
    guest=${2}
    mac=${3}
    certs='./ssh'
    images=${SOLACE_DIR}/images

    virsh destroy ${guest}
    virsh undefine ${guest}
    state=$(virsh list --all | grep ${base_vm} | awk '{ print $3 }')
    if ([ "${state}" != "" ] && [ "${state}" == "running" ]); then
        virsh shutdown ${base_vm}
        sleep 10
    fi
    [ -f ${images}/${guest}.qcow2 ] && sudo rm ${images}/${guest}.qcow2

    publickey=${certs}/id_rsa.pub

    virt-clone \
    --connect qemu:///system \
    --original ${base_vm} \
    --name ${guest} \
    --mac ${mac} \
    --file ${images}/${guest}.qcow2
}

scrub_vm() {
    guest=${1}
    user=${VM_USER}
    certs='./ssh'
    publickey=${certs}/id_rsa.pub

    state=$(virsh list --all | grep ${guest} | awk '{ print $3 }')
    if ([ "${state}" != "" ] && [ "${state}" == "running" ]); then
        virsh shutdown ${guest}
        sleep 10
    fi

    # list of operations to enable
    w=$(virt-sysprep --list-operations | egrep -v 'fs-uuids|lvm-uuids|ssh-userdir' | awk '{ printf "%s,", $1}' | sed 's/,$//')
    #echo "$w"

    sudo virt-sysprep -d ${guest} \
    --hostname ${guest} \
    --keep-user-accounts root,${user} \
    --ssh-inject ${user}:file:${publickey} \
    --network \
    --enable $w \
    --update \
    --quiet
}

create_base_vm() {
    base_vm="solace-base"

    echo "launch ${base_vm}"
    echo "#++++++++++++++++++++++++++"
    create_vm ${base_vm}
    sleep 5
    echo "scrub ${base_vm}"
    echo "#++++++++++++++++++++++++++"
    sleep 5
    scrub_vm ${base_vm}
}

create_vmz() {
    base_vm="solace-base"
    
    if [ ${VM_TRIPLET} == true ]; then
        echo "#++++++++++++++++++++++++++"
        echo "launch triplet instances"
        for i in 1 2 3; do
            guest=${VM_NAME}$i
            mac=${VM_MAC[$i-1]}
            echo "launch ${guest}"
            echo "#++++++++++++++++++++++++++"
            clone_vm ${base_vm} ${guest} ${mac}
            scrub_vm ${guest}
            virsh start ${guest}
            echo
        done
    else
        echo "launch 1 instance"
        echo "#++++++++++++++++++++++++++"
        clone_vm ${base_vm} ${VM_NAME}1
        scrub_vm ${VM_NAME}1
        virsh start ${VM_NAME}1
        echo
    fi
}

launch_ha() {
    [ -f $(pwd)/pubsub+.sh ] && rm $(pwd)/pubsub+.sh
    pubsub_ha

    # get ip
    for i in 1 2 3; do
        echo "Remote launch containers"
        echo "+++++++++++++++++++++++++++++++++++++"
        node="${nodes["${VM_NAME}$i"]}"
        exit
        #node=$(virsh net-dhcp-leases br0|grep solace${i}|awk '{ print $5 }'|cut -d "/" -f1)
        scp -i $(pwd)/ssh/id_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null $(pwd)/pubsub+.sh soladmin@${node}:
        scp -i $(pwd)/ssh/id_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        /var/lib/solace/software/solace-pubsub-standard-latest-docker.tar.gz soladmin@${node}:
        ssh -i $(pwd)/ssh/id_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null soladmin@${node} -- chmod +x pubsub+.sh
        ssh -i $(pwd)/ssh/id_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null soladmin@${node} -- /home/soladmin/pubsub+.sh
        [[ ${VM_SINGLE} = true ]] && exit
    # done
}

kickstart() {
# reverse (decode, uncompress) base64 kickstart answer file. Encode with:
# `cat _ks.cfg | gzip | base64 > ks.bin`
echo 'H4sIAAAAAAAAA71WW2/bNhR+568g3BRuN9BKc1uaQUOzJEWCpk0R17tgaAWKpCTCFMmSlC9N8t93
KNmuq7ZAH4b5web5RH485zsX+dFMOC+NTm8vL66PkdQ+UKUQ487USFFdYqGzyXg0efeSHKOpWOaG
Oo4JmTEwamrTxoO1UHRpmuDTYeOHSIswN24KeG5MsM4Ek/KKWQAoC3JGg4Cl0fFpajSstZF2drR1
sDI+aFqLNLu8Gb97c/r6Ihspw6hCLlLOYYtVVOogFgFnb0/H4z9vbs8zgGHXFBXS+RDpAeDS01wJ
HkExh+i2MS+U1M1iGwqyFp+MFvjUS5qMpS6pNS56LP0kMBRplaFcOBRvR34q7QJ9EqBY7hBTgjpL
XWij0u0xLYOiuVCINsHEZ0iWGijhymkrhFqSxot0ximCXwdY6UxjfTqvhIj+dlJMxhe3MURLvQed
ePpF4J/1gOOCGZ8OvFGUCcxNDY9wpB4g7yvIHOyJ5jbvIHs7+f366uzVxd/ZAIlG0Ziv0olWJjeT
TMRUC93KlA5Y5Yxe8gFCj/BVVzfYUjalpfDo8XoV42+DraX3oGVkWDDVcMENa5/C0WsoNJ92ldaE
4hi9YHACCSsUcQIU9QLNZI1y6ivCTG2VCFC0qGQM1XQqkG+4QVY4qNwGviqQGc1LEZDzS82QsUL7
eFRJoYPf2DEsSOMUhICboD7qOYV7VzYXM8iZLjxpglQ+VicJxsAK8lgxowtZIr/0QdSks8i6xEge
XSYvPpSO2kpC3a7uAvlmEnSrwQ9E8oN9En0p5vMCEVHIWFt16RBRMv/rJ0QKo8PqIlJYB/nlkP0a
gWpBRV9A+0ZrAanx1C3xJgRCJXt+sFiQLUR52jfbcLZAOQuzbXOunu3u9oHDHrDfB3b7Z/a+gez3
kP1nR33k+UGP+eD5UQ85/Ir58NlhDzn6ak9Eyj36LTDvg322X/b6fgKy5dVjoXlsibcwwchqnuIu
h42jsWxjd8BDJFhl8DD2KK+hPbc/p9fX6RP4egrrNzdtl5+fRHSIf8OJCCyJFQ+je8STNcGK71wU
tFHBn2wTQ9VlUyEs/jnF4/Fldjp5d5mNb85eAd/3CVlVG453Dw52v7ulK38WFO7mQjv15hAvm1oZ
Rh5+oQsRDKOdO8xo6IiMX7c1vscwYSwefLg6Twdg0TmMxJcpHt615Y539vDD8AHJAv+Dd+6Mf0hT
Br1jPH6P7+8/g64C8ve/4lAJjbguMFli8L4Bl1aTPSYhwByEJuy6eLVrnaMh2HG41FTzJ8xY93S4
3hKtdYCu2vDkJiSfSVevknYCYXKNiemCXTb1CEI0Ubd2pJxMm1yyE2jxzWHIVojs7UZchWD9SZJw
M9fxTTNq5xXM65FxZdJyyWCcFH5FmHSMyZeUSceZnIFeN+Ps+Mdu78tiDQdFEAS3lYImb3RoNnqP
+mltBzL2FSYMD7q65CL/rwNbTFo3sp27Py5ux1c3b7Kr84cEJ5smoTZAqTYOxuNISR9+JANx32CT
xP/F49tOtFF8L9/jVjrwnESTcvizhTYQvNJwY3n7B+rjxy9xAL6Rt0J2E+lf85ME0+kJAAA=' \
| base64 -d | gunzip > ks.cfg   
}

pubsub_ha() {
# reverse (decode, uncompress) base64 pubsub+ launch script. Encode with:
# `cat _pubsub+.sh | gzip | base64 > pubsub+.bin`
echo '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
+RwAAA==' | base64 -d | gunzip > pubsub+.sh
}

main $@