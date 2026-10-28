"""Shared lock for local schedule POSTs and cloud reservation transactions."""
from contextlib import contextmanager
from django.db import transaction
from django.conf import settings
from django.http import JsonResponse


@contextmanager
def schedule_write_lock():
    from labs.models import Lab
    with transaction.atomic():
        # One deterministic order across local and remote writes avoids deadlocks
        # and prevents two independent approvals from booking the same capacity.
        list(Lab.objects.select_for_update().order_by('pk').values_list('pk', flat=True))
        yield


class ScheduleWriteMiddleware:
    def __init__(self, get_response):
        self.get_response = get_response

    def __call__(self, request):
        scheduling_path = (request.path_info.startswith('/schedule/')
                           or request.path_info.startswith('/admin/scheduling/'))
        if request.method == 'POST' and scheduling_path:
            if getattr(settings, 'CLOUD_RECEIVER_ENABLED', False) and getattr(settings, 'CLOUD_RESERVATIONS_ENABLED', False):
                return JsonResponse({'detail': 'Use Cloud receiver > Reservation changes; campus validation is required.'}, status=409)
            with schedule_write_lock():
                response = self.get_response(request)
                if response.status_code >= 400:
                    transaction.set_rollback(True)
                return response
        return self.get_response(request)
