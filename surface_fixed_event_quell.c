// SPDX-License-Identifier: GPL-2.0-only
/*
 * surface_fixed_event_quell.c - Suppress broken ACPI SCI on Surface hardware
 *
 * The Surface firmware generates unnecessary ACPI interrupts for fixed events
 * that have no working Linux handlers (RTC, PM Timer, Power Button, etc.).
 * This wastes CPU, floods kernel logs, and burns NVMe writes.
 *
 * This module masks the ACPI SCI interrupt. On Surface devices the
 * embedded controller (Surface Aggregator Module) handles battery, thermal,
 * and fan monitoring — standard ACPI interrupts are not needed for these.
 *
 * Author: Barnacle O'Byte <barnacle@o-byte.sea>
 * License: GPL v2
 */
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/interrupt.h>
#include <linux/reboot.h>
#include <linux/acpi.h>
#include <linux/dmi.h>

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Surface ACPI Quell — suppress broken ACPI SCI interrupts");
MODULE_AUTHOR("Barnacle O'Byte");
MODULE_VERSION("1.3.0");

/* ── Parameters ─────────────────────────────────────────────────────────── */

static unsigned int irq_number = 9;
module_param(irq_number, uint, 0444);
MODULE_PARM_DESC(irq_number,
	"ACPI SCI IRQ number (default: 9, must be > 0)");

static unsigned int check_interval_ms = 10000;
module_param(check_interval_ms, uint, 0444);
MODULE_PARM_DESC(check_interval_ms,
	"Interval in ms between re-mask attempts (default: 10000, min: 10)");

static bool skip_hw_check = false;
module_param(skip_hw_check, bool, 0444);
MODULE_PARM_DESC(skip_hw_check,
	"Skip Surface hardware check (default: false, only allowed on Surface)");

/* ── State ──────────────────────────────────────────────────────────────── */

static struct timer_list quell_timer;
static bool timer_active;	/* protected by timer callback serialization */

/* ── Reboot / shutdown notifier ────────────────────────────────────────
 *
 * IRQ 9 (ACPI SCI) must be re-enabled before the final power-off sequence
 * begins. Without this, the ACPI power-off event can't be delivered and the
 * system hangs with screen off but fans running (Surface Laptop Studio 2).
 *
 * This notifier runs at INT_MAX priority (earliest possible) so the IRQ is
 * unmasked before even the device shutdown callbacks are invoked.
 */
static int quell_reboot_notifier(struct notifier_block *nb,
				 unsigned long action, void *data)
{
	WRITE_ONCE(timer_active, false);
	timer_delete_sync(&quell_timer);
	enable_irq(irq_number);
	pr_info("surface_quell: unmasked IRQ %u for shutdown/reboot\n",
		irq_number);
	return NOTIFY_OK;
}

static struct notifier_block quell_reboot_nb = {
	.notifier_call = quell_reboot_notifier,
	.priority = INT_MAX,
};

/* ── Safety: verify we're on Surface hardware ───────────────────────────────
 *
 * The IRQ 9 mask is safe on Surface because the Surface Aggregator Module
 * handles battery, thermal, and platform monitoring. On non-Surface hardware
 * this would break ACPI power management. Refuse to load unless we can
 * confirm Surface hardware (or skip_hw_check is set).
 */

static int check_surface_hardware(void)
{
	const char *vendor;

	if (skip_hw_check) {
		pr_warn("surface_quell: hardware check skipped by module param\n");
		return 0;
	}

	vendor = dmi_get_system_info(DMI_SYS_VENDOR);
	if (!vendor) {
		pr_err("surface_quell: cannot determine hardware vendor\n");
		return -ENODEV;
	}

	if (strstr(vendor, "Microsoft")) {
		pr_info("surface_quell: detected Surface hardware (%s)\n",
			vendor);
		return 0;
	}

	pr_err("surface_quell: not Surface hardware (%s). "
	       "IRQ 9 masking is unsafe on non-Surface systems. "
	       "Set skip_hw_check=true to override.\n", vendor);
	return -ENODEV;
}

/* ── Core ─────────────────────────────────────────────────────────────────
 *
 * disable_irq_nosync() is used instead of disable_irq() because the
 * quell_timer_callback runs in softirq context where sleeping is not
 * allowed. disable_irq() might sleep waiting for handlers to complete.
 * Since the mask is a best-effort operation (the firmware may re-enable
 * the interrupt between checks anyway), nosync is sufficient.
 */

static void mask_acpi_sci(void)
{
	disable_irq_nosync(irq_number);
	pr_debug("surface_quell: masked IRQ %u\n", irq_number);
}

static void quell_timer_callback(struct timer_list *t)
{
	if (!READ_ONCE(timer_active))
		return;

	mask_acpi_sci();

	/* Re-arm only if the module is still active. The flag is cleared
	 * before timer_delete_sync() in the exit path, so this race-free:
	 * either the callback sees timer_active == true and re-arms, or
	 * it sees false and skips re-arm. In the latter case the exit
	 * path's timer_delete_sync() finds no pending timer.
	 */
	if (READ_ONCE(timer_active))
		mod_timer(&quell_timer,
			  jiffies + msecs_to_jiffies(check_interval_ms));
}

/* ── Init / Exit ────────────────────────────────────────────────────────── */

static int __init surface_fixed_event_quell_init(void)
{
	int ret;

	if (irq_number == 0) {
		pr_err("surface_quell: irq_number must be > 0\n");
		return -EINVAL;
	}
	if (check_interval_ms < 10) {
		pr_warn("surface_quell: check_interval_ms %u too low, using 10\n",
			check_interval_ms);
		check_interval_ms = 10;
	}

	ret = check_surface_hardware();
	if (ret)
		return ret;

	pr_info("surface_quell: masking ACPI SCI IRQ %u (check every %ums)\n",
		irq_number, check_interval_ms);

	mask_acpi_sci();

	timer_setup(&quell_timer, quell_timer_callback, 0);
	timer_active = true;
	mod_timer(&quell_timer,
		  jiffies + msecs_to_jiffies(check_interval_ms));

	register_reboot_notifier(&quell_reboot_nb);
	pr_debug("surface_quell: registered reboot notifier\n");

	return 0;
}

static void __exit surface_fixed_event_quell_exit(void)
{
	/* Prevent re-arm: the callback checks this flag, and mod_timer
	 * won't be called once it's cleared. After timer_delete_sync()
	 * returns, no callback is running and no new timer is queued.
	 */
	WRITE_ONCE(timer_active, false);
	timer_delete_sync(&quell_timer);
	unregister_reboot_notifier(&quell_reboot_nb);
	enable_irq(irq_number);
	pr_info("surface_quell: unmasked ACPI SCI IRQ %u\n", irq_number);
}

module_init(surface_fixed_event_quell_init);
module_exit(surface_fixed_event_quell_exit);
