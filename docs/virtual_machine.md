# VM Instances With QEMU/KVM

- qemu-kvm - The main package
- qemu-kvm - Includes the libvirtd server exporting the virtualization support
- libvirt-client - This package contains virsh and other client-side utilities
- libguestfs-tools - This package lets you reset/reconfigure virtual machines
- virt-install - Utility to install virtual machines
- virt-viewer - Utility to display graphical console for a virtual machine

```bash
sudo yum install qemu-kvm qemu-kvm libvirt-client libguestfs-tools virt-install virt-viewer
# sudo apt install qemu-kvm qemu-kvm libvirt-client libguestfs-tools virt-install virt-viewer
```

## Virsh Commands

```bash
virsh list --all
virsh edit node1
# start|reboot|shutdown|autostart|autostart --disable|destroy|undefine node1
virsh reboot node1
lscpu
# clone
virsh shutdown
virt-clone \
--original=node1 \
--name=node2 \
--file=${HOME}/.local/share/libvirt/images/node1.qcow2
# networking info
virsh net-list
virsh net-info default
virsh net-dumpxml default
virsh net-dhcp-leases default | grep solace1 | awk '{ print $5}'
```

## Virt-Manager Wifi Bridge

Note: Other CLI and UI networking tools exist: `nm-connection-editor`, `nmcli` and `nmtui`.

```bash
# This approach is clean and elegant and works with laptop wifi
# - Delete default bridge in virt-manager UI
# - Create bridge br0 as 'NAT to wifi' interface wlp82s0
# - Add installed VM mac addresses to br0 XML
virsh dumpxml solace1 | grep -i 'mac address'
virsh net-edit default
   <dhcp>
      <range start="192.168.100.100" end="192.168.100.254"/>
      <host mac="52:54:00:bb:f5:d7" name="solace-base" ip="192.168.100.100"/>
      <host mac="52:54:00:8b:4d:f8" name="solace1" ip="192.168.100.101"/>
      <host mac="52:54:00:a5:d1:ca" name="solace2" ip="192.168.100.102"/>
      <host mac="52:54:00:e6:fd:ed" name="solace3" ip="192.168.100.103"/>
   </dhcp>

for i in 1 2 3; do virsh shutdown solace$i; done
virsh net-destroy br0
sudo systemctl stop libvirtd
sudo systemctl start libvirtd
virsh net-start br0
for i in 1 2 3; do virsh start solace$i; done
```

## Clone VM

```bash
virsh suspend basevm
virt-clone --original basevm --name testvm --file /var/lib/libvirt/images/testvm-disk01.qcow2
virsh resume basevm
w=$(virt-sysprep --list-operations | egrep -v 'fs-uuids|lvm-uuids|ssh-userdir' | awk '{ printf "%s,", $1}' | sed 's/,$//')
echo "$w"
virt-sysprep -d testvm --hostname testvm --keep-user-accounts vivek --enable $w
```

## Snapshot

```bash
virsh snapshot-list --domain solace1
virsh dumpxml solace1 | grep -i qemu
virsh snapshot-create-as --domain solace1 \
--name "20200524s0" \
--description "Snapshot before upgrading to PubSub+ v9.6" \
--live
virsh snapshot-info --domain solace1 --snapshotname 20200524s0
virsh shutdown --domain solace1
virsh snapshot-revert --domain solace1 --snapshotname 20200524s0 --running
virsh snapshot-delete --domain solace1 --snapshotname 20200524s0
```

## Cockpit

```bash
# sudo yum install cockpit cockpit-machines cockpit-bridge
# Ubuntu
sudo apt install cockpit cockpit-machines cockpit-bridge
sudo systemctl start cockpit.socket
sudo systemctl enable cockpit.socket
sudo systemctl status cockpit.socket
```
