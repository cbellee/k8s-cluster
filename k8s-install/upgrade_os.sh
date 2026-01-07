sudo apt install ubuntu-release-upgrader-core

grep 'lts' /etc/update-manager/release-upgrades
sudo vi /etc/update-manager/release-upgrades

sudo ufw allow 1022/tcp comment 'Open port ssh TCP/1022 as failsafe for upgrades'
sudo ufw status

sudo apt update && sudo apt upgrade -y
sudo do-release-upgrade -d