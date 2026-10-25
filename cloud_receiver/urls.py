from django.urls import path

from cloud_receiver import views

urlpatterns = [
    path('api/ping/', views.ping, name='cloud_receiver_ping'),
    path('api/sync/', views.sync, name='cloud_receiver_sync'),
]
