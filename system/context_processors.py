def system_status(request):
    """Server-reported status for the footer badge (replaces the old
    navigator.onLine check, which only knew whether the *browser* had a
    network, not whether the server had internet or email)."""
    user = getattr(request, 'user', None)
    if not (user and user.is_authenticated and user.role != 'student'):
        return {}
    from system.connectivity import get_summary, headline_for
    try:
        summary = get_summary()
        level, text = headline_for(summary, user.role == 'admin')
        return {'system_status': summary, 'system_headline': text, 'system_headline_level': level}
    except Exception:  # noqa: BLE001 - never break a page over the badge
        return {}
