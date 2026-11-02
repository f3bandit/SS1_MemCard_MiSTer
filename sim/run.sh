#!/bin/sh
# SS1 Memory Card Tool. Copyright (C) 2026 f3bandit. MIT License (see LICENSE-MIT).
# Simulates the card reader against a modelled memory card (needs Icarus Verilog).
cd "$(dirname "$0")/.." && iverilog -g2012 -o sim/tb_ctrl.vvp sim/tb_ctrl.sv rtl/sio_byte.sv rtl/card_sector.sv rtl/mc_ctrl.sv && stdbuf -o0 vvp -n sim/tb_ctrl.vvp
