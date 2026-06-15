#!/bin/bash
# adds subscribers to Open5GS MongoDB
# usage: ./add_subscribers.sh <n_subscribers>

set -uo pipefail

N=${1:-4}

IMSIS=("001010123456781" "001010123456782" "001010123456783" "001010123456784" "001010123456785" "001010123456786" "001010123456787" "001010123456788" "001010123456789" "001010123456790" "001010123456791" "001010123456792" "001010123456793" "001010123456794" "001010123456795")
IPS=("10.45.1.3" "10.45.1.4" "10.45.1.5" "10.45.1.6" "10.45.1.7" "10.45.1.8" "10.45.1.9" "10.45.1.10" "10.45.1.11" "10.45.1.12" "10.45.1.13" "10.45.1.14" "10.45.1.15" "10.45.1.16" "10.45.1.17")

for i in $(seq 0 $((N-1))); do
    IMSI="${IMSIS[$i]}"
    IP="${IPS[$i]}"
    docker exec open5gs_5gc mongosh open5gs --quiet --eval "
    if (db.subscribers.findOne({imsi: '${IMSI}'})) {
        print('already exists: ${IMSI}');
    } else {
        db.subscribers.insertOne({
            imsi: '${IMSI}',
            subscribed_rau_tau_timer: 12,
            network_access_mode: 2,
            subscriber_status: 0,
            access_restriction_data: 32,
            slice: [{
                sst: 1,
                default_indicator: true,
                session: [{
                    qos: { arp: { priority_level: 8, pre_emption_capability: 1, pre_emption_vulnerability: 1 }, index: 9 },
                    ambr: { downlink: { value: 1, unit: 3 }, uplink: { value: 1, unit: 3 } },
                    name: 'internet',
                    type: 3,
                    pcc_rule: [],
                    ue: { ipv4: '${IP}' }
                }]
            }],
            ambr: { uplink: { value: 1, unit: 3 }, downlink: { value: 1, unit: 3 } },
            security: {
                k: '00112233445566778899AABBCCDDEEFF',
                amf: '8000',
                op: null,
                opc: '63BFA50EE6523365FF14C1F45F88737D',
                sqn: NumberLong('96')
            },
            schema_version: 1,
            operator_determined_barring: 0
        });
        print('added: ${IMSI} ip=${IP}');
    }
    "
done
