#
# Purpose: Provide Instrumentation of IPC occurring on multiple domain socket filenodes in /tmp/ebpf_lab, e.g.
#
#  /tmp/ebpf_lab/(controld/streamd/utild)=
#
# Targets are intended for an analysis workflow 
#
# Utilises proxy/tap techniques as well as passive eBPF rules.
#
# Proxy/tap may introduce latency!  eBPF, not so much.
#
# Run with: make recon, make ebpf, make tap, make integrate, etc.
#
# Requires root/sudo for most instrumentation steps.
#
#

SHELL := /bin/bash
SOCKETS := /tmp/ebpf_lab/controld /tmp/ebpf_lab/streamd /tmp/ebpf_lab/utild
DAEMONS := controld streamd utild
LOG_DIR := /tmp/ebpf_lab/ipc_logs
TIMESTAMP := $(shell date +%Y%m%d_%H%M%S)


# =============================================
# Mockup: Example daemons using IPC in /tmp/ebpf_lab/
# =============================================
CC = gcc
CFLAGS = -Wall -Wextra -O2 -g
LDFLAGS =

# Create log directory
$(LOG_DIR):
	mkdir -p $(LOG_DIR) /tmp/ebpf_lab/

controld: controld.o
	$(CC) $(CFLAGS) -o controld controld.o $(LDFLAGS)

streamd: streamd.o
	$(CC) $(CFLAGS) -o streamd streamd.o $(LDFLAGS)

utild: utild.o
	$(CC) $(CFLAGS) -o utild utild.o $(LDFLAGS)

%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@

all-daemons: controld streamd utild

run: $(LOG_DIR) all-daemons
	./controld

.PHONY: $(LOG_DIR) all-daemons run

# =============================================
# Reconnaissance
# =============================================
.PHONY: recon
recon: $(LOG_DIR)
	@echo "=== Reconnaissance ==="
	@echo "Listing sockets and processes..."
	lsof +E -U | grep -E '/tmp/ebpf_lab/(control|stream|util)0' | tee $(LOG_DIR)/recon_lsof_$(TIMESTAMP).log
	ss -lxp | grep -E 'control|stream|util' | tee -a $(LOG_DIR)/recon_ss_$(TIMESTAMP).log
	@echo "Unix sockets:"
	cat /proc/net/unix | grep -E 'control|stream|util' | tee $(LOG_DIR)/recon_unix_$(TIMESTAMP).log
	@ps aux | grep -E '$(DAEMONS)' | grep -v grep | tee $(LOG_DIR)/recon_ps_$(TIMESTAMP).log
	@echo "Recon complete. Logs in $(LOG_DIR)/"

# =============================================
# Passive Kernel Instrumentation (eBPF)
# =============================================
.PHONY: ebpf bpftrace
ebpf: bpftrace

bpftrace: $(LOG_DIR)
	@echo "=== bpftrace scripts ==="
	@sudo bpftrace bpf_data.bt

# =============================================
# Tap/Proxy Techniques
# =============================================
.PHONY: tap socat-tap
tap: socat-tap

socat-tap: $(LOG_DIR)
	@echo "=== Socat Tap/Proxy ==="
	@for s in $(SOCKETS); do \
		base=$$(basename $$s); \
		real="$${s}.real"; \
		echo "Attempting tap of $$s (real: $$real)";\
		if [ -S "$$s" ] && [ ! -S "$$real" ]; then \
			echo "Tapping $$s -> $$real"; \
			sudo mv "$$s" "$$real" || echo "Move failed for $$s"; \
			echo socat -x -v UNIX-LISTEN:"$$s",mode=777,reuseaddr,unlink-early,fork \
				UNIX-CONNECT:"$$real"; \
			sudo socat -x -v UNIX-LISTEN:"$$s",mode=777,reuseaddr,unlink-early,fork \
				UNIX-CONNECT:"$$real" \
				> $(LOG_DIR)/tap_$${base}_$(TIMESTAMP).log 2>&1 & \
			echo "$$!" > $(LOG_DIR)/tap_$${base}.pid; \
		else \
			echo "Not tapping $$s (real: $$real)";\
		fi; \
	done
	@echo "Socat taps started. Check logs in $(LOG_DIR)/"

stop-taps:
	@echo "Stopping taps..."
	@for pidfile in $(LOG_DIR)/*.pid; do \
		if [ -f $$pidfile ]; then \
			echo "**** killing $$(cat $$pidfile) ..."; \
			sudo kill $$(cat $$pidfile) 2>/dev/null || true; \
		fi; \
	done
	@echo "Restore original sockets manually if needed: mv /tmp/ebpf_lab/*.real /tmp/ebpf_lab/*0"

# =============================================
# Holistic Integration & Analysis
# =============================================
.PHONY: integrate analysis
integrate: recon ebpf
	@echo "=== Integration ==="
	@echo "Starting combined observation..."
	@sudo bpftrace -c "sleep 5" $(LOG_DIR)/bpf_data.bt > $(LOG_DIR)/integrated_$(TIMESTAMP).log 2>&1 &
	@echo "Integration scripts launched. Use 'make analysis' for processing."

analysis: $(LOG_DIR)
	@echo "=== Analysis ==="
	@echo "Correlating logs..."
	@find $(LOG_DIR) -name "*.log" -exec echo "=== {} ===" \; -exec head -n 20 {} \; | tee $(LOG_DIR)/summary_$(TIMESTAMP).txt
	@echo "Hex dump example (first 10 lines of data logs):"
	@find $(LOG_DIR) -name "*tap*" -o -name "*dump*" | head -3 | xargs -I{} sh -c 'echo "{}:"; head -10 {} | xxd | head -5' || true
	@echo "Analysis summary in $(LOG_DIR)/summary_*.txt"

# =============================================
# Utility Targets
# =============================================
.PHONY: clean stop-taps help all
clean:
	rm -rf $(LOG_DIR)/*.bt $(LOG_DIR)/*.pid
	@echo "Cleaned logs and scripts (sockets untouched)"
	rm -f *.o controld streamd utild /tmp/ebpf_lab/controld /tmp/ebpf_lab/streamd /tmp/ebpf_lab/utild /tmp/ebpf_lab/streamd.log \
			/tmp/ebpf_lab/controld.real /tmp/ebpf_lab/streamd.real /tmp/ebpf_lab/utild.real

control-start:
	 @echo -n "start" | socat - UNIX-CONNECT:/tmp/ebpf_lab/controld

control-stop:
	 @echo -n "stop" | socat - UNIX-CONNECT:/tmp/ebpf_lab/controld

control-faster:
	 @echo -n "faster" | socat - UNIX-CONNECT:/tmp/ebpf_lab/controld

control-slower:
	 @echo -n "slower" | socat - UNIX-CONNECT:/tmp/ebpf_lab/controld

monitor-logs:
	tail -F -n 100 $(LOG_DIR)/* 2>/dev/null | awk '{ printf "\033[1;36m%s\033[0m: %s\n", FILENAME, $$0 }'

help:
	@echo "Available targets:"
	@echo "  recon		 - Discovery"
	@echo "  ebpf		 - eBPF (bpftrace)"
	@echo "  tap		 - Socat proxies"
	@echo "  integrate	 - Combined setup"
	@echo "  analysis	 - Log correlation & hex"
	@echo "  clean		 - Remove generated files"
	@echo "  stop-taps	 - Kill running socat taps"
	@echo "  all		 - recon + ebpf"

all: controld streamd utild recon ebpf integrate

# End of Makefile
