---
name: maintain-xboard-node
description: Use when the user provides an existing VPN/Xboard node IP and asks to maintain, rotate, restart, stop/start, recover, or refresh a Lightsail-backed Xboard node.
---

# Maintain Xboard Node

## Overview

Use this skill for the live browser workflow that maps an old public IP to an AWS Lightsail instance, stops and starts that instance to obtain a new public IP, updates the matching Xboard node record, verifies recovery, and posts a Slack notice.

This touches live infrastructure. Use the user's real desktop browser session because AWS Console login state and Dev account selection live there. Do not use AWS CLI or backend APIs unless the user explicitly asks for an API-based path.

## Required Input

Require exactly one old IPv4 address from the user before making changes.

If the user has not provided the old IP, ask one concise question for it. If the user provides a node label but no IP, still ask for the old IP because the Xboard update must match the address field.

## Preflight Confirmation

Before opening Lightsail or making any AWS/Xboard change, show a native user confirmation interaction when the runtime has one and wait for an affirmative answer.

The confirmation must ask the user to confirm both:

- They are logged in to AWS Console in the browser session the agent will operate.
- The AWS Console is switched to the Dev environment/account, not production or any other environment.

Use concise wording such as:

`请确认：浏览器已经登录 AWS Console，并且当前切换到 Dev 环境。确认后我才会继续停止/启动 Lightsail 实例并更新 Xboard 节点。`

If the current runtime cannot show a native/structured confirmation interaction, stop and say that this surface cannot pop the required confirmation. Do not silently downgrade to a plain chat message as the confirmation when the skill is configured to require a popup.

If the user does not clearly confirm both conditions through the required confirmation interaction, stop before touching AWS or Xboard.

## Browser Targets

- AWS Lightsail instances: `https://ap-northeast-1.lightsail.aws.amazon.com/ls/webapp/home/instances`
- Xboard node management: `http://52.195.229.186:7001/admin-pannel#/server/manage`

## Browser Requirement

Use the user's computer browser, not an isolated in-app browser. Prefer a browser-control workflow that can claim or operate the user's existing Chrome tabs and logged-in AWS/Xboard session.

If Chrome control is unavailable, use computer-use against the user's visible desktop browser. If only an isolated in-app browser is available, stop and report that this skill cannot continue because it must operate the user's real browser session.

Do not open Lightsail or Xboard in an isolated in-app browser for this skill. It may not share the user's AWS login state or Dev environment/account selection.

## Fast Path

Prefer this path when Chrome/browser-control is available; it is faster and less error-prone than visual scanning.

1. Claim existing Chrome tabs first.
   - List user Chrome tabs and claim existing tabs whose URLs contain `lightsail.aws.amazon.com/ls/webapp/home/instances` and `52.195.229.186:7001/admin-pannel`.
   - Only open a new Chrome tab if the matching tab does not already exist.
   - Do not use an isolated in-app browser as a fallback.

2. Locate the Lightsail instance by page text.
   - Use one bounded page-text read or DOM snapshot to confirm the old IP exists.
   - Extract the nearest instance block around the old IP and record instance name, state, IPv4, region, and zone.
   - In the observed AWS Lightsail UI, instance blocks contain the instance name, plan, state, public IPv4, public IPv6, and region/zone.

3. Use stable menu positioning on Lightsail.
   - After identifying the instance name, use the visible DOM to find that instance's nearby three-dot menu.
   - In the observed Lightsail DOM, each instance exposes the instance link, SSH button, then the three-dot menu button.
   - After clicking the menu, verify the menu contains the intended action (`Stop` when running, `Start` when stopped) before clicking.
   - When AWS shows an extra confirmation dialog, click only the confirmation button for the same action after verifying the instance block still contains the exact old IP.

4. Poll concise status, not screenshots.
   - Poll the target instance block every few seconds for state transitions: `Stopping` -> `Stopped`, then `Starting` -> `Running`.
   - Treat `Starting` as a transitional state. Capture the new IPv4 when it first appears, but wait for `Running` before editing Xboard.
   - Avoid page reloads during normal state transitions unless the UI stops updating.

5. Update Xboard with row-level precision.
   - First read the table text once and confirm exactly one row contains the old IP host.
   - Record node ID, node name, deployment label, status badge, address, and port from that row.
   - Prefer clicking the operation menu for the exact row. If the DOM only exposes repeated row operation buttons, count them and use the button at the same row index as the matched row only after confirming the table has the expected row order.
   - If DOM node IDs become stale, re-read the DOM or use stable locators instead of retrying stale IDs.
   - In the edit modal, target `input[name="host"]` for `节点地址`. Verify `input[name="port"]`, `input[name="server_port"]`, and `input[name="name"]` remain unchanged before submitting.
   - Fastest proven host-input path in Chrome control: read the modal DOM, click the `input[name="host"]` node, press `END`, press `BACKSPACE` `old_ip.length + 4` times, then enter the new IP with individual keypresses for each character. Re-read `input[name="host"]` afterward and verify it equals the new IP.
   - Avoid spending time on `fill`, `type`, clipboard, paste, `Meta+A`, or `Control+A` after a virtual-clipboard error; switch immediately to the individual-keypress path.

6. Final verification should parse table rows.
   - After submitting, refresh the Xboard management URL once.
   - Prefer DOM table row extraction (`tr.innerText`) to avoid mixing status badges from neighboring rows.
   - Final success requires the single row containing the new IP to also contain the original node name/ID, the same port, and `服务器在线`, while the old IP is absent.

7. Notify Slack after verified recovery.
   - Send the notification only after final Xboard verification succeeds.
   - Post to Slack channel `C077167EQR1`.
   - Include a Slack channel-wide mention and the restored node name. Do not include IP addresses or ports. Use Slack's special mention token, not bare text: `<!channel> {node_name} VPN 连接已恢复。`
   - If Slack posting fails, report the maintenance success and the Slack failure separately. Do not retry in a loop.

## Workflow

1. Run preflight confirmation.
   - Confirm the old IP is available.
   - Use a native/structured confirmation interaction to ask the user to confirm they are logged in to AWS Console and switched to the Dev environment/account.
   - If only plain chat is available where a popup is required, stop and report that the required popup/structured confirmation is unavailable in this runtime.
   - Do not open Lightsail, stop instances, start instances, or edit Xboard until the user clearly confirms.

2. Locate the Lightsail tab.
   - Claim or switch to the user's existing desktop-browser Lightsail tab when available; otherwise open the Lightsail instances URL in the user's desktop browser.
   - Prefer the Fast Path page-text extraction to find the exact old IP.
   - If the old IP is not visible, use page search, scroll through all regions/availability zones, and verify the current region list before concluding it is missing.
   - Record the instance name, region/zone, current state, and old IP.

3. Stop the matching instance.
   - Open the instance card's three-dot menu.
   - Click `Stop`.
   - Confirm any AWS dialog only after verifying the instance card contains the exact old IP.
   - Wait until the instance state is `Stopped`. Refresh or re-check the card as needed.
   - Do not proceed while the state is `Stopping`, `Pending`, `Running`, or unclear.

4. Start the same instance again.
   - Open the same instance card's three-dot menu.
   - Click `Start`.
   - Wait until the state returns to `Running`.
   - Read and record the new public IPv4 address from the same instance card.
   - Verify the new IP is non-empty and different from the old IP. If it is unchanged, report that explicitly and ask before repeating stop/start.

5. Update the Xboard node.
   - Claim or switch to the user's existing desktop-browser Xboard node management tab when available; otherwise open the Xboard node management URL in the user's desktop browser.
   - Prefer the Fast Path row-level table extraction to find the exact old IP.
   - Match the row by address host exactly, ignoring the port suffix. Example: old IP `52.195.229.186` matches `52.195.229.186:8443`.
   - Record the node name, node ID, old address value, and port before editing.
   - Open the row's three-dot menu and click `编辑` / `Edit`.
   - In the edit modal, change only `节点地址` / node address from the old IP to the new IP. Target `input[name="host"]` when available.
   - For Chrome/browser-control, prefer the proven keypress replacement path for `input[name="host"]`: click host input, press `END`, press `BACKSPACE` `old_ip.length + 4` times, then send the new IP one character at a time with keypresses.
   - Preserve connection port, server port, node name, security settings, permissions, tags, and all other fields unless the user explicitly says otherwise.
   - Verify the form still shows the same node name, connection port, and server port before submitting.
   - Submit the form and wait for the table to reflect the new address.

6. Verify Xboard recovery.
   - Refresh `http://52.195.229.186:7001/admin-pannel#/server/manage` after submitting the edit.
   - Find the row whose address host exactly matches the new IP, ignoring the port suffix. Prefer parsing DOM table rows instead of broad surrounding text so neighboring rows cannot contaminate the status check.
   - Confirm the Xboard table no longer shows the old IP for that node and does show the new IP with the same port.
   - Check the matching new-IP row's deployment/status badge and wait until it shows `服务器在线`.
   - If the row is still `服务器离线`, missing, stale, or unclear, refresh the page and re-check the same new-IP row until it becomes `服务器在线` or the wait is clearly excessive.

7. Notify Slack and report.
   - After the Xboard row reaches `服务器在线`, send a Slack message to channel `C077167EQR1`.
   - Message template: `<!channel> {node_name} VPN 连接已恢复。`
   - Include the node name from Xboard, for example `Tokyo4`, not only the Lightsail instance name.
   - Do not include IP addresses or ports in the Slack message.
   - Report the instance name, node name/ID, old IP, new IP, port, and whether the Xboard row reached `服务器在线`.
   - Report whether the Slack notification was sent successfully.
   - Mention any manual confirmation dialogs clicked.

## Safety Rules

- Never stop an instance unless the card contains the exact old IP supplied by the user.
- Never edit a Xboard row unless its address host exactly matches the old IP.
- If multiple Lightsail instances or Xboard rows match the same old IP, stop and ask the user which one to use.
- If the browser is logged out, blocked by MFA, or the AWS/Xboard UI differs enough that the target controls cannot be identified, stop and ask the user to restore access or confirm the next step.
- If the available browser surface is an isolated in-app browser instead of the user's desktop browser, stop before navigating or clicking.
- Do not click `Delete`, `Reboot`, `Reset traffic`, or any destructive/non-requested action.
- Avoid changing visibility toggles, permission groups, ports, Reality/VLess settings, subscriptions, or routing.
- Do not treat the workflow as complete immediately after submitting the edit; final success requires the refreshed Xboard row for the new IP to show `服务器在线`.
- Plain chat confirmation is not sufficient for the initial Dev-environment preflight when a native confirmation is available or required; use the native/structured confirmation interaction or stop.
- Do not send the Slack `<!channel>` recovery message before Xboard final verification shows the new-IP row as `服务器在线`.
- Do not include IP addresses or ports in the Slack recovery message.
- Use `<!channel>` for Slack channel-wide notification. Do not use bare `@channel`, because Slack API sends it as plain text in some tool paths.

## Speed Rules

- Prefer one bounded page-text or table-row extraction over screenshots for routine checks.
- Do not repeatedly dump full DOM snapshots. Take a fresh DOM snapshot only after a state change, stale node, timeout, or when a new locator is needed.
- If a DOM node ID is stale, immediately re-read the DOM or switch to a stable locator; do not retry the same stale node ID.
- Do not reload Lightsail during normal stop/start transitions unless the status stops changing. Poll the target instance block instead.
- Use Xboard form field names when available: `input[name="host"]`, `input[name="port"]`, `input[name="server_port"]`, and `input[name="name"]`.
- For Xboard host input in Chrome control, skip `fill`, `type`, clipboard, paste, `Meta+A`, and `Control+A` after the first virtual-clipboard error. Use click -> `END` -> `BACKSPACE` `old_ip.length + 4` times -> per-character keypress instead.
- Avoid image screenshots unless visual layout is ambiguous or a final visual proof is explicitly requested.

## Useful Visual Anchors

- Lightsail instance cards show the instance state (`Running` or `Stopped`), public IPv4, region/zone, and a three-dot menu with `Stop` and `Start`.
- Xboard node rows show columns similar to node ID, visibility, node name, deployment method, address, online users, multiplier, permission group, traffic usage, and a right-side operations menu.
- In the Xboard table, the online server state appears as a green `服务器在线` badge next to the deployment/node label.
- The Xboard edit modal has a `节点地址` field and separate connection/server port fields below it. Only the node address field should change.
