# PubSub+ Quick Guide

Setup a Solace PubSub+ event broker for standalone and HA deployment backed by Libvirt/KVM and Podman.

Two modes: PREP prepares a `solace-base` VM. SINGLE standalone PubSub+. TRIPLET HA triplet.

## Why?

Type1 VM without GUI hassle. Libvirt/KVM is free and runs really fast. Nothing fancy bash scripts. Relatable to Solace documentation. Short `how-to...` guide. Send it to new clients -> reduce back-n-forth emails. Tested on Centos8 and Ubuntu 20.04 LTS.

Note: If you don't like the VM part, comment lines 51 and 55 and don't use the `--prep` mode.

## Usage

```bash
vm-starter.sh

Usage: vm-starter.sh [-n solace | --name=solace] [--prep | --triplet] [-c 2 | --cpu=2] [-m 4096 | --memory=4096] [-d 50 | --disk=50]
```

Options

Default settings: VM name, cpu memory and disk size. You generally only need to give `-n <prefix>` and either `--prep`, `single` or `--triplet`.

`-n | --name`     prefix used to create hostnames. The default is `solace`.
`-c | --cpu`      number of cpus. The default is 2.
`-m | --memory`   memory in GiB. Default is 8192.
`-d | --disk`     disk in GiB. Default is 180. This is the host combined total for 3 VMs.
`--prep`          create base VM image.
`--single`        create single PubSub+ instance cloning from base image.
`--triplet`       create HA triplet instances cloning from base image.
no options        create 1 VM instance cloning from base image.

### PREP Mode

Creates a base image `solace-base` for cloning and also download Solace PubSub+ docker image. The base image can be re-used multiple times. This step may take several minutes to complete. You only need to perform this step once.

```bash
vm-starter.sh -n solace --prep

# Press <Enter> when prompted. Towards the end of the installation, 
# when prompted to login, escape from the login prompt by issuing 
# the key combination `Ctl+Shft+]`.
```

The base image will be created and scrubbed to remove hostIDs, userID, etc. The image is located in `/var/lib/solace/images/solace-base.qcow2` and PubSub+ in `/var/lib/solace/software/solace-pubsub-standard-<latest>-docker.tar.gz` You will also have Libvirt VM management tools like `virt-manager` and `virsh`.

### Single Mode

```bash
/vm-starter.sh -n solace --single
```

This mode will clone 1 VM instance and install the latest `podman` and `slirp4netns` on it. Once this completes, PubSub+ will be installed and configured.

### Triplet Mode

```bash
/vm-starter.sh -n solace --triplet
```

This mode will clone 3 VM instances and install the latest `podman` and `slirp4netns` on each VM. Once this completes, PubSub+ will be installed and configured for HA.

[Launching VM instances](docs/virtual_machine.md)

## Lab Notes

The following scripts are gzipped, base64 encoded and inlined. Both are mostly static. See comments for how this is done, incase you wish to make changes. 

- ks-cfg - virsh `kick-start` used to automate os install
- pubsub+.sh - used to install pubsub+

### PubSub+ Ports

    2222  Solace CLI SSH/SFTP
    8080  PubSub+ Manager, SEMP, SolAdmin
    1943  PubSub+ Manager over HTTPS, SEMP over TLS, SolAdmin over TLS
    5550  Health Check Listen Port
    55555 Solace Message Format (SMF)
    55003 SMF compressed
    55556 SMF routing
    55443 SMF TLS/SSL (with or without compression)
    8008  Web Transport - WebSockets, Comet, etc.
    1443  Web Transport TLS/SSL
    5671  AMQP TLS/SSL
    5672  AMQP
    1883  MQTT
    8883  MQTT TLS/SSL
    8000  MQTT/WebSockets
    8443  MQTT/WebSockets TLS/SSL
    9000  REST
    9443  REST TLS/SSL
    8741  High Availability (HA) Mate Link
    8300  HA Configuration Synchronization
    8301  HA Configuration Synchronization
    8302  HA Configuration Synchronization

### Privileges

Default `podman` file descriptor `ulimit` is 1024. With podman running without privilege, it is not possible to modify user limit settings.

    --ulimit nofile=6324:10192
    --ulimit memlock=-1
    --ulimit core=-1

One approach is to configure system limit setttings.

```bash
sudo vi /etc/security/limits.conf
soladmin        hard    nofile          65535
soladmin        soft    nofile          8096

cat /proc/self/limits | grep open
Max open files            8096                 65535                files
```

Another, is to set limits on the host, then set `podman create` to use the host settings with `--ulimit host`.