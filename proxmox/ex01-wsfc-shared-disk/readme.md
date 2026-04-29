# Lab Guide: Building a Windows Failover Cluster on Ceph (Single-Node Demo)

This guide documents the "unorthodox" process of creating a functional Ceph-backed shared storage environment for Windows Failover Clustering using only a single Proxmox node and a virtual raw disk.

---

## 1. Virtual Hardware Foundation

Since we lacked a physical disk, we created a **10GB Sparse File** and mapped it as a block device.

```bash
# Create the 10GB raw file
truncate -s 10G /root/ceph_disk.img

# Map it to the first available loop device
# -P ensures the kernel scans for partitions
sudo losetup -fP /root/ceph_disk.img

# Verify the device (usually /dev/loop0)
lsblk
```

---

## 2. Ceph Cluster Bootstrap (Proxmox)

Ceph requires a "Brain" (Monitor) and "Manager" before it can handle storage.

```bash
# Initialize Ceph on the local network
pveceph init --network 192.168.1.0/24

# Create the Monitor
pveceph mon create

# Create the Manager
pveceph mgr create

# Install Metadata Server (Required for CephFS warnings to clear)
pveceph mds create
```

---

## 3. Provisioning the "Fake" OSD

Ceph's `pveceph` tool rejects loop devices because they lack hardware serial numbers. We bypassed this by wrapping the loop device in **LVM** manually.

```bash
# 1. Create LVM structures
pvcreate /dev/loop0
vgcreate ceph-virtual-vg /dev/loop0
lvcreate -l 100%FREE -n osd0-lv ceph-virtual-vg

# 2. Export the bootstrap keyring (Fixes "Keyring not found" errors)
ceph auth get client.bootstrap-osd > /etc/pve/priv/ceph.client.bootstrap-osd.keyring

# 3. Force create the OSD using the Logical Volume
ceph-volume lvm create --data ceph-virtual-vg/osd0-lv
```

---

## 4. Bypassing Safety Protocols

A standard Ceph cluster wants 3 nodes. To get a `HEALTH_OK` status on a single node with one disk, we must lower the replication requirements.

```bash
# Allow pool sizes of 1 (Disabled by default)
ceph config set global mon_allow_pool_size_one true

# Set global default to 1 OSD
ceph config set global osd_pool_default_size 1

# Update existing pools to size 1
# Replace <pool_name> with names from 'ceph osd lspools'
ceph osd pool set .mgr size 1
ceph osd pool set device_health_metrics size 1
```

---

## 5. Creating the Shared RBD (The "Cluster Disk")

Now we create a **RADOS Block Device** that will act as the shared SAN storage for Windows.

```bash
# Create a pool for shared storage
ceph osd pool create shared_storage 64 64
ceph osd pool set shared_storage size 1
rbd pool init shared_storage

# Create the 5GB shared disk
rbd create shared_storage/vm-999-shared-disk --size 5G
```

---

## 6. Mapping to Windows VMs (Proxmox CLI)

The Proxmox GUI creates unique disks. To share the **exact same** disk between two VMs, use the CLI or edit the `.conf` files.

```bash
# Ensure both VMs use the VirtIO SCSI Single controller (CRITICAL for Windows)
qm set 100 --scsihw virtio-scsi-single
qm set 101 --scsihw virtio-scsi-single

# Attach the same RBD image to both VMs with the 'shared' flag
qm set 100 --scsi1 ceph-shared:vm-999-shared-disk,shared=1,serial=SHARED01
qm set 101 --scsi1 ceph-shared:vm-999-shared-disk,shared=1,serial=SHARED01
```

---

## 7. Windows Guest Configuration

Inside the Windows Server VMs, the disk will not appear until the **VirtIO SCSI drivers** are installed.

1. **Install Drivers:** Attach `virtio-win.iso`. In Device Manager, update the "SCSI Controller" (yellow bang) pointing to the `vioscsi` folder.
2. **Disk Management:**
    * **VM 1:** Bring disk Online, Initialize as **GPT**, Format as **NTFS**.
    * **VM 2:** Rescan disks. The disk must appear as **Offline/Reserved**.
3. **Failover Cluster Feature:** ```powershell
    Install-WindowsFeature -Name Failover-Clustering -IncludeManagementTools

    ```
4. **Validate:** Run the Validation Wizard. It will now pass the **SCSI-3 Persistent Reservations** test because of the `virtio-scsi-single` controller and Ceph's RBD backend.

---

## 8. Persistence (Post-Reboot)

Because `/dev/loop0` is volatile, if the Proxmox host reboots, run:

```bash
losetup -fP /root/ceph_disk.img
vgchange -ay ceph-virtual-vg
systemctl restart ceph-osd@0
```
