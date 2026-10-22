# hvu1_resize_pipe unit simulation (VCS)
# Usage:
#   make sim TEST=bypass_2x2
#   make sim TEST=stall_fetch STALL=1
#   make sim-all
#   make clean
#
# All generated artifacts go to out/

SIMDIR := $(abspath .)
OUT    := out
TEST   ?= bypass
STALL  ?= 0

VCS ?= vcs

VCS_FLAGS := -full64 -sverilog +v2k -timescale=1ns/1ps \
	-f filelist.f +incdir+. \
	-debug_access+all \
	-o $(OUT)/simv \
	-Mdir=$(OUT)/csrc

TESTS := \
	reset_idle \
	start_illegal_zero_dst \
	start_ignored_busy \
	two_frames \
	bypass_2x2 \
	bypass_1x1 \
	bypass_eol_last \
	near_identity \
	near_upscale_2to4 \
	near_downscale \
	near_round_half_up \
	near_clamp_edge \
	near_reserved_interp \
	bilin_2x2_to_4x4 \
	bilin_identity_frac0 \
	bilin_edge_dup_taps \
	bilin_alpha \
	stall_fetch \
	stall_csc \
	stall_cu \
	stall_all \
	idle_interp_quiet

STALL_TESTS := stall_fetch stall_csc stall_cu stall_all

.PHONY: all compile sim sim-all clean

all: sim

compile:
	mkdir -p $(OUT)
	$(VCS) $(VCS_FLAGS) -l $(OUT)/compile.log
	@for f in ucli.key vc_hdrs.h novas.rc novas.conf .vlogansetup.args .vlogansetup.env; do \
		if [ -e $$f ]; then mv $$f $(OUT)/; fi; \
	done

sim: compile
	cd $(OUT) && ./simv +TEST=$(TEST) +STALL=$(STALL) -l sim_$(TEST).log

sim-all: compile
	@fail=0; \
	for t in $(TESTS); do \
		echo "==== $$t STALL=0 ===="; \
		if ! ( cd $(OUT) && ./simv +TEST=$$t +STALL=0 -l sim_$$t.log ); then \
			echo "FAIL $$t"; fail=1; \
		fi; \
	done; \
	for t in $(STALL_TESTS); do \
		echo "==== $$t STALL=1 ===="; \
		if ! ( cd $(OUT) && ./simv +TEST=$$t +STALL=1 -l sim_$${t}_stall.log ); then \
			echo "FAIL $$t STALL=1"; fail=1; \
		fi; \
	done; \
	if [ $$fail -ne 0 ]; then echo "sim-all FAILED"; exit 1; fi; \
	echo "sim-all PASSED"

clean:
	rm -rf $(OUT)
