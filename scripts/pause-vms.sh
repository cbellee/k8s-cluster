for i in $(virsh list --name --all); 
do 
    virsh pause $i; 
done