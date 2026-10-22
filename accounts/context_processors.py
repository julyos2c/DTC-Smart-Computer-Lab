# accounts/context_processors.py
from notifications.models import Notification
from issues.models import Issue
from scheduling.models import SessionRequest
from django.conf import settings

def app_version(request):
    return {'APP_VERSION': getattr(settings, 'APP_VERSION', '')}

def sidebar_counts(request):
    if not request.user.is_authenticated:
        return {}
    pending_requests = SessionRequest.objects.filter(status='pending')
    if request.user.role == 'incharge':
        # Matches ManageRequestsView: an In-Charge manages their own lab only.
        pending_requests = pending_requests.filter(lab_id=request.user.assigned_lab_id)
    return {
        'unread_notifications_count': Notification.objects.filter(
            user=request.user, read=False
        ).count(),
        'open_issues_count': Issue.objects.filter(status='open').count()
        if request.user.role in ['admin', 'incharge'] else 0,
        'pending_requests_count': pending_requests.count()
        if request.user.role in ['admin', 'incharge'] else 0,
    }