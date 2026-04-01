

# You <-> Wireguard <-> Raspberry Pi <-> Wireguard <-> The Internet

## Context

I just could not come up with another name for it. Long story short, once I 
purchased Proton VPN annual subscription I faced an issue (if it can be called an issue 
really) that my Raspberry pi with Adguard Home and other stuff like Syncthing
was just lying around while I was connected to ProtonVPN. Every time I needed
to use some of my Raspberry PI services from my phone (for instance),
I needed to switch from ProtonVPN to Wireguard vpn that I use to connect to Raspberry pi. 
And when I do that, traffic does reach RP, but leaves it via router without VPN.
So, at that point it was either:

```txt
Phone <-> Proton VPN <-> The Internet
```
or:
```txt
Phone <-> Wireguard VPN <-> Raspberry PI <-> The Internet
```


I really suppose that it is a common setup to have a Raspberry Pi with different services 
running within your home network and you connect to it either just within the network, or by using your 
router's public IP (from ISP) and some VPN configured on RP (usually Wireguard). So, 
such issues feels common to me.


## Quick start

So, you can see this script `main.sh`. It is really simple, you should modify
it for your purposes, but basically it requires you to have a directory containing
different Wireguard configs. This script picks a random one, brings it up and configures 
routing to route all Internet-targeted traffic via that VPN while still allowing to use 
your local services. Also it configures a cron job that will rotate the vpn to another 
random one from that directory once in a while.

To setup:
```bash
./main.sh up
```
To teardown:
```bash
./main.sh down
```

To rotate right now
```bash
./main.sh rotate
```

**NOTE:** this script currently does not manage you firewall rules, but you need masquerade and allow forwarding from your WG subnet to the one it brings up and back:
```conf
table inet filter {
	chain INPUT {
		type filter hook input priority filter; policy drop;
		ct state established,related accept comment "Allow traffic originated from us"
		ct state invalid drop comment "Drop invalid connections"
		iif "lo" accept comment "Accept traffic from localhost"
		tcp dport 22 accept comment "Accept SSH"
		iifname "eth0" udp dport 51820 accept comment "Accept WG connections"
	}

	chain FORWARD {
		type filter hook forward priority filter; policy drop;
		iifname "eth0" oifname "wg0" accept comment "Allow VPN clients to connect (reach wg0 basically)"
		iifname "wg0" oifname "eth0" accept comment "Allow VPN clients to visit the Internet"
		iifname "wg0" oifname "protonvpn" accept comment "Phone traffic to ProtonVPN"
		iifname "vpn" oifname "wg0" accept comment "ProtonVPN return traffic to phone"
	}

	chain OUTPUT {
		type filter hook output priority filter; policy accept;
	}
}
table inet wireguard {
	chain POSTROUTING {
		type nat hook postrouting priority srcnat; policy accept;
		oifname "eth0" ip saddr 10.154.100.0/24 masquerade
		oifname "vpn" ip saddr 10.154.100.0/24 masquerade comment "Masquerade phone traffic via ProtonVPN"
	}
}

```

## Configuring

Currently there are no options that commands can accept. The bevaviour is configured via ENVS:

- `INTERFACE_NAME` - (default: `vpn`) the name of Wireguard interface to bring up and down. I name it `protonvpn` in my setup
- `CONFIGS_DIR` - (default `/etc/wireguard/$INTERFACE_NAME/`) path to directory where different Wireguard configs are. I put here configs for different countries downloaded from Proton VPN website
- `ROUTING_TABLE_ID` - (default `200`) id of custom routing table that is created while configuring routing. Does not matter much. Should not be 254, 255. If trafic originates from our local Wireguard subnet, it is routed by this new table to `$INTERFACE_NAME` interface
- `ROUTING_RULE_PRIORITY` - (default `100`) priority of the rule that forwards traffic to the routing table described above
- `SOURCE_SUBNET` - (default `10.154.100.0/24`) our local Wireguard subnet. Mine was probably created by `pivpn` if (I'm not mistaken)
- `SOURCE_IF` - (default `wg0`) interface name of our local Wireguard
- `DO_NOT_STRIP_THEIR_DNS` - (default `<empty>`) if smt is set there, it will NOT remove `DNS = .*` from Wireguard condigs inside `$CONFIGS_DIR`
- `ROTATE_CRONTAB` - (default `0 */6 * * *`) when to rotate vpns
- `CRON_FILENAME` - (default `vpn-rotate.sh`) script with this name will be added to `/etc/cron.d/` (and removed at teardown, so be careful to not have your own scripts with such name :))



## My setup

My setup where it works:
- Hardware: Raspberry PI 5
- OS: dietpi

