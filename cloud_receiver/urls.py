from django.urls import path

from cloud_receiver import views

urlpatterns = [
    path('api/ping/', views.ping, name='cloud_receiver_ping'),
    path('api/sync/', views.sync, name='cloud_receiver_sync'),
]

from .command_views import commands
urlpatterns += [path('api/commands/', commands, name='cloud_commands')]

from .reservation_views import reservation_changes
urlpatterns += [path('api/reservation-changes/', reservation_changes, name='cloud_reservation_changes')]

from .inventory_views import inventory_changes
urlpatterns += [path('api/inventory-changes/', inventory_changes, name='cloud_inventory_changes')]

from .monitor import monitor, monitor_data
urlpatterns += [path('cloud/monitor/', monitor, name='cloud_monitor'),
                path('cloud/api/pc-status/', monitor_data, name='cloud_monitor_data')]
