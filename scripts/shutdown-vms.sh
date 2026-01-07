for i in $(virsh list --name --all); 
do 
    virsh shutdown $i; 
done