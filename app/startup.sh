#!/bin/bash

case "$1" in
    start)
        ifconfig wlan0 down
        iw wlan0 set type ibss
        ifconfig wlan0 up
        batctl if add wlan0
        ifconfig bat0 up
        iw wlan0 ibss join gYCLHxHlFVyj 5180
        iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
        iptables -A FORWARD -i bat0 -o eth0 -j ACCEPT
        iptables -A FORWARD -i eth0 -o bat0 -m state --state RELATED,ESTABLISHED -j ACCEPT
        batctl gw client
        ;;
    stop)
        ip route del default dev bat0
        ifconfig bat0 down
        batctl if del wlan0
        iw wlan0 ibss leave
        ifconfig wlan0 down
        iw wlan0 set type managed
        ifconfig wlan0 up
        iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE
        iptables -D FORWARD -i bat0 -o eth0 -j ACCEPT
        iptables -D FORWARD -i eth0 -o bat0 -m state --state RELATED,ESTABLISHED -j ACCEPT
        ;;
    reload|restart)
        $0 stop
        $0 start
        ;;
    *)
        echo "Usage: $0 {start|stop|reload|restart}"
        exit 1
        ;;
esac
