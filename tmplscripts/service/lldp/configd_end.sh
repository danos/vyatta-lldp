#!/bin/bash
if [ ${COMMIT_ACTION} = 'DELETE' ]; then
    /opt/vyatta/sbin/vyatta-config-lldp.pl --action=disable
else
    /opt/vyatta/sbin/vyatta-config-lldp.pl --action=enable
fi;
