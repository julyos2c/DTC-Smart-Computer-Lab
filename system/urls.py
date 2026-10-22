from django.urls import path

from system import views

urlpatterns = [
    path('healthz', views.healthz, name='healthz'),
    path('healthz/ready', views.healthz_ready, name='healthz_ready'),
    path('system/status/', views.SystemStatusView.as_view(), name='system_status'),
    path('system/status/recheck/', views.system_recheck, name='system_recheck'),
]
