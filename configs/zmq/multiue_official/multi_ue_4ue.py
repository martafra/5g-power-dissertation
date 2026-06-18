#!/usr/bin/env python3
# -*- coding: utf-8 -*-

#
# SPDX-License-Identifier: GPL-3.0
#
# headless 4-UE extension of the official srsRAN Project multi_ue_scenario
# GNU Radio broker. Based on multi_ue_scenario.py (3 UE), extended with a
# fourth UE branch and stripped of the Qt GUI, since this runs under
# xvfb-run with no interactive use.
#
# port layout (matches the conf files on the node):
#   DU   tx_port=2000  rx_port=2001
#   UE1  tx_port=2101  rx_port=2100
#   UE2  tx_port=2201  rx_port=2200
#   UE3  tx_port=2301  rx_port=2300
#   UE4  tx_port=2401  rx_port=2400

import argparse
import signal

from gnuradio import blocks
from gnuradio import gr
from gnuradio import zeromq


class multi_ue_scenario_4ue(gr.top_block):

    def __init__(self, ue1_path_loss_db=0, ue2_path_loss_db=10,
                 ue3_path_loss_db=20, ue4_path_loss_db=30,
                 slow_down_ratio=4, samp_rate=11520000):
        gr.top_block.__init__(self, "srsRAN_multi_UE_4ue", catch_exceptions=True)

        ##################################################
        # variables
        ##################################################
        self.zmq_timeout = 1000
        self.zmq_hwm = 1000
        self.ue1_path_loss_db = ue1_path_loss_db
        self.ue2_path_loss_db = ue2_path_loss_db
        self.ue3_path_loss_db = ue3_path_loss_db
        self.ue4_path_loss_db = ue4_path_loss_db
        self.slow_down_ratio = slow_down_ratio
        self.samp_rate = samp_rate

        ##################################################
        # blocks
        ##################################################

        # du downlink source: what the DU transmits
        self.zeromq_req_source_du = zeromq.req_source(
            gr.sizeof_gr_complex, 1, 'tcp://127.0.0.1:2000',
            self.zmq_timeout, False, self.zmq_hwm)

        # du uplink sink: combined uplink from all UEs, what the DU receives
        self.zeromq_rep_sink_du = zeromq.rep_sink(
            gr.sizeof_gr_complex, 1, 'tcp://127.0.0.1:2001',
            self.zmq_timeout, False, self.zmq_hwm)

        # per-UE uplink sources (what each UE transmits) and downlink sinks
        # (what each UE receives)
        self.zeromq_req_source_ue1 = zeromq.req_source(
            gr.sizeof_gr_complex, 1, 'tcp://127.0.0.1:2101',
            self.zmq_timeout, False, self.zmq_hwm)
        self.zeromq_rep_sink_ue1 = zeromq.rep_sink(
            gr.sizeof_gr_complex, 1, 'tcp://127.0.0.1:2100',
            self.zmq_timeout, False, self.zmq_hwm)

        self.zeromq_req_source_ue2 = zeromq.req_source(
            gr.sizeof_gr_complex, 1, 'tcp://127.0.0.1:2201',
            self.zmq_timeout, False, self.zmq_hwm)
        self.zeromq_rep_sink_ue2 = zeromq.rep_sink(
            gr.sizeof_gr_complex, 1, 'tcp://127.0.0.1:2200',
            self.zmq_timeout, False, self.zmq_hwm)

        self.zeromq_req_source_ue3 = zeromq.req_source(
            gr.sizeof_gr_complex, 1, 'tcp://127.0.0.1:2301',
            self.zmq_timeout, False, self.zmq_hwm)
        self.zeromq_rep_sink_ue3 = zeromq.rep_sink(
            gr.sizeof_gr_complex, 1, 'tcp://127.0.0.1:2300',
            self.zmq_timeout, False, self.zmq_hwm)

        self.zeromq_req_source_ue4 = zeromq.req_source(
            gr.sizeof_gr_complex, 1, 'tcp://127.0.0.1:2401',
            self.zmq_timeout, False, self.zmq_hwm)
        self.zeromq_rep_sink_ue4 = zeromq.rep_sink(
            gr.sizeof_gr_complex, 1, 'tcp://127.0.0.1:2400',
            self.zmq_timeout, False, self.zmq_hwm)

        # throttle on the DU downlink feed, shared by all four downlink branches
        self.blocks_throttle_0 = blocks.throttle(
            gr.sizeof_gr_complex * 1,
            1.0 * self.samp_rate / (1.0 * self.slow_down_ratio), True)

        # downlink path loss: DU signal attenuated per UE before reaching it
        self.blocks_mult_dl_ue1 = blocks.multiply_const_cc(
            10 ** (-1.0 * self.ue1_path_loss_db / 20.0))
        self.blocks_mult_dl_ue2 = blocks.multiply_const_cc(
            10 ** (-1.0 * self.ue2_path_loss_db / 20.0))
        self.blocks_mult_dl_ue3 = blocks.multiply_const_cc(
            10 ** (-1.0 * self.ue3_path_loss_db / 20.0))
        self.blocks_mult_dl_ue4 = blocks.multiply_const_cc(
            10 ** (-1.0 * self.ue4_path_loss_db / 20.0))

        # uplink path loss: each UE signal attenuated before being summed
        # into the shared uplink channel seen by the DU
        self.blocks_mult_ul_ue1 = blocks.multiply_const_cc(
            10 ** (-1.0 * self.ue1_path_loss_db / 20.0))
        self.blocks_mult_ul_ue2 = blocks.multiply_const_cc(
            10 ** (-1.0 * self.ue2_path_loss_db / 20.0))
        self.blocks_mult_ul_ue3 = blocks.multiply_const_cc(
            10 ** (-1.0 * self.ue3_path_loss_db / 20.0))
        self.blocks_mult_ul_ue4 = blocks.multiply_const_cc(
            10 ** (-1.0 * self.ue4_path_loss_db / 20.0))

        # combiner for the shared uplink channel. the add_vcc parameter is
        # the vector length (1 = scalar gr_complex stream), not the number
        # of input ports; the number of summed inputs is set by how many
        # connect() calls feed into it below, same as the original 3-UE graph
        self.blocks_add_xx_0 = blocks.add_vcc(1)

        ##################################################
        # connections
        ##################################################

        # downlink: DU -> throttle -> per-UE path loss -> per-UE sink
        self.connect((self.zeromq_req_source_du, 0), (self.blocks_throttle_0, 0))
        self.connect((self.blocks_throttle_0, 0), (self.blocks_mult_dl_ue1, 0))
        self.connect((self.blocks_throttle_0, 0), (self.blocks_mult_dl_ue2, 0))
        self.connect((self.blocks_throttle_0, 0), (self.blocks_mult_dl_ue3, 0))
        self.connect((self.blocks_throttle_0, 0), (self.blocks_mult_dl_ue4, 0))
        self.connect((self.blocks_mult_dl_ue1, 0), (self.zeromq_rep_sink_ue1, 0))
        self.connect((self.blocks_mult_dl_ue2, 0), (self.zeromq_rep_sink_ue2, 0))
        self.connect((self.blocks_mult_dl_ue3, 0), (self.zeromq_rep_sink_ue3, 0))
        self.connect((self.blocks_mult_dl_ue4, 0), (self.zeromq_rep_sink_ue4, 0))

        # uplink: per-UE source -> per-UE path loss -> combiner -> DU sink
        self.connect((self.zeromq_req_source_ue1, 0), (self.blocks_mult_ul_ue1, 0))
        self.connect((self.zeromq_req_source_ue2, 0), (self.blocks_mult_ul_ue2, 0))
        self.connect((self.zeromq_req_source_ue3, 0), (self.blocks_mult_ul_ue3, 0))
        self.connect((self.zeromq_req_source_ue4, 0), (self.blocks_mult_ul_ue4, 0))
        self.connect((self.blocks_mult_ul_ue1, 0), (self.blocks_add_xx_0, 0))
        self.connect((self.blocks_mult_ul_ue2, 0), (self.blocks_add_xx_0, 1))
        self.connect((self.blocks_mult_ul_ue3, 0), (self.blocks_add_xx_0, 2))
        self.connect((self.blocks_mult_ul_ue4, 0), (self.blocks_add_xx_0, 3))
        self.connect((self.blocks_add_xx_0, 0), (self.zeromq_rep_sink_du, 0))


def parse_args():
    parser = argparse.ArgumentParser(
        description='headless 4-UE GNU Radio broker for srsRAN ZMQ testing')
    parser.add_argument('--ue1-loss', type=float, default=0,
                         help='UE1 path loss in dB (default: 0)')
    parser.add_argument('--ue2-loss', type=float, default=10,
                         help='UE2 path loss in dB (default: 10)')
    parser.add_argument('--ue3-loss', type=float, default=20,
                         help='UE3 path loss in dB (default: 20)')
    parser.add_argument('--ue4-loss', type=float, default=30,
                         help='UE4 path loss in dB (default: 30)')
    parser.add_argument('--slow-down-ratio', type=float, default=4,
                         help='time slow down ratio (default: 4)')
    parser.add_argument('--samp-rate', type=float, default=11520000,
                         help='sample rate in Hz (default: 11520000)')
    return parser.parse_args()


def main():
    args = parse_args()

    tb = multi_ue_scenario_4ue(
        ue1_path_loss_db=args.ue1_loss,
        ue2_path_loss_db=args.ue2_loss,
        ue3_path_loss_db=args.ue3_loss,
        ue4_path_loss_db=args.ue4_loss,
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
