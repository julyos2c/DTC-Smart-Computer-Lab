from django.urls import path

from cloud_sync import views

urlpatterns = [
    path('', views.SyncQueueView.as_view(), name='cloud_sync_queue'),
    path('retry-now/', views.cloud_sync_retry_now, name='cloud_sync_retry_now'),
    path('retry-failed/', views.cloud_sync_retry_failed, name='cloud_sync_retry_failed'),
    path('<int:pk>/retry/', views.cloud_sync_item_retry, name='cloud_sync_item_retry'),
    path('<int:pk>/resolve/', views.cloud_sync_item_resolve, name='cloud_sync_item_resolve'),
]
