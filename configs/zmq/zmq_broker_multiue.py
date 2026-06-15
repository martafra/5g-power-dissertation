#!/usr/bin/env python3
# ZMQ multi-UE broker
# DU uses ports 3000 (tx) and 3001 (rx)
# UEs use ports 2100/2101, 2110/2111, ...
# broker sits between DU and UEs

import zmq, threading, sys

N_UES = int(sys.argv[1]) if len(sys.argv) > 1 else 2
BASE_DL_PORT = 2100
BASE_UL_PORT = 2101

ctx = zmq.Context()

def dl_forward():
    # receive from DU tx (DU binds on 3000, we connect)
    src = ctx.socket(zmq.REQ)
    src.connect("tcp://127.0.0.1:3000")
    # send to each UE (UEs connect to us, we bind)
    sinks = []
    for i in range(N_UES):
        s = ctx.socket(zmq.REP)
        s.bind(f"tcp://127.0.0.1:{BASE_DL_PORT + i * 10}")
        sinks.append(s)
    print(f"DL: DU:3000 -> UEs {[BASE_DL_PORT + i*10 for i in range(N_UES)]}")
    poller = zmq.Poller()
    for s in sinks:
        poller.register(s, zmq.POLLIN)
    while True:
        try:
            src.send(b"")
            data = src.recv()
            evts = dict(poller.poll(timeout=0))
            for s in sinks:
                if s in evts:
                    s.recv()
                    s.send(data)
        except zmq.ZMQError as e:
            print(f"DL error: {e}")
            break

def ul_forward():
    # receive from each UE (UEs bind, we connect)
    sources = []
    for i in range(N_UES):
        s = ctx.socket(zmq.REQ)
        s.connect(f"tcp://127.0.0.1:{BASE_UL_PORT + i * 10}")
        sources.append(s)
    # send to DU rx (DU connects to us, we bind)
    dst = ctx.socket(zmq.REP)
    dst.bind("tcp://127.0.0.1:3001")
    print(f"UL: UEs {[BASE_UL_PORT + i*10 for i in range(N_UES)]} -> DU:3001")
    ue_idx = 0
    while True:
        try:
            dst.recv()
            src = sources[ue_idx % N_UES]
            src.send(b"")
            data = src.recv()
            dst.send(data)
            ue_idx += 1
        except zmq.ZMQError as e:
            print(f"UL error: {e}")
            break

t1 = threading.Thread(target=dl_forward, daemon=True)
t2 = threading.Thread(target=ul_forward, daemon=True)
t1.start()
t2.start()
print(f"Broker running for {N_UES} UE(s). Ctrl+C to stop.")
try:
    t1.join()
    t2.join()
except KeyboardInterrupt:
    ctx.destroy()
    print("Broker stopped.")
