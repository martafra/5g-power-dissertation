#!/usr/bin/env python3
# -*- coding: utf-8 -*-

#
# SPDX-License-Identifier: GPL-3.0
#
# headless N-UE extension of the official srsRAN Project multi_ue_scenario
# GNU Radio broker. Same topology as multi_ue_4ue.py (one shared throttle
# feeding N downlink branches, N uplink branches summed into one combiner)
# but generated programmatically so the UE count is a parameter instead of
# a fixed number of copy-pasted blocks.
# port layout, for UE index i (1-indexed):
#   DU   tx_port=2000  rx_port=2001
#   UEi  tx_port=2000+(i*100)+1  rx_port=2000+(i*100)
# e.g. UE1=2101/2100, UE2=2201/2200, ... UE16=3601/3600

import argparse
import signal

from gnuradio import blocks
from gnuradio import gr
from gnuradio import zeromq


class multi_ue_scenario_nue(gr.top_block):

    def __init__(self, n_ue=16, path_loss_db=None,
                 zmq_timeout=1000, zmq_hwm=10000,
                 slow_down_ratio=1, samp_rate=11520000):
        gr.top_block.__init__(self, "srsRAN_multi_UE_nue", catch_exceptions=True)

        if path_loss_db is None:
            # default progression mirrors the 4-UE broker's spirit (modest,
            # diversified, non-zero) extended to n_ue entries
            path_loss_db = [round(i * 2.0, 1) for i in range(n_ue)]
        if len(path_loss_db) != n_ue:
            raise ValueError(
                f"path_loss_db has {len(path_loss_db)} entries, expected {n_ue}")

        self.n_ue = n_ue
        self.path_loss_db = path_loss_db
        self.zmq_timeout = zmq_timeout
        self.zmq_hwm = zmq_hwm
        self.slow_down_ratio = slow_down_ratio
        self.samp_rate = samp_rate

        ##################################################
        # du source/sink (fixed, independent of n_ue)
        ##################################################
        self.zeromq_req_source_du = zeromq.req_source(
            gr.sizeof_gr_complex, 1, 'tcp://127.0.0.1:2000',
            self.zmq_timeout, False, self.zmq_hwm)
        self.zeromq_rep_sink_du = zeromq.rep_sink(
            gr.sizeof_gr_complex, 1, 'tcp://127.0.0.1:2001',
            self.zmq_timeout, False, self.zmq_hwm)

        # shared throttle on the DU downlink feed
        self.blocks_throttle_0 = blocks.throttle(
            gr.sizeof_gr_complex * 1,
            1.0 * self.samp_rate / (1.0 * self.slow_down_ratio), True)
        self.connect((self.zeromq_req_source_du, 0), (self.blocks_throttle_0, 0))

        # combiner for the shared uplink channel (vector length 1 = scalar
        # gr_complex stream; input count comes from how many branches
        # connect() into it below, not from this constructor argument)
        self.blocks_add_xx_0 = blocks.add_vcc(1)
        self.connect((self.blocks_add_xx_0, 0), (self.zeromq_rep_sink_du, 0))

        ##################################################
        # per-UE branches, generated programmatically
        ##################################################
        self.ue_req_sources = []
        self.ue_rep_sinks = []
        self.ue_mult_dl = []
        self.ue_mult_ul = []

        for i in range(1, n_ue + 1):
            tx_port = 2000 + i * 100 + 1  # UE uplink source port (UE tx -> broker)
            rx_port = 2000 + i * 100      # UE downlink sink port (broker -> UE rx)
            loss_db = self.path_loss_db[i - 1]

            req_source = zeromq.req_source(
                gr.sizeof_gr_complex, 1, f'tcp://127.0.0.1:{tx_port}',
                self.zmq_timeout, False, self.zmq_hwm)
            rep_sink = zeromq.rep_sink(
                gr.sizeof_gr_complex, 1, f'tcp://127.0.0.1:{rx_port}',
                self.zmq_timeout, False, self.zmq_hwm)

            mult_dl = blocks.multiply_const_cc(10 ** (-1.0 * loss_db / 20.0))
            mult_ul = blocks.multiply_const_cc(10 ** (-1.0 * loss_db / 20.0))

            # downlink: shared throttle -> per-UE path loss -> per-UE sink
            self.connect((self.blocks_throttle_0, 0), (mult_dl, 0))
            self.connect((mult_dl, 0), (rep_sink, 0))

            # uplink: per-UE source -> per-UE path loss -> shared combiner
            self.connect((req_source, 0), (mult_ul, 0))
            self.connect((mult_ul, 0), (self.blocks_add_xx_0, i - 1))

            self.ue_req_sources.append(req_source)
            self.ue_rep_sinks.append(rep_sink)
            self.ue_mult_dl.append(mult_dl)
            self.ue_mult_ul.append(mult_ul)


def parse_args():
    parser = argparse.ArgumentParser(
        description='headless N-UE GNU Radio broker for srsRAN ZMQ testing')
    parser.add_argument('--n-ue', type=int, default=16,
                         help='number of UEs (default: 16)')
    parser.add_argument('--path-loss', type=float, nargs='+', default=None,
                         help='space-separated path loss in dB per UE, '
                              'e.g. --path-loss 0 2 4 6. defaults to a '
                              '2 dB step progression starting at 0 if omitted')
    parser.add_argument('--zmq-timeout', type=float, default=1000,
                         help='ZMQ receive timeout in ms (default: 1000)')
    parser.add_argument('--zmq-hwm', type=int, default=10000,
                         help='ZMQ high water mark (default: 10000)')
    parser.add_argument('--slow-down-ratio', type=float, default=1,
                         help='time slow down ratio (default: 1, no '
                              'artificial slowdown)')
    parser.add_argument('--samp-rate', type=float, default=11520000,
                         help='sample rate in Hz (default: 11520000)')
    return parser.parse_args()


def main():
    args = parse_args()

    tb = multi_ue_scenario_nue(
        n_ue=args.n_ue,
        path_loss_db=args.path_loss,
        zmq_timeout=args.zmq_timeout,
        zmq_hwm=args.zmq_hwm,
        slow_down_ratio=args.slow_down_ratio,
        samp_rate=args.samp_rate)

    def sig_handler(sig=None, frame=None):
        tb.stop()
        tb.wait()

    signal.signal(signal.SIGINT, sig_handler)
    signal.signal(signal.SIGTERM, sig_handler)

    tb.start()
    tb.wait()


if __name__ == '__main__':
    main()
