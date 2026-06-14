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
#include <linux/acpi.h>
#include <linux/dmi.h>

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Surface ACPI Quell — suppress broken ACPI SCI interrupts");
MODULE_AUTHOR("Barnacle O'Byte");
MODULE_VERSION("1.1.0");

/* ── Parameters ─────────────────────────────────────────────────────────── */

static unsigned int irq_number = 9;
module_param(irq_number, uint, 0444);
MODULE_PARM_DESC(irq_number,
	"ACPI SCI IRQ number (default: 9)");

static unsigned int check_interval_ms = 10000;
module_param(check_interval_ms, uint, 0444);
MODULE_PARM_DESC(check_interval_ms,
	"Interval in ms between re-mask attempts (default: 10000)");

static bool skip_hw_check = false;
module_param(skip_hw_check, bool, 0444);
MODULE_PARM_DESC(skip_hw_check,
	"Skip Surface hardware check (default: false, only allowed on Surface)");

/* ── State ──────────────────────────────────────────────────────────────── */

static struct timer_list quell_timer;

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

/* ── Core ───────────────────────────────────────────────────────────────── */

static void mask_acpi_sci(void)
{
	disable_irq(irq_number);
	pr_debug("surface_quell: masked IRQ %u\n", irq_number);
}

static void quell_timer_callback(struct timer_list *t)
{
	mask_acpi_sci();
	mod_timer(&quell_timer,
		  jiffies + msecs_to_jiffies(check_interval_ms));
}

/* ── Init / Exit ────────────────────────────────────────────────────────── */

static int __init surface_fixed_event_quell_init(void)
{
	int ret;

	ret = check_surface_hardware();
	if (ret)
		return ret;

	pr_info("surface_quell: masking ACPI SCI IRQ %u (check every %ums)\n",
		irq_number, check_interval_ms);

	mask_acpi_sci();

	timer_setup(&quell_timer, quell_timer_callback, 0);
	mod_timer(&quell_timer,
		  jiffies + msecs_to_jiffies(check_interval_ms));

	return 0;
}

static void __exit surface_fixed_event_quell_exit(void)
{
	timer_delete_sync(&quell_timer);
	enable_irq(irq_number);
	pr_info("surface_quell: unmasked ACPI SCI IRQ %u\n", irq_number);
}

module_init(surface_fixed_event_quell_init);
module_exit(surface_fixed_event_quell_exit);
