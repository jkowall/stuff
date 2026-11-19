# Home Assistant and SPAN Panel

This runbook covers taking over an existing Home Assistant SPAN integration and validating power and energy dashboards. Keep site-specific sensor mappings, configuration snapshots, and recovery notes in the private Home Assistant backup.

## Check the live setup

1. In Home Assistant, check the SPAN entry under **Settings → Devices & services**. Record the Home Assistant version, the installed SPAN integration version, the panel model and firmware, and any active repairs in the private notes.
2. If the entry is loaded and sensors are updating, use the existing entry and entity IDs. If setup is incomplete, confirm the VM can reach the panel on the local network and check the installed release’s firmware and Home Assistant requirements. Use the panel’s current address from the SPAN app or from discovery.
3. Before an update, reconfiguration, or dashboard change, create an encrypted Home Assistant backup and save the current Energy settings and affected dashboard configurations privately. If reauthentication is required, enter the On-premise passphrase directly in the Home Assistant setup form. [SPAN integration and setup](https://github.com/SpanPanel/span)

## Choose sources for the dashboards

| Reading | Source selection |
| --- | --- |
| Grid import and export | Use one validated meter at the grid connection. Compare its readings and coverage over the same time window before changing the existing source. |
| Solar and battery | Use the inverter or other verified equipment sensors for production, battery charge and discharge, and state of charge. Check direction and units. |
| Circuit power and energy | Use SPAN readings from verified circuits. Confirm labels and coverage against the SPAN app and observe a load during normal use. |
| EV charging and appliances | Choose a meter that covers the intended load. Where both a circuit and a device under it are tracked, configure the circuit as the upstream device when that relationship is known. |

1. Compare live power in W or kW and energy changes in Wh or kWh after converting to common units. If a panel meter sits near zero while the site meter shows sustained load, check the metering topology and compare the panel’s reading with the SPAN app before treating it as a whole-home meter. [Grid meters](https://www.home-assistant.io/docs/energy/electricity-grid/) · [Individual device hierarchies](https://www.home-assistant.io/docs/energy/individual-devices/)
2. In the built-in Energy dashboard, verify import, export, tariff, and the available solar, battery, and device statistics. Retain working historical sources unless a verified replacement is needed. Check that energy counters have the expected state class and are included in Recorder. [Energy settings](https://www.home-assistant.io/docs/energy/) · [Long-term statistics](https://www.home-assistant.io/docs/configuration/long-term-statistics/)
3. Audit custom dashboards for power cards, energy cards, and references to renamed or unavailable entities. Use clear labels for whole-home, panel, circuit, and device readings. Use sensor-only cards for the power views and preserve unavailable states so missing readings remain distinguishable from zero.

## Investigate untracked electricity

1. Count configured circuits from the SPAN panel topology. A multi-pole circuit can use multiple breaker positions, and a position may be unassigned. Check for shared meters and count each physical measurement once.
2. Add eligible SPAN consumption counters and their matching live power sensors as individual devices in Energy. If a plug or appliance meter can overlap a circuit, configure its upstream circuit when the relationship is known. A separate history graph preserves the plug or appliance statistics when the relationship is still unclear.
3. Compare the sum of all circuit energy against the net site meter across matching, completed intervals. Start after circuit data was first recorded. A date range that includes time before circuit statistics started will include untracked usage from that time.

For a phone layout, use a compact instant-power reading and daily energy and cost cards. Limit the number of devices in the live flow diagram and link to a circuit breakdown. Group read-only SPAN sensor rows by breaker position and use the per-entity history for individual checks.

## Verify and document changes

1. Confirm each referenced entity and statistic exists. Save dashboard changes against the freshly read configuration, then read back the saved configuration and open the affected views at desktop and phone widths.
2. Compare live graphs against the source readings. Check a prior date for existing history and a new hourly statistics interval for new energy sources. Confirm device and circuit totals account for overlapping meters and that grid flow has the expected direction. [Energy cards](https://www.home-assistant.io/dashboards/energy/)
3. If a dashboard or Energy settings change fails verification, restore its saved configuration. Use the encrypted backup if an integration upgrade requires a broader rollback.
4. Update this runbook when the setup or verification procedure changes. Record the applied changes, source choices, verification results, and remaining issues in the private Home Assistant backup.
