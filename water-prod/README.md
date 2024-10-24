# Hello CSH!

Shout out to the fella on Stack-Overflow who helped me solve this:

* [DD-WRT: How to][] allow port forwarding to apply to requests originating from inside the LAN?

[DD-WRT: How to]: https://superuser.com/questions/285699/dd-wrt-how-to-allow-port-forwarding-to-apply-to-requests-originating-from-insid

This is my firewall script on the dd-wrt:

```bash
iptables -I FORWARD -s 10.17.13.0/24 -j ACCEPT
iptables -t nat -I POSTROUTING -o wlan0 -j SNAT --to `nvram get lan_ipaddr`
iptables -t nat -A POSTROUTING -s 10.17.13.0/24 -o vlan2 -j MASQUERADE
iptables -t nat -A POSTROUTING -s 10.17.13.0/24 -i br0 -o vlan2 -j SNAT --to-source `nvram get wan_ipaddr`
# https://superuser.com/a/286802/208930
iptables -t nat -I POSTROUTING -o br0 -s 10.17.13.0/24 -d 10.17.13.0/24 -j MASQUERADE
```

[Solved][]:
> Seems like it's a bug in recent DD-WRT builds.
> 
> Use iptables:
> 
> `iptables -t nat -I POSTROUTING -o br0 -s 192.168.1.0/24 -d 192.168.1.0/24 -j MASQUERADE`
> (change your subnet according to your specific LAN)

[Solved]: # https://superuser.com/a/286802/208930

(In my case, the traffic is coming from a different network segment, so it may not be a bug)
