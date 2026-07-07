# 2026-07-07 16:01:14 by RouterOS 7.23.1
# software id = EKBF-RRLM
#
# model = E60iUGS
# serial number = HJR0AKXSMZD
/interface bridge
add admin-mac=04:F4:1C:32:D5:3B auto-mac=no comment=defconf name=bridge
/interface ethernet
set [ find default-name=ether1 ] name=wan
/interface wireguard
add listen-port=13231 mtu=1420 name=wireguard1
/interface list
add comment=defconf name=WAN
add comment=defconf name=LAN
/ip pool
add name=default-dhcp ranges=192.168.88.10-192.168.88.254
add name=kube-vm-pool ranges=192.168.89.10-192.168.89.254
/ip dhcp-server
add address-pool=default-dhcp interface=bridge lease-script=":local ttl 600s\
    \n\
    \n:local GetDomain do={\
    \n    :local ipaddr [:toip \$1]\
    \n    /ip dhcp-server network\
    \n    :foreach network in [find] do={\
    \n        :local netblock [get value-name=address \$network]\
    \n        :if (\$ipaddr in \$netblock) do={\
    \n            :return [get value-name=domain \$network]\
    \n        }\
    \n    }\
    \n}\
    \n\
    \n:local IsValidFQDN do={\
    \n    :local string [:tostr \$1]\
    \n    :return (\$string~\"^(([a-zA-Z0-9][a-zA-Z0-9-]{0,61}){0,1}[a-zA-Z]\\\
    \\.){1,9}[a-zA-Z][a-zA-Z0-9-]{0,28}[a-zA-Z]\\\$\")\
    \n}\
    \n\
    \n/ip dns static\
    \n:if (\$leaseBound = 1) do={\
    \n    :local FQDN \"\$(\$\"lease-hostname\").\$[\$GetDomain \$leaseActIP]\
    \"\
    \n    :if ([\$IsValidFQDN \$FQDN]) do={\
    \n        remove numbers=[find where name=\$FQDN]\
    \n        add name=\$FQDN address=\$leaseActIP ttl=\$ttl\
    \n    }\
    \n} else={\
    \n    remove numbers=[find where address=\$leaseActIP ttl=\$ttl]\
    \n}" name=defconf
/routing bgp instance
add as=64512 disabled=no name=bgp-1 router-id=192.168.88.1 routing-table=main
/routing bgp template
add as=64512 name=k8s-cluster-template output.default-originate=always \
    .redistribute=connected,static
/disk settings
set auto-media-interface=bridge auto-media-sharing=yes auto-smb-sharing=yes
/interface bridge port
add bridge=bridge comment=defconf interface=ether2
add bridge=bridge comment=defconf interface=ether3
add bridge=bridge comment=defconf interface=ether4
add bridge=bridge comment=defconf interface=ether5
add bridge=bridge comment=defconf interface=sfp1
/ip neighbor discovery-settings
set discover-interface-list=LAN
/interface list member
add comment=defconf interface=bridge list=LAN
add comment=defconf interface=wan list=WAN
/interface wireguard peers
add allowed-address=192.168.100.2/32 interface=wireguard1 name=peer4 \
    public-key="JfVHU35X1up0GEB82p7Dj5EwejOFVDCKe3ZsQoDCJWQ="
/ip address
add address=192.168.88.1/24 comment=defconf interface=bridge network=\
    192.168.88.0
add address=192.168.100.1/24 interface=wireguard1 network=192.168.100.0
add address=192.168.89.1/24 comment="Kubernetes virtual cluster" interface=\
    bridge network=192.168.89.0
/ip cloud
set ddns-enabled=yes
/ip dhcp-client
add comment=defconf interface=wan name=client1
/ip dhcp-server lease
add address=192.168.88.106 client-id=1:10:97:bd:59:7b:a0 mac-address=\
    10:97:BD:59:7B:A0 server=defconf
add address=192.168.88.11 mac-address=90:E6:43:03:1F:89 server=defconf
/ip dhcp-server network
add address=192.168.88.0/24 comment=defconf dns-server=192.168.88.1 domain=\
    internal.bellee.net gateway=192.168.88.1
add address=192.168.89.0/24 comment=kube-vm-network dns-server=192.168.88.1 \
    domain=internal.bellee.net gateway=192.168.88.1
/ip dns
set allow-remote-requests=yes
/ip dns static
add address=192.168.88.167 comment=defconf name=\
    syn-nas-01.internal.bellee.net type=A
add address=172.16.0.0 name=colourserver-green.internal.bellee.net type=A
add address=172.16.0.1 name=colourserver-blue.internal.bellee.net type=A
add address=192.168.88.69 name=Lounge-Room.internal.bellee.net ttl=10m type=A
add address=192.168.88.120 name=ShedWifiAP.internal.bellee.net ttl=10m type=A
add address=192.168.88.134 name=LoungeWifiAP.internal.bellee.net ttl=10m \
    type=A
add address=192.168.88.111 name=HallWifiAP.internal.bellee.net ttl=10m type=A
add address=192.168.88.106 name=espressif.internal.bellee.net ttl=10m type=A
add address=192.168.88.113 name=SonosZP.internal.bellee.net ttl=10m type=A
add address=192.168.88.17 name=Mac.internal.bellee.net ttl=10m type=A
add address=192.168.88.40 name=SAW-L20788917AU.internal.bellee.net ttl=10m \
    type=A
add address=192.168.88.121 name=Dog.internal.bellee.net ttl=10m type=A
add address=192.168.88.196 name=XboxOne.internal.bellee.net ttl=10m type=A
add address=192.168.88.33 name=Carlies-Laptop.internal.bellee.net ttl=10m \
    type=A
add address=192.168.88.114 name=MacBookPro.internal.bellee.net ttl=10m type=A
add address=192.168.88.14 name=CB-HP-LT.internal.bellee.net ttl=10m type=A
add address=192.168.88.16 name=iPhone.internal.bellee.net ttl=10m type=A
add address=192.168.88.122 name=cb-ubuntu-pc.internal.bellee.net ttl=10m \
    type=A
add address=192.168.88.23 name=LGwebOSTV.internal.bellee.net ttl=10m type=A
add address=192.168.88.31 name=vagrant.internal.bellee.net ttl=10m type=A
/ip firewall filter
add action=accept chain=input comment="allow WireGuard" dst-port=13231 \
    protocol=udp
add action=accept chain=input comment="allow WireGuard traffic" src-address=\
    192.168.100.0/24
add action=accept chain=input comment=\
    "defconf: accept established,related,untracked" connection-state=\
    established,related,untracked
add action=drop chain=input comment="defconf: drop invalid" connection-state=\
    invalid
add action=accept chain=input comment="defconf: accept ICMP" protocol=icmp
add action=accept chain=input comment=\
    "defconf: accept to local loopback (for CAPsMAN)" dst-address=127.0.0.1
add action=drop chain=input comment="defconf: drop all not coming from LAN" \
    in-interface-list=!LAN
add action=accept chain=forward comment="defconf: accept in ipsec policy" \
    disabled=yes ipsec-policy=in,ipsec
add action=accept chain=forward comment="defconf: accept out ipsec policy" \
    disabled=yes ipsec-policy=out,ipsec
add action=fasttrack-connection chain=forward comment="defconf: fasttrack" \
    connection-state=established,related
add action=accept chain=forward comment=\
    "defconf: accept established,related, untracked" connection-state=\
    established,related,untracked
add action=drop chain=forward comment="defconf: drop invalid" \
    connection-state=invalid
add action=drop chain=forward comment=\
    "defconf: drop all from WAN not DSTNATed" connection-nat-state=!dstnat \
    connection-state=new in-interface-list=WAN
add action=accept chain=forward comment=solar-ev-charger:allow-https-forward \
    connection-nat-state=dstnat dst-port=8443 protocol=tcp
add action=accept chain=forward comment=solar-ev-charger:allow-http-forward \
    connection-nat-state=dstnat dst-port=8081 protocol=tcp
/ip firewall nat
add action=masquerade chain=srcnat comment="defconf: masquerade" \
    ipsec-policy=out,none out-interface-list=WAN
add action=dst-nat chain=dstnat comment=solar-ev-charger:https dst-port=443 \
    in-interface=wan protocol=tcp to-addresses=192.168.88.167 to-ports=443
add action=dst-nat chain=dstnat comment=solar-ev-charger:http dst-port=80 \
    in-interface=wan protocol=tcp to-addresses=192.168.88.167 to-ports=80
add action=dst-nat chain=dstnat comment="hairpin ev.bellee.net 443" \
    dst-address=1.123.159.151 dst-port=443 protocol=tcp src-address=\
    192.168.88.0/24 to-addresses=192.168.88.167 to-ports=443
add action=dst-nat chain=dstnat comment="hairpin ev.bellee.net 80" \
    dst-address=1.123.159.151 dst-port=80 protocol=tcp src-address=\
    192.168.88.0/24 to-addresses=192.168.88.167 to-ports=80
add action=masquerade chain=srcnat comment="hairpin masquerade 443" \
    dst-address=192.168.88.167 dst-port=443 protocol=tcp src-address=\
    192.168.88.0/24
add action=masquerade chain=srcnat comment="hairpin masquerade 80" \
    dst-address=192.168.88.167 dst-port=80 protocol=tcp src-address=\
    192.168.88.0/24
/ip firewall service-port
set ftp disabled=yes
set tftp disabled=yes
set pptp disabled=yes
/ip service
set ftp disabled=yes
set telnet disabled=yes
set www address=192.168.88.0/24 disabled=yes
/ipv6 firewall address-list
add address=::/128 comment="defconf: unspecified address" list=bad_ipv6
add address=::1/128 comment="defconf: lo" list=bad_ipv6
add address=fec0::/10 comment="defconf: site-local" list=bad_ipv6
add address=::ffff:0.0.0.0/96 comment="defconf: ipv4-mapped" list=bad_ipv6
add address=::/96 comment="defconf: ipv4 compat" list=bad_ipv6
add address=100::/64 comment="defconf: discard only " list=bad_ipv6
add address=2001:db8::/32 comment="defconf: documentation" list=bad_ipv6
add address=2001:10::/28 comment="defconf: ORCHID" list=bad_ipv6
add address=3ffe::/16 comment="defconf: 6bone" list=bad_ipv6
/ipv6 firewall filter
add action=accept chain=input comment=\
    "defconf: accept established,related,untracked" connection-state=\
    established,related,untracked
add action=drop chain=input comment="defconf: drop invalid" connection-state=\
    invalid
add action=accept chain=input comment="defconf: accept ICMPv6" protocol=\
    icmpv6
add action=accept chain=input comment="defconf: accept UDP traceroute" \
    dst-port=33434-33534 protocol=udp
add action=accept chain=input comment=\
    "defconf: accept DHCPv6-Client prefix delegation." dst-port=546 protocol=\
    udp src-address=fe80::/10
add action=accept chain=input comment="defconf: accept IKE" dst-port=500,4500 \
    protocol=udp
add action=accept chain=input comment="defconf: accept ipsec AH" protocol=\
    ipsec-ah
add action=accept chain=input comment="defconf: accept ipsec ESP" protocol=\
    ipsec-esp
add action=accept chain=input comment=\
    "defconf: accept all that matches ipsec policy" ipsec-policy=in,ipsec
add action=drop chain=input comment=\
    "defconf: drop everything else not coming from LAN" in-interface-list=\
    !LAN
add action=fasttrack-connection chain=forward comment="defconf: fasttrack6" \
    connection-state=established,related
add action=accept chain=forward comment=\
    "defconf: accept established,related,untracked" connection-state=\
    established,related,untracked
add action=drop chain=forward comment="defconf: drop invalid" \
    connection-state=invalid
add action=drop chain=forward comment=\
    "defconf: drop packets with bad src ipv6" src-address-list=bad_ipv6
add action=drop chain=forward comment=\
    "defconf: drop packets with bad dst ipv6" dst-address-list=bad_ipv6
add action=drop chain=forward comment="defconf: rfc4890 drop hop-limit=1" \
    hop-limit=equal:1 protocol=icmpv6
add action=accept chain=forward comment="defconf: accept ICMPv6" protocol=\
    icmpv6
add action=accept chain=forward comment="defconf: accept HIP" protocol=139
add action=accept chain=forward comment="defconf: accept IKE" dst-port=\
    500,4500 protocol=udp
add action=accept chain=forward comment="defconf: accept ipsec AH" protocol=\
    ipsec-ah
add action=accept chain=forward comment="defconf: accept ipsec ESP" protocol=\
    ipsec-esp
add action=accept chain=forward comment=\
    "defconf: accept all that matches ipsec policy" ipsec-policy=in,ipsec
add action=drop chain=forward comment=\
    "defconf: drop everything else not coming from LAN" in-interface-list=\
    !LAN
/routing bgp connection
add instance=bgp-1 local.role=ibgp name=peer-to-k8s-wk-01 remote.address=\
    192.168.88.60 .as=64512 templates=k8s-cluster-template
add instance=bgp-1 local.role=ibgp name=peer-to-k8s-wk-02 remote.address=\
    192.168.88.61 .as=64512 templates=k8s-cluster-template
add instance=bgp-1 local.role=ibgp name=peer-to-k8s-wk-03 remote.address=\
    192.168.88.62 .as=64512 templates=k8s-cluster-template
/system clock
set time-zone-name=Australia/Sydney
/tool mac-server
set allowed-interface-list=LAN
/tool mac-server mac-winbox
set allowed-interface-list=LAN
