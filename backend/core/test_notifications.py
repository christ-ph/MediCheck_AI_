from django.contrib.auth import get_user_model
from rest_framework.test import APITestCase
from .models import SubscriptionPlan, ReviewNotification, Profile, ProfessionalApplication

class NotificationTests(APITestCase):
    def setUp(self):
        User = get_user_model()
        self.user = User.objects.create_user(username='notif-user')
        self.other = User.objects.create_user(username='notif-other')
        self.admin = User.objects.create_superuser(username='notif-admin', password='test-only-pass')
        SubscriptionPlan.objects.update_or_create(code='silver', defaults=dict(name='Silver',price_fcfa=1000,enabled=True))
    def test_subscription_notification_and_privacy(self):
        self.client.force_authenticate(self.user)
        r=self.client.post('/api/billing/subscription/',{'plan':'silver'},format='json')
        self.assertEqual(r.status_code,201)
        pk=r.data['id']
        self.client.force_authenticate(self.admin)
        url=f'/api/admin/billing/subscriptions/{pk}/'
        data={'action':'activate','reason':'Activation de test'}
        self.assertEqual(self.client.patch(url,data,format='json').status_code,200)
        self.assertEqual(self.client.patch(url,data,format='json').status_code,400)
        n=ReviewNotification.objects.get(subscription_id=pk,category='subscription')
        self.client.force_authenticate(self.other)
        self.assertEqual(self.client.get('/api/reviews/notifications/').data['count'],0)
        self.client.post(f'/api/reviews/notifications/{n.pk}/read/',{},format='json')
        n.refresh_from_db(); self.assertIsNone(n.read_at)
        self.client.force_authenticate(self.user)
        me=self.client.get('/api/me/').data
        self.assertFalse(me['professional_verified']); self.assertEqual(me['notification_unread'],1)
        r=self.client.get('/api/reviews/notifications/')
        self.assertEqual(r.data['results'][0]['category'],'subscription')
        self.assertEqual(self.client.post(f'/api/reviews/notifications/{n.pk}/read/',{},format='json').status_code,204)
        self.assertEqual(self.client.get('/api/me/').data['notification_unread'],0)
    def test_professional_decision(self):
        p=Profile.objects.create(user=self.user,professional_requested=True)
        ProfessionalApplication.objects.create(profile=p,status='pending',proof=b'%PDF-test')
        self.client.force_authenticate(self.admin)
        r=self.client.patch(f'/api/admin/professionals/{p.pk}/',{'verified':True},format='json')
        self.assertEqual(r.status_code,200)
        self.client.force_authenticate(self.user)
        self.assertEqual(self.client.get('/api/me/').data['notification_unread'],1)
        self.assertEqual(self.client.get('/api/reviews/notifications/').data['results'][0]['category'],'professional')
