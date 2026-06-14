# Surface ACPI Quell — Makefile
obj-m += surface_fixed_event_quell.o

KDIR  := /lib/modules/$(shell uname -r)/build
PWD   := $(shell pwd)

DESTDIR        ?=
PREFIX         ?= /usr/local
UNITDIR        ?= /etc/systemd/system
MODULES_LOAD_D ?= /etc/modules-load.d
JOURNALD_CONF_D ?= /etc/systemd/journald.conf.d
ICON_DIR       ?= $(PREFIX)/share/icons/hicolor
AUTOSTART_DIR  ?= /etc/xdg/autostart

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
	$(RM) Module.symvers modules.order

# ── Kernel module ──────────────────────────────────────────────────────────

install-module:
	$(MAKE) -C $(KDIR) M=$(PWD) modules_install
	depmod -a
	# Also copy to a known location for the watcher fallback
	install -Dm644 surface_fixed_event_quell.ko \
		$(DESTDIR)$(PREFIX)/lib/surface-acpi-quell/surface_fixed_event_quell.ko

uninstall-module:
	$(RM) -r $(DESTDIR)/lib/modules/$(shell uname -r)/extra/surface_fixed_event_quell*
	$(RM) -r $(DESTDIR)$(PREFIX)/lib/surface-acpi-quell
	depmod -a

# ── Watcher script ─────────────────────────────────────────────────────────

install-watcher:
	install -Dm755 watcher.sh $(DESTDIR)$(PREFIX)/bin/surface-acpi-watcher
	install -Dm644 surface-acpi-watcher.service $(DESTDIR)$(UNITDIR)/surface-acpi-watcher.service
	install -Dm644 surface-acpi-watcher.timer $(DESTDIR)$(UNITDIR)/surface-acpi-watcher.timer

uninstall-watcher:
	$(RM) $(DESTDIR)$(PREFIX)/bin/surface-acpi-watcher
	$(RM) $(DESTDIR)$(UNITDIR)/surface-acpi-watcher.service
	$(RM) $(DESTDIR)$(UNITDIR)/surface-acpi-watcher.timer

# ── Tray indicator ─────────────────────────────────────────────────────────

install-indicator:
	install -Dm755 indicator.py $(DESTDIR)$(PREFIX)/bin/surface-acpi-indicator
	install -Dm644 surface-acpi-indicator.desktop $(DESTDIR)$(AUTOSTART_DIR)/surface-acpi-indicator.desktop
	for res in scalable 22x22; do \
		for state in ok warning critical unknown; do \
			install -Dm644 icons/surface-acpi-$$state.svg \
				$(DESTDIR)$(ICON_DIR)/$$res/status/surface-acpi-$$state.svg; \
		done; \
	done
	-gtk-update-icon-cache $(DESTDIR)$(ICON_DIR) 2>/dev/null; true

uninstall-indicator:
	$(RM) $(DESTDIR)$(PREFIX)/bin/surface-acpi-indicator
	$(RM) $(DESTDIR)$(AUTOSTART_DIR)/surface-acpi-indicator.desktop
	for res in scalable 22x22; do \
		for state in ok warning critical unknown; do \
			$(RM) $(DESTDIR)$(ICON_DIR)/$$res/status/surface-acpi-$$state.svg; \
		done; \
	done
	-gtk-update-icon-cache $(DESTDIR)$(ICON_DIR) 2>/dev/null; true

# ── Config files ───────────────────────────────────────────────────────────

install-config:
	install -Dm644 modules-load.d-surface_fixed_event_quell.conf \
		$(DESTDIR)$(MODULES_LOAD_D)/surface_fixed_event_quell.conf
	install -Dm644 journald-99-acpi-rate-limit.conf \
		$(DESTDIR)$(JOURNALD_CONF_D)/99-acpi-rate-limit.conf

uninstall-config:
	$(RM) $(DESTDIR)$(MODULES_LOAD_D)/surface_fixed_event_quell.conf
	$(RM) $(DESTDIR)$(JOURNALD_CONF_D)/99-acpi-rate-limit.conf

# ── All-in-one ─────────────────────────────────────────────────────────────

install-verify:
	install -Dm755 surface-acpi-verify.sh $(DESTDIR)$(PREFIX)/bin/surface-acpi-verify
	install -Dm644 surface-acpi-verify.service $(DESTDIR)$(UNITDIR)/surface-acpi-verify.service

uninstall-verify:
	$(RM) $(DESTDIR)$(PREFIX)/bin/surface-acpi-verify
	$(RM) $(DESTDIR)$(UNITDIR)/surface-acpi-verify.service

install-kernel-hook:
	install -Dm755 99-surface-acpi-quell.install $(DESTDIR)/etc/kernel/install.d/99-surface-acpi-quell.install

uninstall-kernel-hook:
	$(RM) $(DESTDIR)/etc/kernel/install.d/99-surface-acpi-quell.install

install-docs:
	install -Dm644 README.md $(DESTDIR)$(PREFIX)/share/doc/surface-acpi-quell/README.md
	install -Dm644 LICENSE $(DESTDIR)$(PREFIX)/share/doc/surface-acpi-quell/LICENSE

uninstall-docs:
	$(RM) -r $(DESTDIR)$(PREFIX)/share/doc/surface-acpi-quell

install: install-module install-watcher install-indicator install-config install-docs install-verify install-kernel-hook
	-systemctl daemon-reload 2>/dev/null; true
	-systemctl enable --now surface-acpi-watcher.timer 2>/dev/null; true
	-systemctl enable surface-acpi-verify.service 2>/dev/null; true
	@echo "✅ surface-acpi-quell installed!"
	@echo "   Reboot or: sudo modprobe surface_fixed_event_quell"
	@echo "   Watcher running every 60s"
	@echo "   Boot-time verification enabled"
	@echo "   Kernel update hook installed"

uninstall: uninstall-module uninstall-watcher uninstall-indicator uninstall-config uninstall-docs uninstall-verify uninstall-kernel-hook
	-systemctl disable --now surface-acpi-watcher.timer 2>/dev/null; true
	-systemctl disable surface-acpi-verify.service 2>/dev/null; true
	-systemctl daemon-reload 2>/dev/null; true
	@echo "🗑️  surface-acpi-quell uninstalled"

.PHONY: all clean install-module uninstall-module \
	install-watcher uninstall-watcher \
	install-indicator uninstall-indicator \
	install-config uninstall-config \
	install uninstall load unload

load:
	sudo modprobe surface_fixed_event_quell

unload:
	sudo rmmod surface_fixed_event_quell
