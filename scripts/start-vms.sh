for i in $(virsh list --name --all); 
do 
    sudo virsh start $i; 
done