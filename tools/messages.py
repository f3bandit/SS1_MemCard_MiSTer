#!/usr/bin/env python3
"""Writes the screen texts: rtl/messages.hex (48 characters per message) and rtl/messages.vh
(their numbers). The core's font has capitals, digits and punctuation only."""
import os
W = 64
# controller test: the button names, and which bit of the report each word lights up with
# (bits: 0 Select 1 L3 2 R3 3 Start 4 Up 5 Right 6 Down 7 Left 8 L2 9 R2 10 L1 11 R1
#        12 Triangle 13 Circle 14 Cross 15 Square)
BTN_WORDS = [
    [("UP", 4), ("DOWN", 6), ("LEFT", 7), ("RIGHT", 5), ("TRIANGLE", 12), ("CIRCLE", 13), ("CROSS", 14), ("SQUARE", 15)],
    [("L1", 10), ("L2", 8), ("R1", 11), ("R2", 9), ("L3", 1), ("R3", 2), ("SELECT", 0), ("START", 3)],
]
BTN_ROWS, BTN_COLS = [], []
for words in BTN_WORDS:
    row, cols = "", []
    for w, bit in words:
        if row:
            row += "  "
        for c in w:
            cols.append((len(row), bit))
            row += c
    BTN_ROWS.append(row)
    BTN_COLS.append(cols)

# the sticks row; the numbers go in the gaps after the letters (3 digits each)
STICKS = "STICKS   LEFT X      Y        RIGHT X      Y"
STICK_COLS = [i + 2 for i, c in enumerate(STICKS) if c in "XY" and STICKS[i-1] == " "]
assert len(STICK_COLS) == 4
# the wiring check row: pins pulled low (USER_IN bits as a number) and what answered on pin 6
WIRE = "PINS LOW: P1      P2      PIN6      PIN6 ID"
WIRE_COLS = [WIRE.index(" P1") + 4, WIRE.index(" P2") + 4, WIRE.index(" PIN6 ") + 6, WIRE.index("PIN6 ID") + 8]

MSGS = [
    ("TITLE",      "SS1 MEMORY CARD TOOL"),
    ("RULE",       "-" * 46),
    ("CARD",       "CARD:"),
    ("FILE",       "FILE:"),
    ("JOB",        "JOB:"),
    ("C_NONE",     "NONE - PUT A CARD IN FRONT PORT 1"),
    ("C_FMT",      "FOUND"),
    ("C_BLANK",    "FOUND, NOT FORMATTED"),
    ("F_NONE",     "NONE - MOUNT A CARD FILE IN THE MENU"),
    ("F_OK",       "READY (128 KB)"),
    ("F_BAD",      "WRONG SIZE - A CARD FILE IS 128 KB"),
    ("J_NONE",     "-"),
    ("J_BACKUP",   "BACK UP THE CARD TO THE FILE"),
    ("J_VERIFY",   "CHECK THE CARD AGAINST THE FILE"),
    ("J_WRITE",    "WRITE THE FILE TO THE CARD"),
    ("J_TOOL",     "    (SENT BY SS1 TOOL)"),
    ("J_STEP1",    "STEP 1 OF 2: READING - NOTHING IS WRITTEN YET"),
    ("J_STEP2",    "STEP 2 OF 2: WRITING THE CHANGES TO THE CARD"),
    ("P_IDLE",     "WAITING"),
    ("P_LOAD",     "LOADING THE FILE"),
    ("P_READ",     "READING SECTOR      / 1024"),
    ("P_WRITE",    "WRITING SECTOR      / 1024"),
    ("P_SAVE",     "SAVING THE FILE"),
    ("P_REPORT",   "WRITING THE REPORT"),
    ("P_DONE",     "FINISHED"),
    ("L_OK",       "READ OK"),
    ("L_RETRY",    "NEEDED A RETRY"),
    ("L_FAIL",     "FAILED"),
    ("L_DIFF",     "DIFFERS FROM FILE"),
    ("L_NONE",     "NOT READ YET"),
    ("L_WRITTEN",  "WRITTEN AND CHECKED"),
    ("N_OK",       "OK"),
    ("N_RETRY",    "RETRIED"),
    ("N_FAIL",     "FAILED"),
    ("N_DIFF",     "DIFFERENT"),
    ("N_WRITTEN",  "WRITTEN"),
    ("R_NONE",     ""),
    ("R_OK",       "BACKUP COMPLETE"),
    ("R_OK_RETRY", "BACKUP COMPLETE - SOME SECTORS NEEDED RETRIES"),
    ("R_FAILED",   "SECTORS FAILED - THE FILE WAS NOT CHANGED"),
    ("R_NOCARD",   "STOPPED - NO CARD IN FRONT PORT 1"),
    ("R_DIFFER",   "THE CARD AND THE FILE ARE DIFFERENT"),
    ("R_BADFILE",  "THE FILE ISN'T A 128 KB CARD FILE"),
    ("R_READONLY", "THE FILE IS READ ONLY - NOTHING SAVED"),
    ("R_SAVED_BAD","SAVED - BUT SOME SECTORS FAILED"),
    ("R_V_OK",     "THE CARD MATCHES THE FILE"),
    ("V_FAILED",   "SECTORS FAILED - CHECK NOT COMPLETE"),
    ("W_OK",       "THE CARD WAS UPDATED AND CHECKED"),
    ("W_FAILED",   "WRITING FAILED - RESTORE THE BACKUP IN SS1 TOOL"),
    ("J_PAD",      "CONTROLLER TEST"),
    ("P_PAD",      "CONTROLLER TEST - BOTH FRONT PORTS"),
    ("PD_P1",      "PORT 1:"),
    ("PD_P2",      "PORT 2:"),
    ("PD_NONE",    "NONE - PLUG ONE INTO THIS PORT"),
    ("PD_DIG",     "DIGITAL PAD"),
    ("PD_DS",      "ANALOG (DUALSHOCK)"),
    ("PD_ANA",     "ANALOG JOYSTICK"),
    ("PD_NEG",     "NEGCON"),
    ("PD_MOUSE",   "MOUSE"),
    ("PD_GUN",     "LIGHT GUN"),
    ("PD_OTHER",   "OTHER CONTROLLER"),
    ("PD_B1",      BTN_ROWS[0]),
    ("PD_B2",      BTN_ROWS[1]),
    ("PD_STICKS",  STICKS),
    ("PD_MC",      "MEMORY CARD:"),
    ("PD_WIRE",    WIRE),
    ("PD_MC_NO",   "NONE"),
    ("PD_MC_YES",  "YES"),
    ("PD_MC_BLANK","YES, NOT FORMATTED"),
    ("ST_START",   "STARTING..."),
    ("H_BUSY",     "DON'T REMOVE THE CARD"),
    ("H_IDLE",     "PRESS THE MENU BUTTON FOR OPTIONS OR TO EXIT"),
]
assert len(MSGS) <= 128
here = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(here, "..", "rtl", "messages.hex"), "w") as f:
    for _, t in MSGS:
        assert len(t) <= 60 and all(32 <= ord(c) < 96 for c in t), t
        t = t.ljust(W)
        for c in t:
            f.write(f"{ord(c)-32:02x}\n")
    for _ in range((128 - len(MSGS)) * W):
        f.write("00\n")
with open(os.path.join(here, "..", "rtl", "padcols.vh"), "w") as f:
    f.write("// generated by tools/messages.py: controller test, which bit lights each column (0 = none)\n")
    f.write("function [4:0] btn_bit(input r, input [5:0] col);\n\tbegin\n\t\tbtn_bit = 0;\n\t\tcase ({r, col})\n")
    for r, cols in enumerate(BTN_COLS):
        for col, bit in cols:
            f.write(f"\t\t\t{{1'b{r}, 6'd{col}}}: btn_bit = 5'd{bit + 1};\n")
    f.write("\t\t\tdefault: ;\n\t\tendcase\n\tend\nendfunction\n")
    f.write("// sticks row: where each value's first digit goes (columns counted from the message start)\n")
    for n, c in zip(["SX_LX", "SX_LY", "SX_RX", "SX_RY"], STICK_COLS):
        f.write(f"localparam {n} = {c};\n")
    for n, c in zip(["WX_P1", "WX_P2", "WX_P6", "WX_ID"], WIRE_COLS):
        f.write(f"localparam {n} = {c};\n")
with open(os.path.join(here, "..", "rtl", "messages.vh"), "w") as f:
    f.write("// generated by tools/messages.py\n")
    for i, (n, _) in enumerate(MSGS):
        f.write(f"localparam M_{n} = 7'd{i};\n")
print(len(MSGS), "messages")
