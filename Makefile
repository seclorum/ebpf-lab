#
# Purpose: Provide Instrumentation of IPC occurring on multiple domain socket filenodes in /tmp, e.g.
#
#  /tmp/(controld/streamd/utild)=
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
SOCKETS := /tmp/control0 /tmp/stream0 /tmp/util0
DAEMONS := controld streamd utild
LOG_DIR := ./ipc_logs
TIMESTAMP := $(shell date +%Y%m%d_%H%M%S)


# =============================================
# Mockup: Example daemons using IPC in /tmp/
# =============================================
CC = gcc
CFLAGS = -Wall -Wextra -O2 -g
LDFLAGS =

# Create log directory
$(LOG_DIR):
	mkdir -p $(LOG_DIR)

controld: controld.o
	$(CC) $(CFLAGS) -o controld controld.o $(LDFLAGS)

streamd: streamd.o
	$(CC) $(CFLAGS) -o streamd streamd.o $(LDFLAGS)

utild: utild.o
	$(CC) $(CFLAGS) -o utild utild.o $(LDFLAGS)

%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@

all-daemons: controld streamd utild

run: all-daemons
	./controld

.PHONY: all-daemons run

# =============================================
# Phase 1: Reconnaissance
# =============================================
.PHONY: recon
recon: $(LOG_DIR)
	@echo "=== Phase 1: Reconnaissance ==="
	@echo "Listing sockets and processes..."
	lsof +E -U | grep -E '/tmp/(control|stream|util)0' | tee $(LOG_DIR)/recon_lsof_$(TIMESTAMP).log
	ss -lxp | grep -E 'control|stream|util' | tee -a $(LOG_DIR)/recon_ss_$(TIMESTAMP).log
	@echo "Unix sockets:"
	cat /proc/net/unix | grep -E 'control|stream|util' | tee $(LOG_DIR)/recon_unix_$(TIMESTAMP).log
	@ps aux | grep -E '$(DAEMONS)' | grep -v grep | tee $(LOG_DIR)/recon_ps_$(TIMESTAMP).log
	@echo "Recon complete. Logs in $(LOG_DIR)/"

# =============================================
# Phase 2: Passive Kernel Instrumentation (eBPF)
# =============================================
.PHONY: ebpf unixdump bpftrace
ebpf: unixdump bpftrace

unixdump: $(LOG_DIR)
	@echo "=== Phase 2: unixdump (eBPF) ==="
	@if [ ! -d unixdump ]; then \
		echo "Cloning unixdump..."; \
		git clone https://github.com/nccgroup/unixdump.git || echo "Already cloned or failed"; \
	fi
	@cd unixdump && make || echo "Build may require manual steps"
	@echo "Run manually for full capture (example):"
	@echo "sudo ./unixdump/unixdump -s '$(SOCKETS)' -b -o $(LOG_DIR)/unixdump_$(TIMESTAMP).pcapng"
	@echo "Or with hex: sudo ./unixdump/unixdump -s '$(SOCKETS)' | tee $(LOG_DIR)/unixdump_$(TIMESTAMP).log"

bpftrace: $(LOG_DIR)
	@echo "=== Phase 2: bpftrace scripts ==="
	@cat > $(LOG_DIR)/bpf_connect.bt << 'EOF'
	tracepoint:syscalls:sys_enter_connect,
	tracepoint:syscalls:sys_enter_accept4 {
		if (str(args->addr) ~ /control0|stream0|util0/) {
			printf("[%s] %s PID:%d COMM:%s\n", strftime("%H:%M:%S"), probe, pid, comm);
		}
	}
	EOF
	@cat > $(LOG_DIR)/bpf_data.bt << 'EOF'
	kprobe:unix_stream_sendmsg,
	kprobe:unix_dgram_sendmsg,
	kprobe:unix_stream_recvmsg {
		$len = arg2;
		printf("[%s] %s PID:%d COMM:%s len:%d\n", strftime("%H:%M:%S"), probe, pid, comm, $len);
	}
	EOF
	@echo "bpftrace scripts written to $(LOG_DIR)/"
	@echo "Usage: sudo bpftrace $(LOG_DIR)/bpf_data.bt"

# =============================================
# Phase 3: Tap/Proxy Techniques
# =============================================
.PHONY: tap socat-tap
tap: socat-tap

socat-tap: $(LOG_DIR)
	@echo "=== Phase 3: Socat Tap/Proxy ==="
	@for s in $(SOCKETS); do \
		base=$$(basename $$s); \
		real="$${s}.real"; \
		if [ -S "$$s" ] && [ ! -S "$$real" ]; then \
			echo "Tapping $$s -> $$real"; \
			sudo mv "$$s" "$$real" || echo "Move failed for $$s"; \
			sudo socat UNIX-LISTEN:"$$s",mode=777,reuseaddr,fork \
				UNIX-CONNECT:"$$real" -x -v \
				> $(LOG_DIR)/tap_$${base}_$(TIMESTAMP).log 2>&1 & \
			echo "$$!" > $(LOG_DIR)/tap_$${base}.pid; \
		fi; \
	done
	@echo "Socat taps started. Check logs in $(LOG_DIR)/"

# =============================================
# Phase 4: Holistic Integration & Analysis
# =============================================
.PHONY: integrate analysis
integrate: recon ebpf
	@echo "=== Phase 4: Integration ==="
	@echo "Starting combined observation..."
	@sudo bpftrace -c "sleep 5" $(LOG_DIR)/bpf_data.bt > $(LOG_DIR)/integrated_$(TIMESTAMP).log 2>&1 &
	@echo "Integration scripts launched. Use 'make analysis' for processing."

analysis: $(LOG_DIR)
	@echo "=== Phase 4: Analysis ==="
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
	rm -f *.o controld streamd utild /tmp/controld /tmp/streamd /tmp/utild /tmp/streamd.log

stop-taps:
	@echo "Stopping taps..."
	@for pidfile in $(LOG_DIR)/*.pid; do \
		if [ -f $$pidfile ]; then \
			sudo kill $$(cat $$pidfile) 2>/dev/null || true; \
		fi; \
	done
	@echo "Restore original sockets manually if needed: mv /tmp/*.real /tmp/*0"

help:
	@echo "Available targets:"
	@echo "  recon		 - Phase 1: Discovery"
	@echo "  ebpf		 - Phase 2: eBPF (unixdump + bpftrace)"
	@echo "  tap		 - Phase 3: Socat proxies"
	@echo "  integrate	 - Phase 4: Combined setup"
	@echo "  analysis	 - Phase 4: Log correlation & hex"
	@echo "  clean		 - Remove generated files"
	@echo "  stop-taps	 - Kill running socat taps"
	@echo "  all		 - recon + ebpf"

all: controld streamd utild recon ebpf integrate

# End of Makefile
