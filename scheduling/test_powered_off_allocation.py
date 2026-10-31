"""Regression tests: powered-off PCs remain bookable for scheduled slots.

Run via: python manage.py test scheduling.test_powered_off_allocation
Django creates a separate temporary test database (test DB privileges required).
"""
import datetime

from django.test import TestCase
from django.utils import timezone

from labs.models import Lab, PC
from scheduling.models import Session
from scheduling.utils import allocate_pcs, lab_pc_capacity


class PoweredOffReservationAllocationTests(TestCase):
    @classmethod
    def setUpTestData(cls):
        cls.lab = Lab.objects.create(
            name='Offline Booking Regression Lab',
            opening_time=datetime.time(0), closing_time=datetime.time(23, 59),
        )
        cls.pcs = [PC.objects.create(lab=cls.lab, pc_id=f'TEST-{i:02d}', status='offline')
                   for i in range(1, 11)]
        cls.future_day = timezone.localdate() + datetime.timedelta(days=2)
        cls.start = datetime.time(9)
        cls.end = datetime.time(10)

    def book(self, count, *, date=None, start=None, end=None):
        return Session.objects.create(
            lab=self.lab,
            subject='Reserved seats',
            date=date or self.future_day,
            start_time=start or self.start,
            end_time=end or self.end,
            student_count=count,
            pcs_allocated=count,
        )

    def test_ten_powered_off_pcs_can_be_reserved_for_future_class(self):
        self.assertEqual(lab_pc_capacity(self.lab, self.future_day, self.start, self.end), (10, 0, 10))
        self.assertEqual(allocate_pcs(self.lab, self.future_day, self.start, self.end, 10)[0], 10)

    def test_three_already_booked_and_seven_powered_off_grants_seven(self):
        self.book(3)
        # Simulates three computers occupied now and seven powered off.
        # Their current physical state does not change a future slot's capacity.
        PC.objects.filter(pk__in=[p.pk for p in self.pcs[:3]]).update(status='in_use')
        self.assertEqual(lab_pc_capacity(self.lab, self.future_day, self.start, self.end), (10, 3, 7))
        grant, note, available = allocate_pcs(self.lab, self.future_day, self.start, self.end, 8)
        self.assertEqual((grant, available), (7, 7))
        self.assertIn('requested 8', note)
        self.assertIn('only 7', note)

    def test_adjacent_reservations_are_not_double_booked(self):
        self.book(3)
        self.assertEqual(allocate_pcs(self.lab, self.future_day, self.start, self.end, 10)[0], 7)
        self.assertEqual(allocate_pcs(self.lab, self.future_day, datetime.time(10), datetime.time(11), 10)[0], 10)

    def test_maintenance_and_issue_do_not_count_as_usable(self):
        self.pcs[0].status = 'maintenance'
        self.pcs[0].save(update_fields=['status'])
        self.pcs[1].status = 'issue'
        self.pcs[1].save(update_fields=['status'])
        self.assertEqual(lab_pc_capacity(self.lab, self.future_day, self.start, self.end), (8, 0, 8))

    def test_current_unreserved_occupancy_blocks_only_current_time_slot(self):
        PC.objects.filter(pk__in=[p.pk for p in self.pcs[:3]]).update(status='in_use')
        today = timezone.localdate()
        entire_day_start = datetime.time(0)
        entire_day_end = datetime.time(23, 59, 59)
        self.assertEqual(allocate_pcs(self.lab, today, entire_day_start, entire_day_end, 10)[0], 7)
        self.assertEqual(allocate_pcs(self.lab, self.future_day, self.start, self.end, 10)[0], 10)

    def test_active_booked_pcs_are_not_counted_twice(self):
        today = timezone.localdate()
        start = datetime.time(0)
        end = datetime.time(23, 59, 59)
        reserved = self.book(3, date=today, start=start, end=end)
        PC.objects.filter(pk__in=[p.pk for p in self.pcs[:3]]).update(
            status='in_use', current_session=reserved,
        )
        self.assertEqual(lab_pc_capacity(self.lab, today, start, end), (10, 3, 7))

    def test_all_ten_booked_blocks_a_second_booking(self):
        self.book(10)
        grant, note, available = allocate_pcs(self.lab, self.future_day, self.start, self.end, 1)
        self.assertEqual((grant, available), (0, 0))
        self.assertIn('No available PCs', note)
