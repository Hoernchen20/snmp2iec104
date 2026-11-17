# A net-snmp agent to poll and to send traps from, for trying the gateway
# without real devices. Only for the compose test setup.
FROM debian:trixie-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends snmpd snmp \
 && rm -rf /var/lib/apt/lists/*
COPY snmpd.conf /etc/snmp/snmpd.conf
COPY send-traps /usr/local/bin/send-traps
EXPOSE 161/udp
CMD ["snmpd", "-f", "-Lo", "-C", "-c", "/etc/snmp/snmpd.conf", "udp:161"]
