#!/bin/bash
virsh shutdown mycluster-cp1
virsh shutdown mycluster-cp2
virsh shutdown mycluster-cp3
virsh shutdown mycluster-wk1
virsh shutdown mycluster-wk2
virsh shutdown mycluster-wk3

sudo cp /media/STORAGE/VM/blank/*.rawdisk /media/STORAGE/VM
virsh start mycluster-cp1
virsh start mycluster-cp2
virsh start mycluster-cp3
virsh start mycluster-wk1
virsh start mycluster-wk2
virsh start mycluster-wk3

