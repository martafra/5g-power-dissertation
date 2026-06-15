#!/usr/bin/env python3
# GNU Radio broker for 2 UE ZMQ setup
# DL: DU tx (2000) -> UE1 rx (2100) and UE2 rx (2110)
# UL: UE1 tx (2101) -> DU rx (2001), UE2 tx (2111) -> DU rx (2001)

from gnuradio import gr, zeromq, blocks

class zmq_broker_2ue(gr.top_block):
    def __init__(self):
        gr.top_block.__init__(self, "ZMQ Broker 2 UE")

        # DL source from DU
        self.dl_src = zeromq.req_source(gr.sizeof_gr_complex, 1, 'tcp://127.0.0.1:2000', 100, False, -1)

        # DL sinks to UE1 and UE2
        self.dl_snk1 = zeromq.rep_sink(gr.sizeof_gr_complex, 1, 'tcp://127.0.0.1:2100', 100, False, -1)
        self.dl_snk2 = zeromq.rep_sink(gr.sizeof_gr_complex, 1, 'tcp://127.0.0.1:2110', 100, False, -1)

        # UL sources from UE1 and UE2
        self.ul_src1 = zeromq.req_source(gr.sizeof_gr_complex, 1, 'tcp://127.0.0.1:2101', 100, False, -1)
        self.ul_src2 = zeromq.req_source(gr.sizeof_gr_complex, 1, 'tcp://127.0.0.1:2111', 100, False, -1)

        # UL sink to DU
        self.ul_snk = zeromq.rep_sink(gr.sizeof_gr_complex, 1, 'tcp://127.0.0.1:2001', 100, False, -1)

        # adder for UL (mix UE1 + UE2)
        self.adder = blocks.add_cc()

        # DL connections: broadcast to both UEs
        self.connect(self.dl_src, self.dl_snk1)
        self.connect(self.dl_src, self.dl_snk2)

        # UL connections: mix and send to DU
        self.connect(self.ul_src1, (self.adder, 0))
        self.connect(self.ul_src2, (self.adder, 1))
        self.connect(self.adder, self.ul_snk)

def main():
    tb = zmq_broker_2ue()
    tb.start()
    print("Broker running for 2 UE...")
    input("Press Enter to stop\n")
    tb.stop()
    tb.wait()

if __name__ == '__main__':
    main()
