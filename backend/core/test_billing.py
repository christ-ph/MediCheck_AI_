import uuid
from datetime import timedelta
from django.contrib.auth import get_user_model
from django.utils import timezone
from rest_framework.test import APITestCase
from .models import SubscriptionPlan, Subscription, Profile, ProfessionalApplication, PointWallet, PointTransaction

class BillingTests(APITestCase):
    def setUp(self):
        U=get_user_model()
        self.user=U.objects.create_user(username='billing-user')
        self.pro=U.objects.create_user(username='billing-pro')
        self.admin=U.objects.create_superuser(username='billing-admin',password='test-only-pass')
        p=Profile.objects.create(user=self.pro,professional_requested=True,professional_verified=True)
        ProfessionalApplication.objects.create(profile=p,status='approved',proof=b'%PDF-test')
        for code,price in [('free',0),('silver',1000),('gold',2500)]:
            SubscriptionPlan.objects.update_or_create(code=code,defaults={'name':code.title(),'price_fcfa':price,'enabled':True})
    def auth(self,u): self.client.force_authenticate(user=u)
    def test_subscription_flow(self):
        self.auth(self.user)
        self.assertEqual(self.client.get('/api/admin/billing/subscriptions/').status_code,403)
        self.assertEqual(self.client.get('/api/billing/subscription/').data['effective_plan'],'free')
        r=self.client.post('/api/billing/subscription/',{'plan':'silver','price_fcfa':1},format='json')
        self.assertEqual(r.status_code,201); pk=r.data['id']; self.assertEqual(r.data['price_fcfa'],1000)
        self.assertEqual(self.client.post('/api/billing/subscription/',{'plan':'gold'},format='json').status_code,400)
        self.auth(self.pro)
        self.assertEqual(self.client.post(f'/api/billing/subscription/{pk}/cancel/',{},format='json').status_code,404)
        self.auth(self.admin)
        self.assertEqual(self.client.patch(f'/api/admin/billing/subscriptions/{pk}/',{'action':'activate','reason':'Test de démonstration'},format='json').status_code,200)
        self.auth(self.user)
        self.assertEqual(self.client.get('/api/billing/subscription/').data['effective_plan'],'silver')
        Subscription.objects.filter(pk=pk).update(ends_at=timezone.now()-timedelta(seconds=1))
        self.assertEqual(self.client.get('/api/billing/subscription/').data['effective_plan'],'free')
        self.assertEqual(self.client.post('/api/billing/subscription/',{'plan':'gold'},format='json').status_code,201)
    def test_points_permissions_and_balance(self):
        self.auth(self.user)
        self.assertEqual(self.client.get('/api/billing/points/').status_code,403)
        url=f'/api/admin/billing/wallets/{self.pro.pk}/'
        d={'delta':50,'reason':'Contribution de test','operation_id':str(uuid.uuid4())}
        self.assertEqual(self.client.post(url,d,format='json').status_code,403)
        self.auth(self.admin)
        self.assertEqual(self.client.post(url,d,format='json').status_code,201)
        self.assertEqual(self.client.post(url,d,format='json').status_code,200)
        self.assertEqual(PointTransaction.objects.count(),1)
        self.assertEqual(self.client.post(url,{**d,'delta':-51,'operation_id':str(uuid.uuid4())},format='json').status_code,400)
        self.assertEqual(PointWallet.objects.get(user=self.pro).balance,50)
        self.auth(self.pro)
        self.assertEqual(self.client.get('/api/billing/points/').data['balance'],50)
        Profile.objects.filter(user=self.pro).update(professional_verified=False)
        self.assertEqual(self.client.get('/api/billing/points/').status_code,403)
