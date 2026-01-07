for i in $(virsh list --name --all); 
do 
    virsh snapshot-create $i; 
done
