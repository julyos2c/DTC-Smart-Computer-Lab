"""Who may talk for a lab PC: per-PC agent secrets.

Every lab PC agent proves itself with a secret, in both directions:
  * agent -> server (the pc-agent-* APIs): the server finds the PC by the
    request's IP address and checks the secret against THAT PC;
  * server -> agent (unlock, lock, override warning, power): the agent
    checks the secret against its own agent_config.local.json.

Originally every PC used the one PC_AGENT_SHARED_SECRET, so anyone who
copied it from one lab PC could act for every PC. Now each PC gets its own
secret (PC.agent_secret) the first time its Agent config file is downloaded,
and the move happens per PC without breaking anything:

  1. A PC without its own secret keeps using the shared one (old installs).
  2. Downloading its Agent config creates its own secret; the agent still
     installed on it keeps working with the shared secret meanwhile.
  3. The first time the agent on that PC uses its own secret (after the
     agent setup was run with the new file), agent_secret_in_use is set and
     the shared secret is refused for that PC from then on.
  4. When every PC has moved, PC_AGENT_REQUIRE_PER_PC_SECRET=True in .env
     refuses the shared secret everywhere.

A per-PC secret only works from that PC's own IP address, so a secret
copied from one PC does not unlock or impersonate another.
"""
import hmac
import secrets

from django.conf import settings


def _same(given, expected):
    if not given or not expected:
        return False
    return hmac.compare_digest(str(given).encode('utf-8'), str(expected).encode('utf-8'))


def shared_secret_allowed():
    """The shared PC_AGENT_SHARED_SECRET may still be used (for PCs that have
    not moved to their own secret yet)."""
    return bool(getattr(settings, 'PC_AGENT_SHARED_SECRET', '')) and not getattr(
        settings, 'PC_AGENT_REQUIRE_PER_PC_SECRET', False)


def _mark_in_use(pc):
    if not pc.agent_secret_in_use:
        type(pc).objects.filter(pk=pc.pk).update(agent_secret_in_use=True)
        pc.agent_secret_in_use = True


def authenticate(pc, secret):
    """May a request carrying `secret` act for `pc`? `pc` is the PC registered
    with the request's IP address, or None for an address no PC has."""
    if pc is not None and pc.agent_secret and _same(secret, pc.agent_secret):
        _mark_in_use(pc)
        return True
    if not shared_secret_allowed():
        return False
    if pc is not None and pc.agent_secret_in_use:
        return False   # this PC has moved to its own secret
    return _same(secret, settings.PC_AGENT_SHARED_SECRET)


def ensure_secret(pc):
    """This PC's own secret, created on first use (for its Agent config file)."""
    if not pc.agent_secret:
        type(pc).objects.filter(pk=pc.pk, agent_secret='').update(agent_secret=secrets.token_urlsafe(32))
        pc.refresh_from_db(fields=['agent_secret'])
    return pc.agent_secret


def rotate_secret(pc):
    """Replace this PC's secret (e.g. after a lab PC was compromised). The
    agent on the PC stops being accepted until its new Agent config file is
    installed. A PC that had already moved to its own secret does not fall
    back to the shared one."""
    pc.agent_secret = secrets.token_urlsafe(32)
    type(pc).objects.filter(pk=pc.pk).update(agent_secret=pc.agent_secret)
    return pc.agent_secret


def secrets_for_command(pc):
    """The secrets to try, in order, when the server sends a command to the
    agent on `pc`: (secret, is_own_secret) pairs."""
    if pc.agent_secret and pc.agent_secret_in_use:
        return [(pc.agent_secret, True)]
    candidates = []
    if shared_secret_allowed():
        candidates.append((settings.PC_AGENT_SHARED_SECRET, False))
    if pc.agent_secret:
        candidates.append((pc.agent_secret, True))
    return candidates


def command_accepted(pc, is_own_secret):
    """The agent on `pc` accepted a command sent with its own secret: it has
    the new settings file, so stop accepting the shared secret for it."""
    if is_own_secret:
        _mark_in_use(pc)


def summary(pcs):
    """Counts for System status: how many PCs use their own secret."""
    pcs = list(pcs)
    own = sum(1 for pc in pcs if pc.agent_secret_in_use)
    pending = sum(1 for pc in pcs if pc.agent_secret and not pc.agent_secret_in_use)
    return {'total': len(pcs), 'own': own, 'pending': pending, 'shared': len(pcs) - own - pending,
            'shared_allowed': shared_secret_allowed()}
