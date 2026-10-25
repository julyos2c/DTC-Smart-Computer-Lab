from django.conf import settings
from django.contrib import admin
from django.urls import path, include, re_path
from django.views.static import serve
from accounts.views import role_redirect, CompulabLoginView, CompulabPasswordResetView, CompulabPasswordResetConfirmView

urlpatterns = [
    path('admin/', admin.site.urls),
    path('', role_redirect, name='home'),
    path('accounts/login/', CompulabLoginView.as_view(), name='login'),
    path('accounts/password_reset/', CompulabPasswordResetView.as_view(), name='password_reset'),
    path('accounts/reset/<uidb64>/<token>/', CompulabPasswordResetConfirmView.as_view(), name='password_reset_confirm'),
    path('accounts/', include('django.contrib.auth.urls')),
    path('accounts/', include('accounts.urls')),
    path('labs/', include('labs.urls')),
    path('schedule/', include('scheduling.urls')),
    path('issues/', include('issues.urls')),
    path('notifications/', include('notifications.urls')),
    # /healthz, /healthz/ready, /system/status/
    path('', include('system.urls')),
    # Admin view of the optional cloud-sync queue
    path('system/cloud-sync/', include('cloud_sync.urls')),
    # /api/ping/, /api/sync/: the cloud receiver (404 unless CLOUD_RECEIVER_ENABLED)
    path('', include('cloud_receiver.urls')),
]

# Only uploaded avatars are public. Everything else under MEDIA_ROOT (e.g.
# activity_log_backups/*.xlsx, which hold students' PC activity) must never
# be reachable by URL, so MEDIA_ROOT as a whole is deliberately not served.
if settings.DEBUG or settings.SERVE_MEDIA:
    urlpatterns += [
        re_path(
            r'^%savatars/(?P<path>.*)$' % settings.MEDIA_URL.lstrip('/'),
            serve,
            {'document_root': settings.MEDIA_ROOT / 'avatars'},
        ),
    ]
