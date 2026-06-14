# Fedora / RHEL / COPR spec file for surface-acpi-quell
# Build: rpmbuild -ba dist/surface-acpi-quell.spec

%global pkgname surface-acpi-quell
%global pkgver 1.1.0

Name:           surface-acpi-quell
Version:        %{pkgver}
Release:        1%{?dist}
Summary:        Suppress broken ACPI interrupts on Microsoft Surface laptops

License:        MIT
URL:            https://github.com/aaaronmiller/surface-acpi-quell
Source0:        %{url}/archive/v%{version}/%{name}-%{version}.tar.gz

BuildRequires:  make, gcc, kernel-devel, python3-devel, desktop-file-utils
Requires:       python3-gobject, libappindicator-gtk3, gtk3
Recommends:     gnome-shell-extension-appindicator

%description
Surface firmware emits ~227,000 unnecessary ACPI interrupts per second —
GPEs and fixed events that the Linux kernel can't handle. This floods the
CPU, spins up fans, burns NVMe writes, and drains battery.

Surface ACPI Quell kills the storm at three layers:
1. Kernel parameter acpi_mask_gpe blocks problem GPEs
2. Kernel module masks the ACPI SCI (IRQ 9)
3. Watcher daemon auto-repairs and notifies on failure

%prep
%setup -q

%build
make %{?_smp_mflags}

%install
make DESTDIR=%{buildroot} install
install -Dm644 config/surface-acpi-quell.conf \
    %{buildroot}%{_sysconfdir}/surface-acpi-quell/config.conf

%files
%license LICENSE
%doc README.md ROADMAP.md
%dir %{_sysconfdir}/surface-acpi-quell/
%config(noreplace) %{_sysconfdir}/surface-acpi-quell/config.conf
%{_bindir}/surface-acpi-watcher
%{_bindir}/surface-acpi-indicator
%{_bindir}/surface-acpi-verify
%{_unitdir}/surface-acpi-watcher.service
%{_unitdir}/surface-acpi-watcher.timer
%{_unitdir}/surface-acpi-verify.service
%dir /etc/kernel/install.d/
/etc/kernel/install.d/99-surface-acpi-quell.install
%dir /etc/modules-load.d/
%config(noreplace) /etc/modules-load.d/surface_fixed_event_quell.conf
%config(noreplace) %{_sysconfdir}/systemd/journald.conf.d/99-acpi-rate-limit.conf
%dir /usr/local/lib/surface-acpi-quell/
%{_prefix}/lib/surface-acpi-quell/surface_fixed_event_quell.ko
%{_prefix}/share/doc/surface-acpi-quell/*
%{_prefix}/share/icons/hicolor/scalable/status/surface-acpi-*.svg
%{_prefix}/share/icons/hicolor/22x22/status/surface-acpi-*.svg
%dir /etc/xdg/autostart/
/etc/xdg/autostart/surface-acpi-indicator.desktop

%post
%systemd_post surface-acpi-watcher.timer
%systemd_post surface-acpi-verify.service
depmod -a 2>/dev/null || :
gtk-update-icon-cache %{_prefix}/share/icons/hicolor/ 2>/dev/null || :

%preun
%systemd_preun surface-acpi-watcher.timer
%systemd_preun surface-acpi-verify.service

%postun
%systemd_postun surface-acpi-watcher.timer
%systemd_postun surface-acpi-verify.service
depmod -a 2>/dev/null || :

%changelog
* Sat Jun 13 2026 Barnacle O'Byte <barnacle@o-byte.sea> - 1.1.0-1
- Auto-detect problem GPEs
- Config file support
- Non-Surface hardware safety check
- Graceful degradation monitoring
* Fri Jun 12 2026 Barnacle O'Byte <barnacle@o-byte.sea> - 1.0.0-1
- Initial release
