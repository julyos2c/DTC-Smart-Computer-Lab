// static/js/dashboard.js
// Auto-refreshes each PC's status pill on the PC Status page without a full
// page reload. The server already keeps pinging PCs in the background (see
// labs/network.py + labs/apps.py); this just polls the JSON snapshot of
// that data and updates the DOM to match, every 10 seconds.

const STATUS_LABELS = {
  online: 'Available',
  offline: 'Offline',
  in_use: 'In Use',
  maintenance: 'Under Maintenance',
  issue: 'Has Issue',
};

function formatUser(pc) {
  const first = pc.current_user__first_name || '';
  const last = pc.current_user__last_name || '';
  const fullName = `${first} ${last}`.trim();
  const registeredName = fullName || pc.current_user__id_number || null;
  // A PC checked in via Manual Unlock has no registered account at all —
  // current_user__* is blank — so fall back to the typed guest name.
  // Without this, the guest's name gets wiped out by the very next poll.
  if (registeredName) return registeredName;
  return pc.current_guest_name ? `${pc.current_guest_name} (Guest)` : null;
}

async function refreshPcStatuses() {
  let data;
  try {
    const res = await fetch('/labs/pc-status/api/');
    if (!res.ok) return;
    data = await res.json();
  } catch (err) {
    console.error('PC status refresh failed:', err);
    return;
  }

  (data.pcs || []).forEach((pc) => {
    const row = document.querySelector(`tr[data-pc="${pc.pc_id}"]`);
    if (!row) return;

    // COMPULAB_AGENT_STATUS_SINGLE_POLL_V2
    // Display connectivity separately from the stored usage/session status.
    const pill = row.querySelector('[data-role="status-pill"]');
    const note = row.querySelector('[data-role="agent-connection-note"]');
    const disconnected = pc.agent_disconnected === true; // COMPULAB_AUTO_CLEAR_OFFLINE_USER_V1
    if (pill) {
      pill.className = disconnected ? 'ld-pill offline' : `ld-pill ${pc.status}`;
      pill.textContent = disconnected
        ? (pc.status === 'in_use' ? 'Agent Offline - Session Preserved' : 'Agent Offline')
        : (pc.display_status || STATUS_LABELS[pc.status] || pc.status || 'Unknown');
    }
    if (note) {
      if (disconnected) {
        note.textContent = 'Agent disconnected (heartbeat expired). PC unavailable.';
      } else if (pc.status === 'offline') {
        note.textContent = 'PC offline / unreachable';
      } else if (pc.agent_connected === true) {
        note.textContent = 'Agent connected';
      } else {
        note.textContent = 'Agent connection not yet verified';
      }
    }

    const userCell = row.querySelector('[data-role="current-user"]');
    if (userCell) {
      userCell.textContent = formatUser(pc) || '\u2014';
    }
  });

  updateLastUpdatedStamp();
}

function updateLastUpdatedStamp() {
  const el = document.getElementById('ldLastUpdated');
  if (!el) return;
  el.textContent = new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' });
}

// Only start polling on pages that actually have status pills to update
// (i.e. the PC Status page in its normal, non "day lookup" view).
if (document.querySelector('[data-role="status-pill"]')) {
  refreshPcStatuses();
  setInterval(refreshPcStatuses, 10000);
}
