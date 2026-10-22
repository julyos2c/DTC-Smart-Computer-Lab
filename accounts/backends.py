from django.contrib.auth.backends import ModelBackend

from accounts.verification import requires_verification


class VerifiedEmailBackend(ModelBackend):
    """ModelBackend that also refuses accounts still awaiting email
    verification. Applies to every route that authenticates (dashboard
    login, /admin/ login) and to existing sessions, since get_user() runs
    the same check on every request."""

    def user_can_authenticate(self, user):
        return super().user_can_authenticate(user) and not requires_verification(user)
