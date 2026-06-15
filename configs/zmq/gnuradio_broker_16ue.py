#!/usr/bin/env python3
from gnuradio import gr, zeromq, blocks

class zmq_broker(gr.top_block):
    def __init__(self):
        gr.top_block.__init__(self, "ZMQ Broker 16 UE")

        self.dl_src = zeromq.req_source(gr.sizeof_gr_complex, 1, 'tcp://127.0.0.1:2000', 100, False, -1)
        self.ul_snk = zeromq.rep_sink(gr.sizeof_gr_complex, 1, 'tcp://127.0.0.1:2001', 100, False, -1)
        self.adder = blocks.add_cc(1)

        dl_ports = [2100, 2110, 2120, 2130, 2140, 2150, 2160, 2170, 2180, 2190, 2200, 2210, 2220, 2230, 2240, 2250]
        ul_ports = [2101, 2111, 2121, 2131, 2141, 2151, 2161, 2171, 2181, 2191, 2201, 2211, 2221, 2231, 2241, 2251]

        for i, port in enumerate(dl_ports):
            snk = zeromq.rep_sink(gr.sizeof_gr_complex, 1, f'tcp://127.0.0.1:{port}', 100, False, -1)
            self.connect(self.dl_src, snk)

        for i, port in enumerate(ul_ports):
            src = zeromq.req_source(gr.sizeof_gr_complex, 1, f'tcp://127.0.0.1:{port}', 100, False, -1)
            self.connect(src, (self.adder, i))

        self.connect(self.adder, self.ul_snk)

def main():
    tb = zmq_broker()
    tb.start()
    print("Broker running for 16 UE(s)...")
    input("Press Enter to stop\n")
    tb.stop()
    tb.wait()

if __name__ == '__main__':
    main()
